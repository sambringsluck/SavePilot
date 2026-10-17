import Foundation

final class LearningStore {
    struct Rule: Codable {
        var fileExtension: String
        var terms: [String]
        var destinationPath: String
        var approvals: Int
        var rejections: Int
        var updatedAt: Date

        init(fileExtension: String, terms: [String], destinationPath: String, approvals: Int, rejections: Int = 0, updatedAt: Date) {
            self.fileExtension = fileExtension
            self.terms = terms
            self.destinationPath = destinationPath
            self.approvals = approvals
            self.rejections = rejections
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case fileExtension, terms, destinationPath, approvals, rejections, updatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fileExtension = try values.decode(String.self, forKey: .fileExtension)
            terms = try values.decode([String].self, forKey: .terms)
            destinationPath = try values.decode(String.self, forKey: .destinationPath)
            approvals = try values.decode(Int.self, forKey: .approvals)
            rejections = try values.decodeIfPresent(Int.self, forKey: .rejections) ?? 0
            updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        }
    }

    struct NovelCluster: Codable {
        var topic: String
        var terms: [String]
        var sourcePaths: [String]
        var updatedAt: Date
    }

    struct Recommendation {
        let destination: URL
        let confidence: Double
        let evidence: String
        let approvals: Int
        let rejections: Int
    }

    struct TrainingEvent: Codable {
        let id: UUID
        let fileName: String
        let fileExtension: String
        let summary: String
        let terms: [String]
        let destinationPath: String
        let outcome: String
        let createdAt: Date
        let proposedFileName: String?
        let approvedFileName: String?
    }

    private var rules: [Rule]
    private var novelClusters: [NovelCluster]
    private var trainingEvents: [TrainingEvent]
    private let defaults: UserDefaults
    private let key = "learningRules.v2"
    private let legacyKey = "learningRules.v1"
    private let clusterKey = "novelThemeClusters.v3"
    private let eventKey = "personalTrainingEvents.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedEvents: [TrainingEvent]
        if let data = defaults.data(forKey: eventKey),
           let decoded = try? JSONDecoder().decode([TrainingEvent].self, from: data) {
            loadedEvents = decoded
        } else {
            loadedEvents = []
        }
        trainingEvents = loadedEvents

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = decoded
        } else if !loadedEvents.isEmpty {
            // v1 merged every approved file of the same extension and target
            // into one ever-growing bag of terms. Rebuild from the immutable
            // training log into multiple topic clusters instead.
            rules = Self.rebuildRules(from: loadedEvents)
            defaults.set(try? JSONEncoder().encode(rules), forKey: key)
        } else if let data = defaults.data(forKey: legacyKey),
                  let decoded = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        if let data = defaults.data(forKey: clusterKey),
           let decoded = try? JSONDecoder().decode([NovelCluster].self, from: data) {
            novelClusters = decoded
        } else {
            novelClusters = []
        }
    }

    var summary: String {
        let approvals = rules.reduce(0) { $0 + $1.approvals }
        let rejections = rules.reduce(0) { $0 + $1.rejections }
        let namingCorrections = trainingEvents.filter {
            guard let approved = $0.approvedFileName else { return false }
            return approved != $0.fileName
        }.count
        return "已积累 \(trainingEvents.count) 条个人训练样本（\(approvals) 次确认、\(rejections) 次纠正/拒绝、\(namingCorrections) 次命名样本），形成 \(rules.count) 条本地记忆"
    }

    var preferredFileNameSeparator: String {
        var counts = ["_": 0, " - ": 0, "-": 0, " ": 0]
        for event in trainingEvents {
            guard let name = event.approvedFileName,
                  name != event.fileName
            else { continue }
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            if base.contains("_") { counts["_", default: 0] += 1 }
            else if base.contains(" - ") { counts[" - ", default: 0] += 1 }
            else if base.contains("-") { counts["-", default: 0] += 1 }
            else if base.contains(" ") { counts[" ", default: 0] += 1 }
        }
        let winner = counts.max { lhs, rhs in lhs.value < rhs.value }
        return (winner?.value ?? 0) >= 2 ? winner!.key : "_"
    }

    func recommendation(for source: URL, content: ExtractedContent, roots: [URL]) -> Recommendation? {
        let terms = queryTerms(source: source, content: content)
        let ext = source.pathExtension.lowercased()
        let candidates = rules.compactMap { rule -> (Rule, Double)? in
            guard rule.approvals > rule.rejections else { return nil }
            let destination = URL(fileURLWithPath: rule.destinationPath, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: destination.path),
                  roots.contains(where: { root in
                      let rootPath = root.standardizedFileURL.path
                      return destination.path == rootPath || destination.path.hasPrefix(rootPath + "/")
                  })
            else { return nil }
            let memoryTerms = Set(rule.terms)
            let shared = terms.intersection(memoryTerms)
            guard shared.count >= 2 else { return nil }
            let coverage = Double(shared.count) / Double(max(1, terms.count))
            let specificity = Double(shared.count) / Double(max(1, memoryTerms.count))
            let lexical = coverage * 0.72 + specificity * 0.28
            let extensionBonus = !ext.isEmpty && ext == rule.fileExtension ? 0.055 : 0
            let approvalBonus = min(0.16, log1p(Double(rule.approvals)) * 0.055)
            let rejectionPenalty = negativePenalty(
                for: terms,
                destinationPath: rule.destinationPath,
                fileExtension: ext
            )
            return (rule, lexical + extensionBonus + approvalBonus - rejectionPenalty)
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first, best.1 >= 0.24 else { return nil }
        let second = candidates.dropFirst().first?.1 ?? 0
        let margin = best.1 - second
        guard margin >= 0.055 || (best.0.approvals >= 3 && best.1 >= 0.42) else { return nil }
        let confidence = min(0.97, 0.57 + best.1 * 0.31 + margin * 0.20)
        return Recommendation(
            destination: URL(fileURLWithPath: best.0.destinationPath, isDirectory: true),
            confidence: confidence,
            evidence: "检索到 \(best.0.approvals) 次相似归档记忆，且领先其他记忆 \(Int(margin * 100)) 分",
            approvals: best.0.approvals,
            rejections: best.0.rejections
        )
    }

    func record(
        source: URL,
        summary: String,
        destination: URL,
        proposedFileName: String? = nil,
        approvedFileName: String? = nil
    ) {
        let terms = tokenSet("\(source.deletingPathExtension().lastPathComponent) \(summary)")
        updateRule(
            fileExtension: source.pathExtension.lowercased(),
            terms: terms,
            destinationPath: destination.standardizedFileURL.path,
            approved: true,
            at: Date()
        )
        persistRules()
        appendTrainingEvent(
            source: source,
            summary: summary,
            destination: destination,
            outcome: "approved",
            proposedFileName: proposedFileName,
            approvedFileName: approvedFileName
        )
    }

    func recordRejection(source: URL, summary: String, destination: URL) {
        let terms = tokenSet("\(source.deletingPathExtension().lastPathComponent) \(summary)")
        updateRule(
            fileExtension: source.pathExtension.lowercased(),
            terms: terms,
            destinationPath: destination.standardizedFileURL.path,
            approved: false,
            at: Date()
        )
        persistRules()
        appendTrainingEvent(source: source, summary: summary, destination: destination, outcome: "rejected")
    }

    /// A new folder becomes eligible only after three distinct files with a
    /// similar topic have accumulated. One unfamiliar file can never create a
    /// one-off directory.
    func observeNovelTheme(source: URL, content: ExtractedContent, topic: String) -> Bool {
        guard topic != "待整理" else { return false }
        let terms = queryTerms(source: source, content: content)
        let sourcePath = source.standardizedFileURL.path
        let index = novelClusters.indices.max { lhs, rhs in
            clusterSimilarity(novelClusters[lhs], topic: topic, terms: terms)
                < clusterSimilarity(novelClusters[rhs], topic: topic, terms: terms)
        }
        if let index, clusterSimilarity(novelClusters[index], topic: topic, terms: terms) >= 0.28 {
            novelClusters[index].terms = Array(Set(novelClusters[index].terms).union(terms).prefix(120))
            if !novelClusters[index].sourcePaths.contains(sourcePath) {
                novelClusters[index].sourcePaths.append(sourcePath)
            }
            novelClusters[index].sourcePaths = Array(novelClusters[index].sourcePaths.suffix(20))
            novelClusters[index].updatedAt = Date()
            persistClusters()
            return novelClusters[index].sourcePaths.count >= 3
        }
        novelClusters.append(NovelCluster(
            topic: topic,
            terms: Array(terms.prefix(80)),
            sourcePaths: [sourcePath],
            updatedAt: Date()
        ))
        novelClusters = Array(novelClusters.sorted { $0.updatedAt > $1.updatedAt }.prefix(100))
        persistClusters()
        return false
    }

    func reset() {
        rules.removeAll()
        novelClusters.removeAll()
        trainingEvents.removeAll()
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: clusterKey)
        defaults.removeObject(forKey: eventKey)
    }

    private func queryTerms(source: URL, content: ExtractedContent) -> Set<String> {
        tokenSet("\(source.deletingPathExtension().lastPathComponent) \(content.summary) \(content.entities.joined(separator: " "))")
    }

    private func clusterSimilarity(_ cluster: NovelCluster, topic: String, terms: Set<String>) -> Double {
        guard cluster.topic == topic else { return 0 }
        let known = Set(cluster.terms)
        let union = max(1, terms.union(known).count)
        return 0.55 + 0.45 * Double(terms.intersection(known).count) / Double(union)
    }

    private func updateRule(
        fileExtension: String,
        terms: Set<String>,
        destinationPath: String,
        approved: Bool,
        at date: Date
    ) {
        let eligible = rules.indices.filter {
            rules[$0].fileExtension == fileExtension && rules[$0].destinationPath == destinationPath
        }
        let ranked = eligible.map { index in
            (index, Self.jaccard(terms, Set(rules[index].terms)))
        }.sorted { $0.1 > $1.1 }
        let threshold = approved ? 0.18 : 0.12
        if let best = ranked.first, best.1 >= threshold {
            let index = best.0
            rules[index].terms = Array(Set(rules[index].terms).union(terms).prefix(100))
            if approved {
                rules[index].approvals += 1
                rules[index].rejections = max(0, rules[index].rejections - 1)
            } else {
                rules[index].rejections += 1
            }
            rules[index].updatedAt = date
        } else {
            rules.append(Rule(
                fileExtension: fileExtension,
                terms: Array(terms.prefix(100)),
                destinationPath: destinationPath,
                approvals: approved ? 1 : 0,
                rejections: approved ? 0 : 1,
                updatedAt: date
            ))
        }
    }

    private func negativePenalty(for terms: Set<String>, destinationPath: String, fileExtension: String) -> Double {
        rules.filter {
            $0.destinationPath == destinationPath
                && $0.fileExtension == fileExtension
                && $0.rejections > 0
        }.reduce(0.0) { penalty, rule in
            let similarity = Self.jaccard(terms, Set(rule.terms))
            guard similarity >= 0.12 else { return penalty }
            let strength = min(0.62, Double(rule.rejections) * 0.22)
            return max(penalty, similarity * strength)
        }
    }

    private static func rebuildRules(from events: [TrainingEvent]) -> [Rule] {
        var result: [Rule] = []
        for event in events.sorted(by: { $0.createdAt < $1.createdAt }) {
            let terms = Set(event.terms)
            let eligible = result.indices.filter {
                result[$0].fileExtension == event.fileExtension
                    && result[$0].destinationPath == event.destinationPath
            }
            let ranked = eligible.map { index in
                (index, jaccard(terms, Set(result[index].terms)))
            }.sorted { $0.1 > $1.1 }
            let approved = event.outcome == "approved"
            let threshold = approved ? 0.18 : 0.12
            if let best = ranked.first, best.1 >= threshold {
                let index = best.0
                result[index].terms = Array(Set(result[index].terms).union(terms).prefix(100))
                if approved { result[index].approvals += 1 } else { result[index].rejections += 1 }
                result[index].updatedAt = event.createdAt
            } else {
                result.append(Rule(
                    fileExtension: event.fileExtension,
                    terms: Array(terms.prefix(100)),
                    destinationPath: event.destinationPath,
                    approvals: approved ? 1 : 0,
                    rejections: approved ? 0 : 1,
                    updatedAt: event.createdAt
                ))
            }
        }
        return Array(result.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private func persistRules() {
        rules = Array(rules.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
        defaults.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    private func persistClusters() {
        defaults.set(try? JSONEncoder().encode(novelClusters), forKey: clusterKey)
    }

    private func appendTrainingEvent(
        source: URL,
        summary: String,
        destination: URL,
        outcome: String,
        proposedFileName: String? = nil,
        approvedFileName: String? = nil
    ) {
        trainingEvents.append(TrainingEvent(
            id: UUID(),
            fileName: source.lastPathComponent,
            fileExtension: source.pathExtension.lowercased(),
            summary: String(summary.prefix(1_500)),
            terms: Array(tokenSet("\(source.deletingPathExtension().lastPathComponent) \(summary)").prefix(120)),
            destinationPath: destination.standardizedFileURL.path,
            outcome: outcome,
            createdAt: Date(),
            proposedFileName: proposedFileName,
            approvedFileName: approvedFileName
        ))
        trainingEvents = Array(trainingEvents.suffix(2_000))
        defaults.set(try? JSONEncoder().encode(trainingEvents), forKey: eventKey)
    }

    private func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
    }
}
