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
    let evidenceChannels: [String]
    let confidence: Double
}

struct FolderHierarchyConflict: Sendable {
    let childPath: String
    let parentPath: String
    let childSubject: String
    let parentSubject: String
    let confidence: Double
}

struct FolderRelocationPlan: Sendable {
    let destinationContainer: URL
    let finalFolderName: String

    var finalFolder: URL {
        destinationContainer.appendingPathComponent(finalFolderName, isDirectory: true)
    }
}

enum FolderKnowledgeIndex {
    private static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "pdf", "docx", "pptx", "xlsx", "pages",
        "csv", "tsv", "html", "htm", "json", "jsonl", "yaml", "yml", "tex"
    ]

    static func load() -> [FolderKnowledgeProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL),
              let profiles = try? decoder.decode([FolderKnowledgeProfile].self, from: data)
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
        let folders = candidateFolders(in: roots, perRootLimit: 36)
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
        let conflictedPaths = Set(hierarchyConflicts(in: profiles).map(\.childPath))
        let initiallyUsable = profiles.filter { profile in
            let path = URL(fileURLWithPath: profile.path).standardizedFileURL.path
            return !excludingFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
                && !conflictedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
                && path != source.deletingLastPathComponent().standardizedFileURL.path
        }

        var queryCounts = tokenCounts(String(content.text.prefix(10_000)))
        mergeCounts(tokenCounts(content.summary), into: &queryCounts, multiplier: 2)
        mergeCounts(tokenCounts(content.entities.joined(separator: " ")), into: &queryCounts, multiplier: 2)
        mergeCounts(tokenCounts(source.deletingPathExtension().lastPathComponent), into: &queryCounts, multiplier: 3)
        guard !queryCounts.isEmpty else { return nil }
        let rawQueryText = "\(source.deletingPathExtension().lastPathComponent) \(content.summary) \(String(content.text.prefix(10_000)))".lowercased()
        let usable = initiallyUsable.filter {
            destinationIntentIsCompatible(
                profile: $0,
                allProfiles: initiallyUsable,
                rawQueryText: rawQueryText
            )
        }
        guard usable.count >= 2 else { return nil }

        var documentFrequency: [String: Int] = [:]
        for profile in usable {
            for term in profile.weights.keys { documentFrequency[term, default: 0] += 1 }
        }
        let totalProfiles = Double(usable.count)
        var query: [String: Double] = [:]
        for (term, count) in queryCounts {
            let idf = log((totalProfiles + 1) / (Double(documentFrequency[term, default: 0]) + 1)) + 1
            // Log-scaled term frequency prevents repeated boilerplate in JSON,
            // transcripts and templates from drowning out rarer topic terms.
            query[term] = (1 + log(Double(max(1, count)))) * idf
        }
        query = normalized(query)

        let sourceExtension = source.pathExtension.lowercased()
        let sourceNameTerms = Set(tokenCounts(source.deletingPathExtension().lastPathComponent).keys)
        let entityTerms = Set(content.entities.flatMap { tokenCounts($0).keys })
        let genericTitleTerms: Set<String> = [
            "report", "final", "draft", "copy", "new", "untitled", "version",
            "image", "photo", "scan", "screenshot", "export"
        ]
        let specificSourceNameTerms = sourceNameTerms.subtracting(genericTitleTerms)
        let scored = usable.map { profile -> (FolderKnowledgeProfile, Double, Double, Double, Double, [String]) in
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
            let pathTerms = Set(tokenCounts(
                URL(fileURLWithPath: profile.path).pathComponents.suffix(2).joined(separator: " ")
            ).keys)
            let explicitPathOverlap = specificSourceNameTerms.intersection(pathTerms).count
            let pathScore = min(0.24, Double(explicitPathOverlap) * 0.12)
            let extensionScore = (!sourceExtension.isEmpty && profile.extensions.contains(sourceExtension)) ? 1.0 : 0.0
            let evidence = query.keys
                .filter { profileVector[$0] != nil }
                .sorted { (query[$0] ?? 0) * (profileVector[$0] ?? 0) > (query[$1] ?? 0) * (profileVector[$1] ?? 0) }
            return (profile, semanticScore, hypergraphScore, pathScore, extensionScore, Array(evidence.prefix(8)))
        }

        let evidenceCandidates = scored.map {
            let hasEntityAnchor = $0.0.hyperedges.contains { edge in
                !entityTerms.intersection(edge.members).isEmpty
            }
            let topicRoutingAllowed = EvidenceRanker.allowsTopicOnlyRouting(
                coherence: $0.0.coherence,
                sampledFiles: $0.0.sampledFiles,
                pathMatch: $0.3
            ) && ($0.0.coherence >= 0.50 || $0.3 >= 0.12 || hasEntityAnchor)
            return FolderEvidenceCandidate(
                identifier: $0.0.path,
                semantic: topicRoutingAllowed ? $0.1 : 0,
                hypergraph: topicRoutingAllowed ? $0.2 : 0,
                pathMatch: $0.3,
                extensionMatch: $0.4,
                coherence: $0.0.coherence * min(1, Double($0.0.sampledFiles) / 4.0),
                evidenceTermCount: $0.5.count
            )
        }
        // A unique literal title-to-path match (especially an acronym such as
        // IEO) is more specific than broad topical similarity. Generic title
        // words are removed above, and we abstain when multiple paths share
        // the same remaining identifier.
        let explicitPath = scored
            .filter { $0.3 >= 0.12 }
            .sorted {
                if $0.3 != $1.3 { return $0.3 > $1.3 }
                return $0.1 > $1.1
            }
        if let best = explicitPath.first {
            let secondPath = explicitPath.dropFirst().first?.3 ?? 0
            if best.3 - secondPath >= 0.10 {
                let pathTerms = Set(tokenCounts(
                    URL(fileURLWithPath: best.0.path).pathComponents.suffix(2).joined(separator: " ")
                ).keys)
                let pathEvidence = specificSourceNameTerms.intersection(pathTerms).sorted()
                let evidence = Array((pathEvidence + best.5).reduce(into: [String]()) { values, term in
                    if !values.contains(term) { values.append(term) }
                }.prefix(8))
                return FolderKnowledgeRecommendation(
                    destination: URL(fileURLWithPath: best.0.path, isDirectory: true),
                    score: min(0.95, 0.56 + best.1),
                    margin: best.3 - secondPath,
                    evidenceTerms: evidence,
                    evidenceChannels: ["文件名/专属目录名", "正文主题"],
                    confidence: min(0.94, 0.72 + best.1 * 0.55)
                )
            }
        }
        let titleInContent = scored.map { candidate -> ((FolderKnowledgeProfile, Double, Double, Double, Double, [String]), [String]) in
            let matches = specificSourceNameTerms.intersection(candidate.0.weights.keys).sorted()
            return (candidate, matches)
        }.filter {
            let hasEntityAnchor = $0.0.0.hyperedges.contains { edge in
                !entityTerms.intersection(edge.members).isEmpty
            }
            return $0.1.count >= 2 && EvidenceRanker.allowsTopicOnlyRouting(
                coherence: $0.0.0.coherence,
                sampledFiles: $0.0.0.sampledFiles,
                pathMatch: $0.0.3
            ) && ($0.0.0.coherence >= 0.50 || $0.0.3 >= 0.12 || hasEntityAnchor)
        }
            .sorted {
                if $0.1.count != $1.1.count { return $0.1.count > $1.1.count }
                return $0.0.1 > $1.0.1
            }
        if let best = titleInContent.first {
            let secondCount = titleInContent.dropFirst().first?.1.count ?? 0
            if best.1.count > secondCount, best.0.1 >= 0.055 {
                let evidence = Array((best.1 + best.0.5).reduce(into: [String]()) { values, term in
                    if !values.contains(term) { values.append(term) }
                }.prefix(8))
                return FolderKnowledgeRecommendation(
                    destination: URL(fileURLWithPath: best.0.0.path, isDirectory: true),
                    score: min(0.95, 0.58 + best.0.1),
                    margin: min(0.24, Double(best.1.count - secondCount) * 0.08),
                    evidenceTerms: evidence,
                    evidenceChannels: ["文件名/目录正文", "正文主题"],
                    confidence: min(0.94, 0.73 + best.0.1 * 0.45)
                )
            }
        }
        // A hyperedge represents terms/entities that co-occurred in one real
        // resident file. A uniquely strong edge is highly specific even when
        // the containing folder mixes several projects and therefore has low
        // global coherence (for example an author name plus a research topic).
        let explicitEdge = scored
            .filter {
                let hasEntityAnchor = $0.0.hyperedges.contains { edge in
                    !entityTerms.intersection(edge.members).isEmpty
                }
                return $0.2 >= 0.12 && $0.1 >= 0.06 && $0.5.count >= 3
                    && EvidenceRanker.allowsTopicOnlyRouting(
                        coherence: $0.0.coherence,
                        sampledFiles: $0.0.sampledFiles,
                        pathMatch: $0.3
                    )
                    && ($0.0.coherence >= 0.50 || $0.3 >= 0.12 || hasEntityAnchor)
            }
            .sorted { $0.2 > $1.2 }
        if let best = explicitEdge.first {
            let secondEdge = explicitEdge.dropFirst().first?.2 ?? 0
            if best.2 - secondEdge >= 0.04 {
                return FolderKnowledgeRecommendation(
                    destination: URL(fileURLWithPath: best.0.path, isDirectory: true),
                    score: min(0.95, 0.58 + best.2),
                    margin: best.2 - secondEdge,
                    evidenceTerms: best.5,
                    evidenceChannels: ["同文件实体超边", "正文主题"],
                    confidence: min(0.94, 0.71 + best.2 * 0.70 + best.1 * 0.25)
                )
            }
        }
        guard let ranking = EvidenceRanker.rank(evidenceCandidates),
              let best = scored.first(where: { $0.0.path == ranking.identifier })
        else { return nil }
        return FolderKnowledgeRecommendation(
            destination: URL(fileURLWithPath: best.0.path, isDirectory: true),
            score: ranking.quality,
            margin: ranking.margin,
            evidenceTerms: best.5,
            evidenceChannels: ranking.channels,
            confidence: ranking.confidence
        )
    }

    /// Builds explicit child-folder -> parent-folder semantic edges. A child
    /// whose stable content subject conflicts with an explicitly named parent
    /// (for example economics material under `lang`) is kept in the index for
    /// auditing, but is not used as a destination until the hierarchy is fixed.
    static func hierarchyConflicts(in profiles: [FolderKnowledgeProfile]) -> [FolderHierarchyConflict] {
        profiles.compactMap { profile in
            guard profile.sampledFiles >= 2 else { return nil }
            let child = URL(fileURLWithPath: profile.path, isDirectory: true).standardizedFileURL
            let parent = child.deletingLastPathComponent()
            guard parent.path != child.path,
                  let parentMatch = AcademicSubjectClassifier.classify(
                    title: parent.lastPathComponent, body: ""
                  )
            else { return nil }
            let body = profile.weights.sorted { $0.value > $1.value }
                .prefix(100).map(\.key).joined(separator: " ")
            let classifiedChild = AcademicSubjectClassifier.classify(
                title: child.lastPathComponent, body: body
            ).map { (subject: $0.folderName, confidence: $0.confidence) }
            let childMatch = classifiedChild ?? projectSubjectHint(
                folderName: child.lastPathComponent, body: body
            )
            guard let childMatch,
                  childMatch.subject != parentMatch.folderName,
                  childMatch.confidence >= 0.70 else { return nil }
            return FolderHierarchyConflict(
                childPath: child.path,
                parentPath: parent.path,
                childSubject: childMatch.subject,
                parentSubject: parentMatch.folderName,
                confidence: min(childMatch.confidence, parentMatch.confidence)
            )
        }
    }

    static func hierarchyConflict(
        containing destination: URL,
        profiles: [FolderKnowledgeProfile]
    ) -> FolderHierarchyConflict? {
        let path = destination.standardizedFileURL.path
        return hierarchyConflicts(in: profiles).first {
            path == $0.childPath || path.hasPrefix($0.childPath + "/")
        }
    }

    static func relocationPlan(
        for conflict: FolderHierarchyConflict,
        root: URL,
        projectName: String?,
        fileManager: FileManager = .default
    ) -> FolderRelocationPlan {
        let child = URL(fileURLWithPath: conflict.childPath, isDirectory: true).standardizedFileURL
        if let projectName {
            let project = root.appendingPathComponent(projectName, isDirectory: true)
            if fileManager.fileExists(atPath: project.path) {
                return FolderRelocationPlan(
                    destinationContainer: project,
                    finalFolderName: child.lastPathComponent
                )
            }
            return FolderRelocationPlan(
                destinationContainer: root,
                finalFolderName: projectName
            )
        }
        return FolderRelocationPlan(
            destinationContainer: root,
            finalFolderName: child.lastPathComponent
        )
    }

    private static func projectSubjectHint(
        folderName: String,
        body: String
    ) -> (subject: String, confidence: Double)? {
        let nameTokens = Set(folderName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let normalizedBody = body.lowercased()
        // Acronyms are accepted only from the folder name and must be
        // independently confirmed by sampled content. This catches a stable
        // project identity without treating incidental body mentions as truth.
        if nameTokens.contains("ieo"),
           ["economics", "economic", "经济", "olympiad", "奥赛"].filter({ normalizedBody.contains($0) }).count >= 2 {
            return ("经济学", 0.90)
        }
        return nil
    }

    static func buildProfile(folder: URL) async -> FolderKnowledgeProfile? {
        let candidates = sampleFiles(in: folder, limit: 24)
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

        let initialCount = min(6, candidates.count)
        await extract(candidates.prefix(initialCount))
        let initialCoherence = coherence(of: documents.map(\.counts))
        if candidates.count > initialCount, initialCoherence < 0.30 {
            await extract(candidates.dropFirst(initialCount))
        }

        let vectors = documents.map { normalizedCounts($0.counts) }
        let medoidIndex = dominantMedoidIndex(vectors)
        let similarities = vectors.map { cosine($0, vectors[medoidIndex]) }
        let desiredMajority = max(1, Int(ceil(Double(vectors.count) * 0.6)))
        let rankedIndices = similarities.indices.sorted { similarities[$0] > similarities[$1] }
        let similarityMedian = similarities.sorted()[similarities.count / 2]
        let dominantThreshold = max(0.08, min(0.24, similarityMedian * 0.62))
        var dominantIndices = rankedIndices.filter { similarities[$0] >= dominantThreshold }
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
        let top = counts.sorted { $0.value > $1.value }.prefix(360)
        let sublinear = top.map { ($0.key, 1 + log(Double(max(1, $0.value)))) }
        let total = max(1, sublinear.reduce(0) { $0 + $1.1 })
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
            weights: Dictionary(uniqueKeysWithValues: sublinear.map { ($0.0, $0.1 / total) }),
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

    /// Project submission folders often contain copied reference material.
    /// Similarity to one of those references does not mean a new document
    /// belongs to the project. Protect the project and its descendants unless
    /// the current file explicitly contains the project anchor.
    private static func destinationIntentIsCompatible(
        profile: FolderKnowledgeProfile,
        allProfiles: [FolderKnowledgeProfile],
        rawQueryText: String
    ) -> Bool {
        let path = URL(fileURLWithPath: profile.path).standardizedFileURL.path
        for container in allProfiles {
            let containerPath = URL(fileURLWithPath: container.path).standardizedFileURL.path
            guard path == containerPath || path.hasPrefix(containerPath + "/"),
                  let anchor = protectedProjectAnchor(
                    URL(fileURLWithPath: containerPath).lastPathComponent
                  )
            else { continue }
            if !rawQueryText.contains(anchor) { return false }
        }
        return true
    }

    private static func protectedProjectAnchor(_ folderName: String) -> String? {
        let markers = ["提交", "申报", "申请", "参赛", "竞赛", "比赛", "award", "submission", "application"]
        var normalizedName = folderName.lowercased()
        guard markers.contains(where: { normalizedName.contains($0) }) else { return nil }
        for marker in markers {
            normalizedName = normalizedName.replacingOccurrences(of: marker, with: " ")
        }
        normalizedName = normalizedName
            .replacingOccurrences(of: #"\d{3,8}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[_\-\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.count >= 2 ? normalizedName : nil
    }

    private static func mergeCounts(
        _ source: [String: Int],
        into destination: inout [String: Int],
        multiplier: Int
    ) {
        for (term, count) in source {
            destination[term, default: 0] += count * multiplier
        }
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
            // Mix established folders with recently active smaller folders.
            // A single size/recency sort systematically omitted precisely the
            // new personal categories that need good recommendations most.
            let established = candidates.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.2 > $1.2
            }
            let recent = candidates.sorted { $0.2 > $1.2 }
            var mixed: [(URL, Int, Date)] = []
            var localSeen: Set<String> = []
            for candidate in established.prefix((perRootLimit + 1) / 2) {
                if localSeen.insert(candidate.0.path).inserted { mixed.append(candidate) }
            }
            for candidate in recent where mixed.count < perRootLimit {
                if localSeen.insert(candidate.0.path).inserted { mixed.append(candidate) }
            }
            for candidate in mixed {
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
        let eligible = values.compactMap { url -> (URL, Date)? in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  !FolderMonitor.shouldIgnore(path: url.path),
                  let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  resource.isRegularFile == true,
                  (resource.fileSize ?? 0) <= 80_000_000
            else { return nil }
            return (url, resource.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        guard eligible.count > limit else { return eligible.map(\.0) }

        var selected: [URL] = []
        var selectedPaths: Set<String> = []
        func append(_ url: URL) {
            if selectedPaths.insert(url.path).inserted, selected.count < limit { selected.append(url) }
        }

        // Start with recent activity, then deliberately add format diversity
        // and evenly-spaced historical files so a short-lived theme cannot
        // redefine an established folder.
        for item in eligible.prefix(min(4, limit)) { append(item.0) }
        var seenExtensions = Set(selected.map { $0.pathExtension.lowercased() })
        for item in eligible where selected.count < limit {
            let ext = item.0.pathExtension.lowercased()
            if seenExtensions.insert(ext).inserted { append(item.0) }
        }
        let remainingSlots = max(0, limit - selected.count)
        if remainingSlots > 0 {
            for index in 0..<remainingSlots {
                let position = Int((Double(index + 1) / Double(remainingSlots + 1)) * Double(eligible.count - 1))
                append(eligible[position].0)
            }
        }
        for item in eligible where selected.count < limit { append(item.0) }
        return selected
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
            let last = max(0, document.pageCount - 1)
            let pageIndices = Array(Set([0, min(1, last), last / 2, last])).sorted()
            return pageIndices.compactMap { document.page(at: $0)?.string }
                .joined(separator: " ")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 512_000)) ?? Data()
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return ["md", "markdown"].contains(ext)
            ? MarkdownContentNormalizer.normalize(decoded)
            : decoded
    }

    private static func tokenCounts(_ text: String) -> [String: Int] {
        let sample = String(text.prefix(18_000)).lowercased()
            .replacingOccurrences(of: "[_\\/\\-]+", with: " ", options: .regularExpression)
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
            .appendingPathComponent("Library/Application Support/SavePilot/folder-knowledge-v8.json")
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "were", "have", "has",
        "into", "file", "document", "page", "http", "https", "com", "www", "pdf", "docx", "pptx",
        "model", "article", "student", "students", "figure", "table", "chapter", "chapters", "section",
        "sections", "part", "parts", "version", "content", "ii", "iii", "iv", "li",
        "type", "role", "channel", "message", "messages", "request", "response", "timestamp", "metadata",
        "of", "to", "in", "is", "it", "as", "an", "be", "by", "on", "or", "not", "you", "your",
        "user", "do", "like", "will", "can", "may", "we", "our", "they", "their", "which", "what",
        "when", "where", "who", "how", "why", "also", "than", "then", "all", "any", "each", "other",
        "more", "most", "some", "such", "only", "own", "same", "too", "very", "day", "long",
        "after", "before", "because", "about", "between", "through", "during", "under", "over", "again",
        "once", "first", "later", "however", "therefore", "thus", "still", "even", "much", "many",
        "make", "makes", "made", "give", "gives", "show", "shows", "use", "used", "using", "try",
        "believe", "think", "know", "learn", "read", "reading", "way", "ways", "people", "person",
        "information", "claim", "claims", "answer", "conversation", "situation", "method", "tools",
        "new", "bad", "wrong", "correct", "simple", "common", "times", "piece", "behind", "quite",
        "的", "了", "和", "与", "及", "是", "在", "为", "对", "将", "中", "有", "一个", "文件", "文档", "内容",
        "什么", "为什么", "不同", "重要", "问题", "可以", "这个", "没有", "进行", "以及", "通过", "需要",
        "达到", "比例", "能够", "情况", "之间", "其中", "对于", "假设", "固定", "非常", "设定", "可能",
        "结果", "使用", "形成", "表示", "分析", "研究", "相关", "包括", "主要", "如果", "由于", "因此"
    ]
}
