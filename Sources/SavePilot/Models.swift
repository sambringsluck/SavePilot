import Foundation

struct WatchedFolder: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct DestinationRoot: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct FileSuggestion: Identifiable, Hashable {
    let id: UUID
    let source: URL
    let destinationFolder: URL
    let proposedFolderName: String
    let reason: String
    let summary: String
    let confidence: Double
    let createsFolder: Bool
    let detectedAt: Date
    let proposedFileName: String

    init(
        id: UUID,
        source: URL,
        destinationFolder: URL,
        proposedFolderName: String,
        reason: String,
        summary: String,
        confidence: Double,
        createsFolder: Bool,
        detectedAt: Date,
        proposedFileName: String? = nil
    ) {
        self.id = id
        self.source = source
        self.destinationFolder = destinationFolder
        self.proposedFolderName = proposedFolderName
        self.reason = reason
        self.summary = summary
        self.confidence = confidence
        self.createsFolder = createsFolder
        self.detectedAt = detectedAt
        self.proposedFileName = proposedFileName ?? source.lastPathComponent
    }

    var finalDestinationFolder: URL {
        createsFolder
            ? destinationFolder.appendingPathComponent(proposedFolderName, isDirectory: true)
            : destinationFolder
    }

    var finalDestinationURL: URL {
        finalDestinationFolder.appendingPathComponent(proposedFileName)
    }
}

enum SuggestionDependencyResolver {
    static func relocationPrerequisite(
        for suggestion: FileSuggestion,
        in suggestions: [FileSuggestion]
    ) -> FileSuggestion? {
        let target = suggestion.finalDestinationFolder.standardizedFileURL.path
        return suggestions.first { candidate in
            guard candidate.id != suggestion.id,
                  (try? candidate.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return false }
            return candidate.finalDestinationURL.standardizedFileURL.path == target
        }
    }

    static func retargetDependents(
        in suggestions: [FileSuggestion],
        from plannedFolder: URL,
        to actualFolder: URL,
        reasonSuffix: String
    ) -> [FileSuggestion] {
        let plannedPath = plannedFolder.standardizedFileURL.path
        return suggestions.map { suggestion in
            guard suggestion.finalDestinationFolder.standardizedFileURL.path == plannedPath else {
                return suggestion
            }
            return FileSuggestion(
                id: suggestion.id,
                source: suggestion.source,
                destinationFolder: actualFolder,
                proposedFolderName: "",
                reason: suggestion.reason + reasonSuffix,
                summary: suggestion.summary,
                confidence: suggestion.confidence,
                createsFolder: false,
                detectedAt: suggestion.detectedAt,
                proposedFileName: suggestion.proposedFileName
            )
        }
    }
}

struct MoveRecord: Codable, Identifiable {
    let id: UUID
    let sourcePath: String
    let destinationPath: String
    let movedAt: Date
}

struct ExtractedContent {
    let text: String
    let kind: String
    let summary: String
    let signals: [String]
    let entities: [String]
    let metadata: [String: String]

    init(
        text: String,
        kind: String,
        summary: String,
        signals: [String] = [],
        entities: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.text = text
        self.kind = kind
        self.summary = summary
        self.signals = signals
        self.entities = entities
        self.metadata = metadata
    }
}

enum AIBackend: String, CaseIterable, Identifiable {
    case automatic
    case appleFoundation
    case ollama
    case deepseekCloud
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动选择（推荐）"
        case .appleFoundation: return "Apple 本地大模型"
        case .ollama: return "Ollama 本地模型"
        case .deepseekCloud: return "DeepSeek API（云端）"
        case .builtIn: return "内置语义引擎"
        }
    }
}

enum ReviewState: Equatable {
    case waiting
    case analyzing(String)
    case ready
    case moving
    case error(String)
}

struct FolderAuditDocument {
    let url: URL
    let content: ExtractedContent
}

struct FolderAuditOutlier {
    let document: FolderAuditDocument
    let similarity: Double
    let medianSimilarity: Double
    let commonTerms: [String]
}
