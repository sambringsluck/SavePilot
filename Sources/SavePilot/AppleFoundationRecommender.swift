import Foundation

#if canImport(FoundationModels)
import FoundationModels

private struct AppleFileDecision: Decodable {
    let destinationIndex: Int
    let newFolder: String
    let reason: String
    let confidence: Double
}
#endif

enum AppleFoundationRecommender {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static func refine(
        source: URL,
        content: ExtractedContent,
        roots: [URL],
        fallback: FileSuggestion
    ) async -> FileSuggestion? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let folders = discoverFolders(in: roots)
            let indexed = folders.enumerated()
                .map { "\($0.offset): \($0.element.lastPathComponent)" }
                .joined(separator: "\n")
            let prompt = """
            文件名：\(source.lastPathComponent)
            文件类型：\(content.kind)
            分析信号：\(content.signals.joined(separator: "、"))
            识别实体：\(content.entities.joined(separator: "、"))
            内容：\(String(content.text.prefix(7_000)))

            现有文件夹：
            \(indexed)

            优先选择语义明确匹配的现有文件夹。没有合适选项时，destinationIndex 设为 -1，并提出简洁稳定的新文件夹名称。
            若两个目录都可能匹配，应选择 -1 而不是猜测。
            严格只返回一行 JSON，不要使用 Markdown：
            {"destinationIndex":0,"newFolder":"","reason":"中文理由","confidence":0.8}
            """
            let session = LanguageModelSession(instructions: """
                你是运行在用户 Mac 上的私人文件归档助手。只做分类建议，不建议删除文件。
                目录选择必须来自用户提供的编号；新目录名不得包含路径分隔符。
                """)
            do {
                let response = try await session.respond(to: prompt)
                let json = extractJSONObject(from: response.content)
                guard let data = json.data(using: .utf8),
                      let decision = try? JSONDecoder().decode(AppleFileDecision.self, from: data),
                      (-1..<folders.count).contains(decision.destinationIndex),
                      decision.reason.count <= 240
                else { return nil }
                let confidence = min(1, max(0, decision.confidence))
                if folders.indices.contains(decision.destinationIndex) {
                    return FileSuggestion(
                        id: fallback.id,
                        source: source,
                        destinationFolder: folders[decision.destinationIndex],
                        proposedFolderName: "",
                        reason: "Apple 本地模型：\(decision.reason)",
                        summary: fallback.summary,
                        confidence: confidence,
                        createsFolder: false,
                        detectedAt: fallback.detectedAt
                    )
                }
                if let name = sanitizedFolderName(decision.newFolder), let root = roots.first {
                    return FileSuggestion(
                        id: fallback.id,
                        source: source,
                        destinationFolder: root,
                        proposedFolderName: name,
                        reason: "Apple 本地模型：\(decision.reason)",
                        summary: fallback.summary,
                        confidence: confidence,
                        createsFolder: true,
                        detectedAt: fallback.detectedAt
                    )
                }
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private static func sanitizedFolderName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.hasPrefix(".")
        else { return nil }
        return String(trimmed.prefix(60))
    }

    private static func extractJSONObject(from value: String) -> String {
        guard let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}") else { return value }
        return String(value[start...end])
    }

    private static func discoverFolders(in roots: [URL]) -> [URL] {
        var result: [URL] = []
        for root in roots {
            result.append(root)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathComponents.count - root.pathComponents.count > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                if values?.isDirectory == true, values?.isHidden != true { result.append(url) }
                if result.count >= 200 { break }
            }
        }
        return result
    }
}
