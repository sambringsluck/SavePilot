import Foundation

enum DeepSeekRecommender {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct ResponseFormat: Encodable { let type: String }
        struct Thinking: Encodable { let type: String }

        let model: String
        let messages: [Message]
        let responseFormat: ResponseFormat
        let maxTokens: Int
        let reasoningEffort: String
        let thinking: Thinking
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model, messages, thinking, stream
            case responseFormat = "response_format"
            case maxTokens = "max_tokens"
            case reasoningEffort = "reasoning_effort"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct Decision: Decodable {
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
        apiKey: String,
        model: String,
        sendDetailedContent: Bool
    ) async -> FileSuggestion? {
        let folders = discoverFolders(in: roots)
        let indexedFolders = folders.enumerated()
            .map { "\($0.offset): \($0.element.lastPathComponent)" }
            .joined(separator: "\n")
        let contentForCloud = sendDetailedContent
            ? String(content.text.prefix(4_000))
            : String(content.summary.prefix(600))
        let prompt = """
        文件名：\(source.lastPathComponent)
        文件类型：\(content.kind)
        本机提取摘要：\(contentForCloud)
        本机识别实体：\(content.entities.prefix(12).joined(separator: "、"))

        用户已有目录（只能从编号中选择）：
        \(indexedFolders)

        优先选择语义确切匹配的已有目录；没有合适目录时建议一个简洁、稳定、无路径符号的新目录名称。
        输出 JSON：{"destinationIndex":0,"newFolder":null,"reason":"中文理由","confidence":0.8}
        """
        let request = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "你是私人文件归档助手。只返回 JSON，不得建议删除文件，不得创造用户未提供的目录路径。"),
                .init(role: "user", content: prompt)
            ],
            responseFormat: .init(type: "json_object"),
            maxTokens: 400,
            reasoningEffort: "none",
            thinking: .init(type: "disabled")
        )

        guard let decision = try? await send(request, apiKey: apiKey, as: Decision.self) else { return nil }
        let confidence = min(1, max(0, decision.confidence))
        if let index = decision.destinationIndex, folders.indices.contains(index) {
            return FileSuggestion(
                id: fallback.id,
                source: source,
                destinationFolder: folders[index],
                proposedFolderName: "",
                reason: "DeepSeek：\(decision.reason)",
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
                reason: "DeepSeek：\(decision.reason)",
                summary: fallback.summary,
                confidence: confidence,
                createsFolder: true,
                detectedAt: fallback.detectedAt
            )
        }
        return nil
    }

    static func test(apiKey: String, model: String) async -> String {
        struct TestReply: Decodable { let status: String }
        do {
            let reply = try await send(connectionTestRequest(model: model), apiKey: apiKey, as: TestReply.self)
            return reply.status.lowercased() == "ok" ? "DeepSeek 连接成功（\(model)）" : "DeepSeek 返回了非预期结果"
        } catch {
            return "DeepSeek 连接失败：\(error.localizedDescription)"
        }
    }

    static func connectionTestPayload(model: String) throws -> Data {
        try JSONEncoder().encode(connectionTestRequest(model: model))
    }

    private static func connectionTestRequest(model: String) -> ChatRequest {
        ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "只返回 JSON。"),
                .init(role: "user", content: "输出 JSON：{\"status\":\"ok\"}")
            ],
            responseFormat: .init(type: "json_object"),
            maxTokens: 80,
            reasoningEffort: "none",
            thinking: .init(type: "disabled")
        )
    }

    private static func send<T: Decodable>(
        _ requestBody: ChatRequest,
        apiKey: String,
        as type: T.Type
    ) async throws -> T {
        guard let endpoint = URL(string: "https://api.deepseek.com/chat/completions") else {
            throw APIError.invalidEndpoint
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(240)) } ?? ""
            throw APIError.http(http.statusCode, message)
        }
        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content,
              let decisionData = content.data(using: .utf8)
        else { throw APIError.emptyContent }
        return try JSONDecoder().decode(T.self, from: decisionData)
    }

    private static func sanitizedFolderName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"),
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

    enum APIError: LocalizedError {
        case invalidEndpoint
        case invalidResponse
        case http(Int, String)
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "API 地址无效"
            case .invalidResponse: return "API 响应无效"
            case .http(let code, let message): return "HTTP \(code) \(message)"
            case .emptyContent: return "API 未返回内容"
            }
        }
    }
}
