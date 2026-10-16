import Foundation
import NaturalLanguage

struct DocumentRelationship: Sendable {
    let score: Double
    let sharedTerms: [String]
    let topicName: String?
    let evidence: [String]
}

struct NamedDocumentGroupRecommendation: Sendable {
    let topicName: String
    let peerNames: [String]
    let score: Double
}

/// Models file-to-file affinity independently of where either file currently
/// lives.  Directories are treated as mutable labels, not ground truth.  A
/// high-confidence two-file group needs a structured topic signature; generic
/// lexical similarity needs at least three files before it can redirect them.
enum DocumentRelationshipEngine {
    private struct TopicSignature {
        let folderName: String
        let conceptGroups: [[String]]
        let minimumGroups: Int
    }

    private static let signatures: [TopicSignature] = [
        TopicSignature(
            folderName: "数学建模进阶课",
            conceptGroups: [
                ["投资组合", "资产配置", "portfolio", "asset allocation"],
                ["风险", "波动率", "标准差", "risk", "volatility", "standard deviation"],
                ["收益", "回报", "return", "expected return"],
                ["最优", "优化", "约束", "模型", "optimal", "optimization", "constraint", "markowitz"],
                ["股票", "资产", "银行", "stock", "asset", "bank"]
            ],
            minimumGroups: 4
        ),
        TopicSignature(
            folderName: "IEO经济学竞赛",
            conceptGroups: [
                ["ieo", "international economics olympiad", "国际经济学奥林匹克"],
                ["微观经济", "宏观经济", "microeconomics", "macroeconomics"],
                ["题库", "选拔赛", "真题", "problem set", "competition"],
                ["经济学", "economics", "供给", "需求", "supply", "demand"]
            ],
            minimumGroups: 3
        )
    ]

    static func specificTopicName(for url: URL, content: ExtractedContent) -> String? {
        let text = normalizedText(url: url, content: content)
        let titleTokens = Set(
            url.deletingPathExtension().lastPathComponent.lowercased()
                .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )
        // "sat" is too polysemous to act as a body-level relation signature.
        // It may identify a directory project only when the directory title
        // itself says SAT/PSAT and sampled contents confirm exam material.
        let satTitle = !titleTokens.intersection(["sat", "psat"]).isEmpty
        let satExamSignals = ["question bank", "practice test", "college board", "题库", "真题", "module", "psat"]
            .filter { contains($0, in: text) }.count
        if satTitle, satExamSignals >= 2 { return "SAT备考研究" }
        return signatures.first(where: {
            matchedGroups($0, in: text).count >= $0.minimumGroups
        })?.folderName
    }

    static func compare(
        lhsURL: URL,
        lhs: ExtractedContent,
        rhsURL: URL,
        rhs: ExtractedContent
    ) -> DocumentRelationship? {
        let lhsText = normalizedText(url: lhsURL, content: lhs)
        let rhsText = normalizedText(url: rhsURL, content: rhs)

        for signature in signatures {
            let left = matchedGroups(signature, in: lhsText)
            let right = matchedGroups(signature, in: rhsText)
            let sharedGroups = left.intersection(right)
            if left.count >= signature.minimumGroups,
               right.count >= signature.minimumGroups,
               sharedGroups.count >= signature.minimumGroups {
                let evidence = sharedGroups.sorted().map { group in
                    signature.conceptGroups[group].first(where: {
                        contains($0, in: lhsText) && contains($0, in: rhsText)
                    }) ?? signature.conceptGroups[group][0]
                }
                return DocumentRelationship(
                    score: min(0.97, 0.76 + Double(sharedGroups.count) * 0.04),
                    sharedTerms: Array(evidence.prefix(8)),
                    topicName: signature.folderName,
                    evidence: ["结构化主题签名", "跨目录正文关联"]
                )
            }
        }

        let leftCounts = tokenCounts(lhsText)
        let rightCounts = tokenCounts(rhsText)
        let left = Set(leftCounts.keys)
        let right = Set(rightCounts.keys)
        let shared = left.intersection(right)
        guard shared.count >= 4 else { return nil }
        let containment = Double(shared.count) / Double(max(1, min(left.count, right.count)))
        let union = Double(max(1, left.union(right).count))
        let jaccard = Double(shared.count) / union
        let cosine = cosineSimilarity(leftCounts, rightCounts)
        let score = cosine * 0.50 + containment * 0.34 + jaccard * 0.16
        guard score >= 0.34 else { return nil }
        let ranked = shared.sorted {
            (leftCounts[$0, default: 0] + rightCounts[$0, default: 0])
                > (leftCounts[$1, default: 0] + rightCounts[$1, default: 0])
        }
        return DocumentRelationship(
            score: min(0.90, score),
            sharedTerms: Array(ranked.prefix(8)),
            topicName: nil,
            evidence: ["正文关键词", "文件级余弦相似度"]
        )
    }

    /// Resolve a structured project relation against the already extracted
    /// corpus before a suggestion is shown. This prevents a weak directory
    /// match from flashing first and being corrected only after its peer is
    /// processed later in the queue.
    static func namedRecommendation(
        for source: URL,
        content: ExtractedContent,
        corpus: [String: ExtractedContent]
    ) -> NamedDocumentGroupRecommendation? {
        var matches: [String: [(name: String, score: Double)]] = [:]
        let sourcePath = source.standardizedFileURL.path
        for (path, peerContent) in corpus where path != sourcePath {
            let peerURL = URL(fileURLWithPath: path)
            guard let relation = compare(
                lhsURL: source, lhs: content,
                rhsURL: peerURL, rhs: peerContent
            ), let topic = relation.topicName, relation.score >= 0.80 else { continue }
            matches[topic, default: []].append((peerURL.deletingPathExtension().lastPathComponent, relation.score))
        }
        let ranked = matches.map { topic, peers in
            (
                topic: topic,
                peers: peers,
                strength: peers.reduce(0) { $0 + $1.score } / Double(peers.count)
            )
        }.sorted {
            if $0.peers.count != $1.peers.count { return $0.peers.count > $1.peers.count }
            return $0.strength > $1.strength
        }
        guard let best = ranked.first else { return nil }
        // Abstain when two project signatures have the same support and
        // nearly identical strength instead of making an arbitrary choice.
        if let second = ranked.dropFirst().first,
           second.peers.count == best.peers.count,
           best.strength - second.strength < 0.04 { return nil }
        return NamedDocumentGroupRecommendation(
            topicName: best.topic,
            peerNames: Array(best.peers.sorted { $0.score > $1.score }.prefix(3).map(\.name)),
            score: best.strength
        )
    }

    private static func normalizedText(url: URL, content: ExtractedContent) -> String {
        "\(url.deletingPathExtension().lastPathComponent) \(content.summary) \(content.entities.joined(separator: " ")) \(String(content.text.prefix(12_000)))"
            .lowercased()
    }

    private static func matchedGroups(_ signature: TopicSignature, in text: String) -> Set<Int> {
        Set(signature.conceptGroups.indices.filter { index in
            signature.conceptGroups[index].contains { contains($0, in: text) }
        })
    }

    private static func contains(_ signal: String, in text: String) -> Bool {
        let signal = signal.lowercased()
        if signal.contains(" ") || signal.contains(where: { !$0.isASCII }) {
            return text.contains(signal)
        }
        return Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init)).contains(signal)
    }

    private static func tokenCounts(_ text: String) -> [String: Double] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var counts: [String: Double] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).lowercased()
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if token.count >= 2,
               token.rangeOfCharacter(from: .alphanumerics) != nil,
               !stopWords.contains(token) {
                counts[token, default: 0] += 1
            }
            return true
        }
        return counts.mapValues { 1 + log($0) }
    }

    private static func cosineSimilarity(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        let lhsNorm = sqrt(lhs.values.reduce(0) { $0 + $1 * $1 })
        let rhsNorm = sqrt(rhs.values.reduce(0) { $0 + $1 * $1 })
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        let smaller = lhs.count <= rhs.count ? lhs : rhs
        let larger = lhs.count <= rhs.count ? rhs : lhs
        return smaller.reduce(0) { $0 + $1.value * (larger[$1.key] ?? 0) } / (lhsNorm * rhsNorm)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "were", "have", "has",
        "into", "file", "document", "page", "http", "https", "com", "www", "model", "article",
        "chapter", "section", "part", "content", "type", "role", "message", "response", "question",
        "export", "scan", "scanned", "img", "image",
        "author", "unknown", "final", "draft", "copyright", "footer", "header", "generated",
        "answer", "user", "assistant", "conversation", "because", "about", "which", "their", "there",
        "的", "了", "和", "与", "及", "是", "在", "为", "对", "将", "中", "有", "一个", "文件",
        "文档", "内容", "问题", "回答", "用户", "可以", "这个", "进行", "需要", "我们", "认为"
    ]
}

enum RelatedFileConsensus {
    static func consolidate(
        _ suggestions: [FileSuggestion],
        contents: [String: ExtractedContent],
        roots: [URL]
    ) -> [FileSuggestion] {
        guard suggestions.count >= 2, let root = roots.first?.standardizedFileURL else { return suggestions }
        var result = suggestions
        var edges: [(left: Int, right: Int, relation: DocumentRelationship)] = []

        for left in result.indices {
            guard let lhs = contents[result[left].source.standardizedFileURL.path] else { continue }
            for right in result.indices where right > left {
                guard let rhs = contents[result[right].source.standardizedFileURL.path],
                      let relation = DocumentRelationshipEngine.compare(
                        lhsURL: result[left].source, lhs: lhs,
                        rhsURL: result[right].source, rhs: rhs
                      )
                else { continue }
                edges.append((left, right, relation))
            }
        }

        func components(for selected: [(left: Int, right: Int)]) -> [[Int]] {
            var adjacency: [Int: Set<Int>] = [:]
            for edge in selected {
                adjacency[edge.left, default: []].insert(edge.right)
                adjacency[edge.right, default: []].insert(edge.left)
            }
            var groups: [[Int]] = []
            var visited = Set<Int>()
            for start in adjacency.keys where !visited.contains(start) {
                var queue = [start]
                var component: [Int] = []
                while let current = queue.popLast() {
                    guard visited.insert(current).inserted else { continue }
                    component.append(current)
                    queue.append(contentsOf: adjacency[current, default: []])
                }
                groups.append(component)
            }
            return groups
        }

        func apply(component: [Int], folderName: String, edgeKind: String) {
            let target = root.appendingPathComponent(folderName, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: target.path)
            let peerNames = component.map { result[$0].source.deletingPathExtension().lastPathComponent }
            for index in component {
                let original = result[index]
                if original.finalDestinationFolder.standardizedFileURL == target,
                   original.reason.contains("文件关系图（\(edgeKind)）"),
                   original.reason.contains("“\(folderName)”") {
                    continue
                }
                let otherNames = peerNames.filter { $0 != original.source.deletingPathExtension().lastPathComponent }
                result[index] = FileSuggestion(
                    id: original.id,
                    source: original.source,
                    destinationFolder: exists ? target : root,
                    proposedFolderName: exists ? "" : folderName,
                    reason: "文件关系图（\(edgeKind)）：与“\(otherNames.prefix(3).joined(separator: "、"))”形成高置信同主题组，建议共同归入“\(folderName)”。原判断：\(original.reason)",
                    summary: original.summary,
                    confidence: max(0.84, original.confidence),
                    createsFolder: !exists,
                    detectedAt: original.detectedAt,
                    proposedFileName: original.proposedFileName
                )
            }
        }

        // Never let a generic similarity edge bridge an unrelated file into a
        // named project. Topic labels propagate only through edges carrying
        // the exact same structured signature.
        var assigned = Set<Int>()
        let topics = Set(edges.compactMap { edge in
            edge.relation.score >= 0.80 ? edge.relation.topicName : nil
        })
        var namedGroups: [(topic: String, component: [Int], strength: Double)] = []
        for topic in topics {
            let topicEdges = edges.filter {
                $0.relation.topicName == topic && $0.relation.score >= 0.80
            }
            for component in components(for: topicEdges.map { ($0.left, $0.right) }) where component.count >= 2 {
                let nodeSet = Set(component)
                let scores = topicEdges.filter {
                    nodeSet.contains($0.left) && nodeSet.contains($0.right)
                }.map(\.relation.score)
                namedGroups.append((topic, component, scores.reduce(0, +) / Double(max(1, scores.count))))
            }
        }
        for group in namedGroups.sorted(by: {
            if $0.component.count != $1.component.count { return $0.component.count > $1.component.count }
            return $0.strength > $1.strength
        }) where Set(group.component).isDisjoint(with: assigned) {
            apply(component: group.component, folderName: group.topic, edgeKind: "结构化主题边")
            assigned.formUnion(group.component)
        }

        // Generic edges are useful for recurring personal themes but require
        // three mutually connected pending files and cannot touch a file that
        // has already joined a named project component.
        let genericEdges = edges.filter {
            $0.relation.topicName == nil
                && !assigned.contains($0.left) && !assigned.contains($0.right)
        }.map { ($0.left, $0.right) }
        for component in components(for: genericEdges) where component.count >= 3 {
            guard let folderName = reusableGenericName(component, result: result) else { continue }
            apply(component: component, folderName: folderName, edgeKind: "三文件以上普通相似边")
        }
        return result
    }

    private static func reusableGenericName(_ component: [Int], result: [FileSuggestion]) -> String? {
        let names = component.map { result[$0].proposedFolderName }.filter { !$0.isEmpty && $0 != "待整理" }
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        guard let winner = counts.max(by: { $0.value < $1.value }), winner.value >= 2 else { return nil }
        return winner.key
    }
}
