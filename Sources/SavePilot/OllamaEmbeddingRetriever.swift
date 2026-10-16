import Foundation

struct EmbeddingFolderScore: Sendable {
    let profile: FolderKnowledgeProfile
    let similarity: Double
}

enum EmbeddingCandidateSelector {
    static func rank(
        query: [Double],
        profiles: [FolderKnowledgeProfile],
        vectors: [String: [Double]],
        limit: Int = 8
    ) -> [EmbeddingFolderScore] {
        guard !query.isEmpty else { return [] }
        return profiles.compactMap { profile in
            guard let vector = vectors[profile.path], vector.count == query.count else { return nil }
            return EmbeddingFolderScore(profile: profile, similarity: cosine(query, vector))
        }
        .sorted { $0.similarity > $1.similarity }
        .prefix(max(2, limit))
        .map { $0 }
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return 0 }
        return dot / sqrt(leftNorm * rightNorm)
    }
}

actor OllamaEmbeddingRetriever {
    static let shared = OllamaEmbeddingRetriever()

    private struct Request: Encodable {
        let model: String
        let input: [String]
        let truncate = true
    }

    private struct Response: Decodable {
        let embeddings: [[Double]]
    }

    private var cache: [String: [Double]] = [:]

    /// Embeddings only retrieve a small candidate set. The normal local RAG,
    /// graph, hierarchy and margin gates still decide whether any candidate is
    /// safe enough to show.
    func shortlist(
        source: URL,
        content: ExtractedContent,
        profiles: [FolderKnowledgeProfile],
        model: String,
        limit: Int = 8
    ) async -> [FolderKnowledgeProfile]? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, profiles.count >= 2 else { return nil }
        let conflicts = Set(FolderKnowledgeIndex.hierarchyConflicts(in: profiles).map(\.childPath))
        let usable = profiles.filter { profile in
            !conflicts.contains(where: { profile.path == $0 || profile.path.hasPrefix($0 + "/") })
        }
        guard usable.count >= 2 else { return nil }

        let missing = usable.filter { cache[cacheKey(model: model, profile: $0)] == nil }
        var inputs = [queryText(source: source, content: content)]
        inputs.append(contentsOf: missing.map(profileText))
        guard let generated = await embed(inputs, model: model), generated.count == inputs.count else { return nil }
        let query = generated[0]
        for (index, profile) in missing.enumerated() {
            cache[cacheKey(model: model, profile: profile)] = generated[index + 1]
        }
        let vectors = Dictionary(uniqueKeysWithValues: usable.compactMap { profile in
            cache[cacheKey(model: model, profile: profile)].map { (profile.path, $0) }
        })
        let ranked = EmbeddingCandidateSelector.rank(
            query: query, profiles: usable, vectors: vectors, limit: limit
        )
        guard let best = ranked.first, best.similarity >= 0.48 else { return nil }
        // Include a little neighborhood for sparse/hypergraph reranking, but
        // reject a completely flat embedding ranking as uninformative.
        if let second = ranked.dropFirst().first,
           best.similarity - second.similarity < 0.008,
           best.similarity < 0.62 { return nil }
        return ranked.map(\.profile)
    }

    private func embed(_ inputs: [String], model: String) async -> [[Double]]? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/embed") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Request(model: model, input: inputs))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Response.self, from: data).embeddings
        } catch {
            return nil
        }
    }

    private func cacheKey(model: String, profile: FolderKnowledgeProfile) -> String {
        "\(model)|\(profile.path)|\(profile.updatedAt.timeIntervalSince1970)"
    }

    private func queryText(source: URL, content: ExtractedContent) -> String {
        [
            source.deletingPathExtension().lastPathComponent,
            content.summary,
            content.entities.joined(separator: " "),
            String(content.text.prefix(6_000))
        ].joined(separator: "\n")
    }

    private func profileText(_ profile: FolderKnowledgeProfile) -> String {
        let folder = URL(fileURLWithPath: profile.path).pathComponents.suffix(2).joined(separator: " / ")
        let terms = profile.weights.sorted { $0.value > $1.value }.prefix(140).map(\.key).joined(separator: " ")
        let documents = profile.hyperedges.prefix(18).map {
            "\($0.documentName): \($0.members.prefix(20).joined(separator: " "))"
        }.joined(separator: "\n")
        return "folder: \(folder)\nmajority topic: \(terms)\nrepresentative files:\n\(documents)"
    }
}
