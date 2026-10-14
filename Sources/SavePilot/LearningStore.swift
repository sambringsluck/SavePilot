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
    }

    private var rules: [Rule]
    private var novelClusters: [NovelCluster]
    private var trainingEvents: [TrainingEvent]
    private let defaults: UserDefaults
    private let key = "learningRules.v1"
    private let clusterKey = "novelThemeClusters.v2"
    private let eventKey = "personalTrainingEvents.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
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
        if let data = defaults.data(forKey: eventKey),
           let decoded = try? JSONDecoder().decode([TrainingEvent].self, from: data) {
            trainingEvents = decoded
        } else {
            trainingEvents = []
        }
    }

    var summary: String {
        let approvals = rules.reduce(0) { $0 + $1.approvals }
        let rejections = rules.reduce(0) { $0 + $1.rejections }
        return "已积累 \(trainingEvents.count) 条个人训练样本（\(approvals) 次确认、\(rejections) 次纠正/拒绝），形成 \(rules.count) 条本地记忆"
    }

    func recommendation(for source: URL, content: ExtractedContent, roots: [URL]) -> Recommendation? {
        let terms = queryTerms(source: source, content: content)
        let ext = source.pathExtension.lowercased()
        let candidates = rules.compactMap { rule -> (Rule, Double)? in
            guard rule.approvals > 0 else { return nil }
            let destination = URL(fileURLWithPath: rule.destinationPath, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: destination.path),
                  roots.contains(where: { destination.path.hasPrefix($0.standardizedFileURL.path) })
            else { return nil }
            let memoryTerms = Set(rule.terms)
            let union = max(1, terms.union(memoryTerms).count)
            let similarity = Double(terms.intersection(memoryTerms).count) / Double(union)
            let extensionBonus = !ext.isEmpty && ext == rule.fileExtension ? 0.22 : 0
            let approvalBonus = min(0.24, log1p(Double(rule.approvals)) * 0.08)
            let rejectionPenalty = min(0.65, Double(rule.rejections) * 0.18)
            return (rule, similarity + extensionBonus + approvalBonus - rejectionPenalty)
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first, best.1 >= 0.34 else { return nil }
        let confidence = min(0.98, 0.62 + best.1 * 0.28)
        return Recommendation(
            destination: URL(fileURLWithPath: best.0.destinationPath, isDirectory: true),
            confidence: confidence,
            evidence: "检索到 \(best.0.approvals) 次相似归档记忆"
        )
    }

    func record(source: URL, summary: String, destination: URL) {
        let terms = Array(tokenSet("\(source.deletingPathExtension().lastPathComponent) \(summary)").prefix(40))
        let ext = source.pathExtension.lowercased()
        if let index = rules.firstIndex(where: {
            $0.fileExtension == ext && $0.destinationPath == destination.standardizedFileURL.path
        }) {
            rules[index].terms = Array(Set(rules[index].terms).union(terms).prefix(80))
            rules[index].approvals += 1
            rules[index].rejections = max(0, rules[index].rejections - 1)
            rules[index].updatedAt = Date()
        } else {
            rules.append(Rule(
                fileExtension: ext,
                terms: terms,
                destinationPath: destination.standardizedFileURL.path,
                approvals: 1,
                rejections: 0,
                updatedAt: Date()
            ))
        }
        rules = Array(rules.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
        defaults.set(try? JSONEncoder().encode(rules), forKey: key)
        appendTrainingEvent(source: source, summary: summary, destination: destination, outcome: "approved")
    }

    func recordRejection(source: URL, summary: String, destination: URL) {
        let terms = Array(tokenSet("\(source.deletingPathExtension().lastPathComponent) \(summary)").prefix(80))
        let ext = source.pathExtension.lowercased()
        if let index = rules.firstIndex(where: {
            $0.fileExtension == ext && $0.destinationPath == destination.standardizedFileURL.path
        }) {
            rules[index].terms = Array(Set(rules[index].terms).union(terms).prefix(120))
            rules[index].rejections += 1
            rules[index].updatedAt = Date()
        } else {
            rules.append(Rule(
                fileExtension: ext,
                terms: terms,
                destinationPath: destination.standardizedFileURL.path,
                approvals: 0,
                rejections: 1,
                updatedAt: Date()
            ))
        }
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
        defaults.removeObject(forKey: clusterKey)
        defaults.removeObject(forKey: eventKey)
    }

    private func queryTerms(source: URL, content: ExtractedContent) -> Set<String> {
        tokenSet("\(source.deletingPathExtension().lastPathComponent) \(content.summary) \(content.entities.joined(separator: " ")) \(content.signals.joined(separator: " ")) \(String(content.text.prefix(1200)))")
    }

    private func clusterSimilarity(_ cluster: NovelCluster, topic: String, terms: Set<String>) -> Double {
        guard cluster.topic == topic else { return 0 }
        let known = Set(cluster.terms)
        let union = max(1, terms.union(known).count)
        return 0.55 + 0.45 * Double(terms.intersection(known).count) / Double(union)
    }

    private func persistRules() {
        rules = Array(rules.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
        defaults.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    private func persistClusters() {
        defaults.set(try? JSONEncoder().encode(novelClusters), forKey: clusterKey)
    }

    private func appendTrainingEvent(source: URL, summary: String, destination: URL, outcome: String) {
        trainingEvents.append(TrainingEvent(
            id: UUID(),
            fileName: source.lastPathComponent,
            fileExtension: source.pathExtension.lowercased(),
            summary: String(summary.prefix(1_500)),
            terms: Array(tokenSet("\(source.deletingPathExtension().lastPathComponent) \(summary)").prefix(120)),
            destinationPath: destination.standardizedFileURL.path,
            outcome: outcome,
            createdAt: Date()
        ))
        trainingEvents = Array(trainingEvents.suffix(2_000))
        defaults.set(try? JSONEncoder().encode(trainingEvents), forKey: eventKey)
    }

    private func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
    }
}
