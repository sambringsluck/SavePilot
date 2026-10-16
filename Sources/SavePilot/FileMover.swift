import Foundation

enum FileMover {
    static func move(_ source: URL, to folder: URL, preferredFileName: String? = nil) throws -> MoveRecord {
        try validate(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = availableDestination(for: source, in: folder, preferredFileName: preferredFileName)
        try FileManager.default.moveItem(at: source, to: destination)
        return MoveRecord(
            id: UUID(),
            sourcePath: source.path,
            destinationPath: destination.path,
            movedAt: Date()
        )
    }

    static func undo(_ record: MoveRecord) throws {
        let source = URL(fileURLWithPath: record.destinationPath)
        let original = URL(fileURLWithPath: record.sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MoveError.sourceMissing
        }
        guard !FileManager.default.fileExists(atPath: original.path) else {
            throw MoveError.originalOccupied
        }
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: original)
    }

    private static func availableDestination(for source: URL, in folder: URL, preferredFileName: String?) -> URL {
        let requestedName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (requestedName?.isEmpty == false && requestedName?.contains("/") == false)
            ? requestedName!
            : source.lastPathComponent
        let requestedURL = URL(fileURLWithPath: safeName)
        let base = requestedURL.deletingPathExtension().lastPathComponent
        let ext = requestedURL.pathExtension
        var candidate = folder.appendingPathComponent(safeName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private static func validate(folder: URL) throws {
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/", !path.contains("/../") else {
            throw MoveError.invalidDestination
        }
    }

    enum MoveError: LocalizedError {
        case sourceMissing
        case originalOccupied
        case invalidDestination

        var errorDescription: String? {
            switch self {
            case .sourceMissing: return "目标文件已经不存在，无法撤销。"
            case .originalOccupied: return "原位置已有同名文件，已停止撤销以避免覆盖。"
            case .invalidDestination: return "目标目录不安全或无效。"
            }
        }
    }
}
