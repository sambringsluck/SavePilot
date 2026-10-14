import Foundation
import NaturalLanguage
import PDFKit

struct FolderKnowledgeProfile: Codable, Sendable {
    let path: String
    let weights: [String: Double]
    let extensions: [String]
    let sampledFiles: Int
    let consideredFiles: Int
    let dominantFiles: Int
    let coherence: Double
    let hyperedges: [FolderKnowledgeHyperedge]
    let updatedAt: Date
}

struct FolderKnowledgeHyperedge: Codable, Sendable {
    let documentName: String
    let members: [String]
    let fileExtension: String
}

struct FolderKnowledgeRecommendation: Sendable {
    let destination: URL
    let score: Double
    let margin: Double
    let evidenceTerms: [String]
}

enum FolderKnowledgeIndex {
    private static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "pdf", "docx", "pptx", "xlsx", "pages",
        "csv", "tsv", "html", "htm", "json", "jsonl", "yaml", "yml", "tex"
    ]

    static func load() -> [FolderKnowledgeProfile] {
        guard let data = try? Data(contentsOf: storageURL),
              let profiles = try? JSONDecoder().decode([FolderKnowledgeProfile].self, from: data)
        else { return [] }
        return profiles.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func save(_ profiles: [FolderKnowledgeProfile]) {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(profiles).write(to: storageURL, options: .atomic)
        } catch {
            // A stale or unavailable index must not block normal suggestions.
        }
    }

    static func build(roots: [URL]) async -> [FolderKnowledgeProfile] {
        let folders = candidateFolders(in: roots, perRootLimit: 24)
        var profiles: [FolderKnowledgeProfile] = []
        for start in stride(from: 0, to: folders.count, by: 4) {
            let chunk = Array(folders[start..<min(start + 4, folders.count)])
            let values = await withTaskGroup(of: FolderKnowledgeProfile?.self) { group in
                for folder in chunk {
                    group.addTask { await buildProfile(folder: folder) }
                }
                var result: [FolderKnowledgeProfile] = []
                for await profile in group {
                    if let profile { result.append(profile) }
                }
                return result
            }
            profiles.append(contentsOf: values)
        }
        return profiles
    }

    static func recommend(
        source: URL,
        content: ExtractedContent,
        profiles: [FolderKnowledgeProfile],
        excludingFolders: Set<String> = []
    ) -> FolderKnowledgeRecommendation? {
        let usable = profiles.filter { profile in
            let path = URL(fileURLWithPath: profile.path).standardizedFileURL.path
            return !excludingFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
                && path != source.deletingLastPathComponent().standardizedFileURL.path
        }
        guard usable.count >= 2 else { return nil }

        let queryCounts = tokenCounts(
            "\(source.deletingPathExtension().lastPathComponent) \(content.summary) \(content.entities.joined(separator: " ")) \(String(content.text.prefix(8_000)))"
        )
        guard !queryCounts.isEmpty else { return nil }

        var documentFrequency: [String: Int] = [:]
        for profile in usable {
            for term in profile.weights.keys { documentFrequency[term, default: 0] += 1 }
        }
        let totalProfiles = Double(usable.count)
        let queryTotal = Double(max(1, queryCounts.values.reduce(0, +)))
        var query: [String: Double] = [:]
        for (term, count) in queryCounts {
            let idf = log((totalProfiles + 1) / (Double(documentFrequency[term, default: 0]) + 1)) + 1
            query[term] = Double(count) / queryTotal * idf
        }
        query = normalized(query)

        let sourceExtension = source.pathExtension.lowercased()
        let sourceNameTerms = Set(tokenCounts(source.deletingPathExtension().lastPathComponent).keys)
        let ranked = usable.map { profile -> (FolderKnowledgeProfile, Double, [String]) in
            var profileVector: [String: Double] = [:]
            for (term, weight) in profile.weights {
                let idf = log((totalProfiles + 1) / (Double(documentFrequency[term, default: 1]) + 1)) + 1
                profileVector[term] = weight * idf
            }
            profileVector = normalized(profileVector)
            let semanticScore = cosine(query, profileVector)
            let queryMembers = Set(
                content.entities.flatMap { tokenCounts($0).keys }
                + queryCounts.sorted { $0.value > $1.value }.prefix(36).map(\.key)
            )
            let hypergraphScore = profile.hyperedges.reduce(0.0) { current, edge in
                let members = Set(edge.members)
                let shared = queryMembers.intersection(members)
                guard shared.count >= 2 else { return current }
                let edgeScore = pow(Double(shared.count), 1.35)
                    / sqrt(Double(max(1, queryMembers.count * members.count)))
                return max(current, edgeScore)
            }
            var score = semanticScore * 0.74 + hypergraphScore * 0.26
            let pathTerms = Set(tokenCounts(
                URL(fileURLWithPath: profile.path).pathComponents.suffix(2).joined(separator: " ")
            ).keys)
            let explicitPathOverlap = sourceNameTerms.intersection(pathTerms).count
            score += min(0.12, Double(explicitPathOverlap) * 0.06)
            score *= 0.78 + min(0.22, profile.coherence * 0.22)
            if !sourceExtension.isEmpty, profile.extensions.contains(sourceExtension) { score += 0.035 }
            if profile.sampledFiles >= 2,
               !sourceExtension.isEmpty,
               !profile.extensions.contains(sourceExtension) { score -= 0.025 }
            let evidence = query.keys
                .filter { profileVector[$0] != nil }
                .sorted { (query[$0] ?? 0) * (profileVector[$0] ?? 0) > (query[$1] ?? 0) * (profileVector[$1] ?? 0) }
            return (profile, score, Array(evidence.prefix(6)))
        }.sorted { $0.1 > $1.1 }

        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.1 ?? 0
        let margin = best.1 - second
        // Routing is deliberately conservative: a folder must be a clear winner,
        // otherwise retaining the current location is safer than a confident-looking mistake.
        guard best.1 >= 0.085, margin >= 0.03, best.2.count >= 2 else { return nil }
        return FolderKnowledgeRecommendation(
            destination: URL(fileURLWithPath: best.0.path, isDirectory: true),
            score: min(0.98, best.1),
            margin: margin,
            evidenceTerms: best.2
        )
    }

    static func buildProfile(folder: URL) async -> FolderKnowledgeProfile? {
        let candidates = sampleFiles(in: folder, limit: 10)
        guard !candidates.isEmpty else { return nil }
        var documents: [(url: URL, counts: [String: Int])] = []
        var extensions: Set<String> = []

        func extract(_ files: ArraySlice<URL>) async {
            for file in files {
                extensions.insert(file.pathExtension.lowercased())
                let text = lightweightText(from: file)
                let entities = AdvancedExtractors.linguisticInsights(for: text).entities
                let sample = "\(file.deletingPathExtension().lastPathComponent) \(entities.joined(separator: " ")) \(String(text.prefix(8_000)))"
                documents.append((file, tokenCounts(sample)))
            }
        }

        let initialCount = min(3, candidates.count)
        await extract(candidates.prefix(initialCount))
        let initialCoherence = coherence(of: documents.map(\.counts))
        if candidates.count > initialCount, initialCoherence < 0.22 {
            await extract(candidates.dropFirst(initialCount))
        }

        let vectors = documents.map { normalizedCounts($0.counts) }
        let medoidIndex = dominantMedoidIndex(vectors)
        let similarities = vectors.map { cosine($0, vectors[medoidIndex]) }
        let desiredMajority = max(1, Int(ceil(Double(vectors.count) * 0.6)))
        let rankedIndices = similarities.indices.sorted { similarities[$0] > similarities[$1] }
        var dominantIndices = rankedIndices.filter { similarities[$0] >= 0.14 }
        if dominantIndices.count < desiredMajority {
            dominantIndices = Array(rankedIndices.prefix(desiredMajority))
        }

        var counts = tokenCounts(folder.pathComponents.suffix(2).joined(separator: " "))
        for index in dominantIndices {
            let file = documents[index].url
            extensions.insert(file.pathExtension.lowercased())
            for (term, count) in documents[index].counts {
                counts[term, default: 0] += count
            }
        }
        let total = Double(max(1, counts.values.reduce(0, +)))
        let top = counts.sorted { $0.value > $1.value }.prefix(360)
        let hyperedges = dominantIndices.map { index -> FolderKnowledgeHyperedge in
            let document = documents[index]
            let members = document.counts
                .sorted { $0.value > $1.value }
                .prefix(24)
                .map(\.key)
            return FolderKnowledgeHyperedge(
                documentName: document.url.lastPathComponent,
                members: members,
                fileExtension: document.url.pathExtension.lowercased()
            )
        }
        return FolderKnowledgeProfile(
            path: folder.standardizedFileURL.path,
            weights: Dictionary(uniqueKeysWithValues: top.map { ($0.key, Double($0.value) / total) }),
            extensions: Array(extensions).sorted(),
            sampledFiles: documents.count,
            consideredFiles: candidates.count,
            dominantFiles: dominantIndices.count,
            coherence: coherence(of: dominantIndices.map { documents[$0].counts }),
            hyperedges: hyperedges,
            updatedAt: Date()
        )
    }

    private static func normalizedCounts(_ counts: [String: Int]) -> [String: Double] {
        normalized(counts.mapValues(Double.init))
    }

    private static func coherence(of documents: [[String: Int]]) -> Double {
        guard documents.count > 1 else { return 1 }
        let vectors = documents.map(normalizedCounts)
        var total = 0.0
        var pairs = 0
        for lhs in 0..<vectors.count {
            for rhs in (lhs + 1)..<vectors.count {
                total += cosine(vectors[lhs], vectors[rhs])
                pairs += 1
            }
        }
        return pairs == 0 ? 1 : total / Double(pairs)
    }

    private static func dominantMedoidIndex(_ vectors: [[String: Double]]) -> Int {
        guard vectors.count > 1 else { return 0 }
        return vectors.indices.max { lhs, rhs in
            let lhsScore = vectors.indices.reduce(0.0) { $0 + cosine(vectors[lhs], vectors[$1]) }
            let rhsScore = vectors.indices.reduce(0.0) { $0 + cosine(vectors[rhs], vectors[$1]) }
            return lhsScore < rhsScore
        } ?? 0
    }

    private static func candidateFolders(in roots: [URL], perRootLimit: Int) -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            var candidates: [(URL, Int, Date)] = []
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathComponents.count - root.pathComponents.count > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .contentModificationDateKey])
                guard values?.isDirectory == true,
                      values?.isHidden != true,
                      !FolderMonitor.shouldIgnore(path: url.path)
                else { continue }
            let files = sampleFiles(in: url, limit: 4)
                if !files.isEmpty {
                    candidates.append((url, files.count, values?.contentModificationDate ?? .distantPast))
                }
            }
            // Mix larger established folders with recently active ones.
            candidates.sort {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.2 > $1.2
            }
            for candidate in candidates.prefix(perRootLimit) {
                let path = candidate.0.standardizedFileURL.path
                if seen.insert(path).inserted { result.append(candidate.0) }
            }
        }
        return result
    }

    private static func sampleFiles(in folder: URL, limit: Int) -> [URL] {
        guard let values = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return values.compactMap { url -> (URL, Date)? in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  !FolderMonitor.shouldIgnore(path: url.path),
                  let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  resource.isRegularFile == true,
                  (resource.fileSize ?? 0) <= 80_000_000
            else { return nil }
            return (url, resource.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    /// Indexing deliberately avoids OCR and Quick Look. Those remain enabled
    /// for the one file currently being classified, while a folder refresh
    /// stays bounded and cannot be held hostage by a difficult preview.
    private static func lightweightText(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["docx", "pptx", "xlsx", "pages"].contains(ext) {
            return AdvancedExtractors.extractOfficeText(at: url) ?? ""
        }
        if ext == "pdf", let document = PDFDocument(url: url) {
            return (0..<min(4, document.pageCount)).compactMap { document.page(at: $0)?.string }
                .joined(separator: " ")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 120_000)) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private static func tokenCounts(_ text: String) -> [String: Int] {
        let sample = String(text.prefix(18_000)).lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sample
        var result: [String: Int] = [:]
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { range, _ in
            let token = String(sample[range]).trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if token.count >= 2,
               token.contains(where: { $0.isLetter }),
               !stopWords.contains(token) {
                result[token, default: 0] += 1
            }
            return true
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
        return max(0, smaller.reduce(0) { $0 + $1.value * (larger[$1.key] ?? 0) })
    }

    private static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SavePilot/folder-knowledge-v5.json")
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "were", "have", "has",
        "into", "file", "document", "page", "http", "https", "com", "www", "pdf", "docx", "pptx",
        "model", "article", "student", "students", "figure", "table", "chapter", "chapters", "section",
        "sections", "part", "parts", "version", "content", "ii", "iii", "iv", "li",
        "of", "to", "in", "is", "it", "as", "an", "be", "by", "on", "or", "not", "you", "your",
        "user", "do", "like", "will", "can", "may", "we", "our", "they", "their", "which", "what",
        "when", "where", "who", "how", "why", "also", "than", "then", "all", "any", "each", "other",
        "more", "most", "some", "such", "only", "own", "same", "too", "very", "day", "long",
        "的", "了", "和", "与", "及", "是", "在", "为", "对", "将", "中", "有", "一个", "文件", "文档", "内容",
        "什么", "为什么", "不同", "重要", "问题", "可以", "这个", "没有", "进行", "以及", "通过", "需要"
    ]
}
