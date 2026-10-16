import Foundation

final class UserProfileStore {
    struct Observation: Codable {
        let path: String
        let subject: String
        let confidence: Double
        let observedAt: Date
    }

    private struct StoredProfile: Codable {
        var folderAffinity: [String: Double]
        var observations: [Observation]
        var profiledFolders: Int
        var sampledFiles: Int
        var updatedAt: Date
    }

    private var stored: StoredProfile

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.storageURL),
           let decoded = try? decoder.decode(StoredProfile.self, from: data) {
            stored = decoded
        } else {
            stored = StoredProfile(
                folderAffinity: [:], observations: [], profiledFolders: 0,
                sampledFiles: 0, updatedAt: .distantPast
            )
        }
    }

    var snapshot: UserProfileSnapshot {
        var affinity = stored.folderAffinity
        for observation in stored.observations {
            affinity[observation.subject, default: 0] += observation.confidence * 0.65
        }
        return UserProfileSnapshot(
            academicAffinity: affinity,
            observedLooseFiles: stored.observations.count,
            profiledFolders: stored.profiledFolders,
            sampledFiles: stored.sampledFiles,
            updatedAt: stored.updatedAt
        )
    }

    func rebuild(from profiles: [FolderKnowledgeProfile]) {
        var affinity: [String: Double] = [:]
        for profile in profiles {
            let topTerms = profile.weights.sorted { $0.value > $1.value }.prefix(80).map(\.key).joined(separator: " ")
            let path = URL(fileURLWithPath: profile.path).pathComponents.suffix(2).joined(separator: " ")
            guard let match = AcademicSubjectClassifier.classify(title: path, body: topTerms) else { continue }
            let reliability = min(1, Double(profile.sampledFiles) / 6.0) * (0.65 + min(0.35, profile.coherence))
            affinity[match.folderName, default: 0] += reliability * max(0.5, match.confidence)
        }
        stored.folderAffinity = affinity
        stored.profiledFolders = profiles.count
        stored.sampledFiles = profiles.reduce(0) { $0 + $1.sampledFiles }
        stored.updatedAt = Date()
        persist()
    }

    func observe(source: URL, content: ExtractedContent) {
        let path = source.standardizedFileURL.path
        let previousCount = stored.observations.count
        stored.observations.removeAll { $0.path == path }
        guard let match = AcademicSubjectClassifier.classify(source: source, content: content),
              match.confidence >= 0.70
        else {
            if stored.observations.count != previousCount {
                stored.updatedAt = Date()
                persist()
            }
            return
        }
        stored.observations.append(Observation(
            path: path, subject: match.folderName,
            confidence: match.confidence, observedAt: Date()
        ))
        stored.observations = Array(stored.observations.sorted { $0.observedAt > $1.observedAt }.prefix(2_000))
        stored.updatedAt = Date()
        persist()
    }

    func resetObservations() {
        stored.observations.removeAll()
        stored.updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: Self.storageURL, options: .atomic)
        } catch {
            // The profile is an optional accuracy prior; persistence failure
            // must never block file recommendations.
        }
    }

    private static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SavePilot/user-profile-v1.json")
    }
}
