import Foundation
import NaturalLanguage

enum FolderAuditEngine {
    static func candidateEntries(in folder: URL, limit: Int = 80) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return contents.compactMap { url -> (URL, Date)? in
            guard !url.lastPathComponent.hasPrefix("."),
                  !auditIgnoredNames.contains(url.lastPathComponent.lowercased()),
                  !FolderMonitor.shouldIgnore(path: url.path),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true || values.isDirectory == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    static func candidateFiles(in folder: URL, limit: Int = 80) -> [URL] {
        candidateEntries(in: folder, limit: limit).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// A child directory participates in the same audit as a file. Its theme
    /// is represented by a bounded, extension-diverse sample of descendants,
    /// which lets the audit find a misplaced project folder such as an
    /// economics corpus living under a language root.
    static func auditDocument(for entry: URL, sampleLimit: Int = 10) async -> FolderAuditDocument {
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            return FolderAuditDocument(url: entry, content: await ContentExtractor.extract(from: entry))
        }

        let sample = representativeFiles(in: entry, limit: sampleLimit)
        var textParts = [entry.lastPathComponent]
        var summaries: [String] = []
        var entities = Set<String>()
        for file in sample {
            let extracted = await ContentExtractor.extract(from: file)
            textParts.append(file.deletingPathExtension().lastPathComponent)
            textParts.append(String(extracted.text.prefix(2_000)))
            summaries.append(extracted.summary)
            entities.formUnion(extracted.entities)
        }
        return FolderAuditDocument(
            url: entry,
            content: ExtractedContent(
                text: textParts.joined(separator: " "),
                kind: "文件夹主题样本（\(sample.count) 个文件）",
                summary: summaries.prefix(4).joined(separator: "；"),
                signals: ["递归抽样", "子文件夹主题"],
                entities: Array(entities.prefix(40))
            )
        )
    }

    static func findOutliers(
        in documents: [FolderAuditDocument],
        parentFolder: URL? = nil
    ) -> [FolderAuditOutlier] {
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
        var findings = documents.indices
            .filter { similarities[$0] < threshold && median - similarities[$0] >= 0.14 }
            .sorted { similarities[$0] < similarities[$1] }
            .map { index in
                FolderAuditOutlier(
                    document: documents[index],
                    similarity: similarities[index],
                    medianSimilarity: median,
                    commonTerms: commonTerms
                )
            }

        // Directory placement has an intent channel that lexical centroids do
        // not capture. A code-heavy economics project and a code-heavy
        // language project can look alike as bags of tokens, while the child
        // folder's subject plainly conflicts with a parent named "lang".
        if let parentFolder,
           let parentSubject = AcademicSubjectClassifier.classify(
            title: parentFolder.lastPathComponent,
            body: ""
           ) {
            for document in documents {
                let isDirectory = (try? document.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    || document.content.signals.contains("子文件夹主题")
                guard isDirectory,
                      let childSubject = AcademicSubjectClassifier.classify(
                        source: document.url, content: document.content
                      ),
                      childSubject.folderName != parentSubject.folderName,
                      childSubject.confidence >= 0.72
                else { continue }
                findings.removeAll { $0.document.url.standardizedFileURL == document.url.standardizedFileURL }
                findings.append(FolderAuditOutlier(
                    document: document,
                    similarity: 0,
                    medianSimilarity: median,
                    commonTerms: ["父目录：\(parentSubject.folderName)", "子目录：\(childSubject.folderName)"]
                ))
            }
        }
        return Array(findings.sorted { $0.similarity < $1.similarity }.prefix(maximumFindings))
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

    private static func representativeFiles(in folder: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var candidates: [(URL, Date)] = []
        while let file = enumerator.nextObject() as? URL, candidates.count < 320 {
            if FolderMonitor.shouldIgnore(path: file.path) {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            ), values.isRegularFile == true, (values.fileSize ?? 0) <= 80_000_000 else { continue }
            candidates.append((file, values.contentModificationDate ?? .distantPast))
        }
        let recent = candidates.sorted { $0.1 > $1.1 }
        var selected: [URL] = []
        var seenExtensions = Set<String>()
        for candidate in recent where selected.count < limit {
            let ext = candidate.0.pathExtension.lowercased()
            if seenExtensions.insert(ext).inserted { selected.append(candidate.0) }
        }
        for candidate in recent where selected.count < limit && !selected.contains(candidate.0) {
            selected.append(candidate.0)
        }
        return selected
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

    private static let auditIgnoredNames: Set<String> = [
        "__pycache__", "node_modules", ".git", ".build", "deriveddata", "logs", "tmp", "temp"
    ]
}
