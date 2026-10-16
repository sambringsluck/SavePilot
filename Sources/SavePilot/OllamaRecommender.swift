import Foundation

enum OllamaRecommender {
    struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    static func setupStatus(requiredModels: [String]) async -> String {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return "Ollama 地址无效" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
            else { return "Ollama 服务响应异常" }
            let installed = Set(tags.models.flatMap { [$0.name, $0.name.replacingOccurrences(of: ":latest", with: "")] })
            let missing = requiredModels.filter { model in
                !installed.contains(model) && !installed.contains(model + ":latest")
            }
            return missing.isEmpty
                ? "Ollama 高精度配置已就绪"
                : "Ollama 已运行，缺少模型：\(missing.joined(separator: "、"))"
        } catch {
            return "Ollama 未运行；仍可使用内置降级模式"
        }
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream = false
        let format = "json"
    }

    struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    struct Decision: Decodable {
        let destinationIndex: Int?
        let newFolder: String?
        let reason: String
        let confidence: Double
    }

    static func refine(
        source: URL,
        content: ExtractedContent,
        roots: [URL],
        fallback: FileSuggestion,
        model: String
    ) async -> FileSuggestion? {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let folders = discoverFolders(in: roots)
        let indexedFolders = folders.enumerated()
            .map { "\($0.offset): \($0.element.lastPathComponent)" }
            .joined(separator: "\n")
        let prompt = """
        文件名：\(source.lastPathComponent)
        内容摘要：\(String(content.text.prefix(5_000)))

        可选的现有文件夹（只能用编号选择）：
        \(indexedFolders)

        判断最合适的存放位置。优先使用确实匹配的现有文件夹；都不合适时建议一个简短的新文件夹名称。
        只返回 JSON：
        {"destinationIndex": 0, "newFolder": null, "reason": "简短理由", "confidence": 0.8}
        或：
        {"destinationIndex": null, "newFolder": "新目录名", "reason": "简短理由", "confidence": 0.8}
        """
        let request = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "你是本地文件归档助手。不要输出 JSON 以外的内容，不要建议删除文件。"),
                .init(role: "user", content: prompt)
            ]
        )

        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 25
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(request) else { return nil }
        urlRequest.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let decisionData = chat.message.content.data(using: .utf8),
                  let decision = try? JSONDecoder().decode(Decision.self, from: decisionData)
            else { return nil }

            let confidence = min(1, max(0, decision.confidence))
            if let index = decision.destinationIndex, folders.indices.contains(index) {
                return FileSuggestion(
                    id: fallback.id,
                    source: source,
                    destinationFolder: folders[index],
                    proposedFolderName: "",
                    reason: "本地 AI：\(decision.reason)",
                    summary: fallback.summary,
                    confidence: confidence,
                    createsFolder: false,
                    detectedAt: fallback.detectedAt
                )
            }

            if let proposed = sanitizedFolderName(decision.newFolder), let root = roots.first {
                return FileSuggestion(
                    id: fallback.id,
                    source: source,
                    destinationFolder: root,
                    proposedFolderName: proposed,
                    reason: "本地 AI：\(decision.reason)",
                    summary: fallback.summary,
                    confidence: confidence,
                    createsFolder: true,
                    detectedAt: fallback.detectedAt
                )
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func sanitizedFolderName(_ value: String?) -> String? {
        guard let value else { return nil }
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
