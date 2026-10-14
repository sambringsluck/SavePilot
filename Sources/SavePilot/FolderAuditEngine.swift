import Foundation
import NaturalLanguage

enum FolderAuditEngine {
    static func candidateFiles(in folder: URL, limit: Int = 80) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return contents.compactMap { url -> (URL, Date)? in
            guard !FolderMonitor.shouldIgnore(path: url.path),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    static func findOutliers(in documents: [FolderAuditDocument]) -> [FolderAuditOutlier] {
        guard documents.count >= 5 else { return [] }
        let tokenMaps = documents.map { tokenCounts(for: $0) }
        var documentFrequency: [String: Int] = [:]
        for map in tokenMaps {
            for token in map.keys { documentFrequency[token, default: 0] += 1 }
        }

        let count = Double(documents.count)
        let vectors: [[String: Double]] = tokenMaps.map { map in
            let total = max(1, map.values.reduce(0, +))
            var vector: [String: Double] = [:]
            for (token, occurrences) in map {
                let df = Double(documentFrequency[token, default: 1])
                let idf = log((count + 1) / (df + 1)) + 1
                vector[token] = (Double(occurrences) / Double(total)) * idf
            }
            return normalized(vector)
        }

        var centroid: [String: Double] = [:]
        for vector in vectors {
            for (term, weight) in vector { centroid[term, default: 0] += weight / count }
        }
        centroid = normalized(centroid)
        let similarities = vectors.map { cosine($0, centroid) }
        let sorted = similarities.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(0.14, min(0.52, median * 0.58))
        let commonTerms = centroid
            .filter { documentFrequency[$0.key, default: 0] >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map(\.key)

        let maximumFindings = max(1, min(15, documents.count / 4))
        return documents.indices
            .filter { similarities[$0] < threshold && median - similarities[$0] >= 0.14 }
            .sorted { similarities[$0] < similarities[$1] }
            .prefix(maximumFindings)
            .map { index in
                FolderAuditOutlier(
                    document: documents[index],
                    similarity: similarities[index],
                    medianSimilarity: median,
                    commonTerms: commonTerms
                )
            }
    }

    private static func tokenCounts(for document: FolderAuditDocument) -> [String: Int] {
        let input = "\(document.url.deletingPathExtension().lastPathComponent) \(document.content.text) \(document.content.entities.joined(separator: " "))"
        let sample = String(input.prefix(6_000)).lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sample
        var result: [String: Int] = [:]
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { range, _ in
            let token = String(sample[range]).trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if token.count >= 2, !stopWords.contains(token), token.rangeOfCharacter(from: .alphanumerics) != nil {
                result[token, default: 0] += 1
            }
            return true
        }
        if result.isEmpty {
            for token in sample.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where token.count >= 2 {
                let value = String(token)
                if !stopWords.contains(value) { result[value, default: 0] += 1 }
            }
        }
        return result
    }

    private static func normalized(_ vector: [String: Double]) -> [String: Double] {
        let magnitude = sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.mapValues { $0 / magnitude }
    }

    private static func cosine(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        let smaller = lhs.count <= rhs.count ? lhs : rhs
        let larger = lhs.count <= rhs.count ? rhs : lhs
        return max(0, min(1, smaller.reduce(0) { $0 + $1.value * (larger[$1.key] ?? 0) }))
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "were", "have", "has",
        "into", "file", "document", "page", "http", "https", "com", "www", "pdf", "docx", "pptx",
        "的", "了", "和", "与", "及", "是", "在", "为", "对", "将", "中", "有", "一个", "文件", "文档", "内容"
    ]
}
