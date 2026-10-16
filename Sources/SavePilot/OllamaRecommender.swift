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
        let think = false
        let format = "json"
        let options = Options()

        struct Options: Encodable {
            let temperature = 0.0
            let numPredict = 256

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
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

    struct FolderRerankDecision: Sendable {
        let profile: FolderKnowledgeProfile?
        let reason: String
        let confidence: Double
    }

    private struct FolderDecision: Decodable {
        let destinationIndex: Int?
        let reason: String
        let confidence: Double
    }

    /// Embeddings are deliberately used only for recall. The local language
    /// model then sees a small, content-grounded candidate set and may veto all
    /// of it. This catches lexical traps such as Apple/company vs apple/fruit
    /// without allowing the model to invent an arbitrary path.
    static func rerankFolders(
        source: URL,
        content: ExtractedContent,
        profiles: [FolderKnowledgeProfile],
        model: String
    ) async -> FolderRerankDecision? {
        guard !profiles.isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let candidates = profiles.enumerated().map { index, profile in
            let folder = URL(fileURLWithPath: profile.path).pathComponents.suffix(3).joined(separator: " / ")
            let terms = profile.weights.sorted { $0.value > $1.value }.prefix(45).map(\.key).joined(separator: "、")
            let examples = profile.hyperedges.prefix(5).map {
                "\($0.documentName): \($0.members.prefix(12).joined(separator: "、"))"
            }.joined(separator: "\n")
            return "候选 \(index)｜\(folder)\n主题词：\(terms)\n代表文件：\n\(examples)"
        }.joined(separator: "\n\n")
        let prompt = """
        待归类文件：\(source.lastPathComponent)
        正文摘要：\(content.summary)
        正文节选：\(String(content.text.prefix(6_000)))

        以下候选只由 embedding 负责召回，可能包含同词异义或宽泛主题造成的错误：
        \(candidates)

        这是归档判断，不是重复文件检测。不同作业、讲义、复习资料或不同语言版本，只要属于同一具体课程、研究项目或窄主题，就应归在一起；无需标题和措辞完全相同。只共享宽泛词、作者名、文件格式、导出模板或歧义词时必须拒绝。若都不可靠，destinationIndex 返回 null。
        正例：AP Physics 力学作业与牛顿定律、动量、能量复习资料属于同一物理力学课程文件夹。
        正例：错误信息重复研究与虚假真相效应、记忆和可信度资料属于同一研究主题。
        反例：Apple 公司财报与苹果派食谱只共享歧义词，不能归在一起。
        反例：数学证明与法律证据不能归在一起。
        只返回 JSON：{"destinationIndex": 0, "reason": "简短证据", "confidence": 0.9}
        """
        let request = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: "你是文件归档关系复核器，不是重复文件检测器。同一具体课程、研究项目或窄主题的不同材料应归在一起；拒绝宽泛主题和同词异义碰撞。只输出 JSON，理由不超过 30 个字。"),
                .init(role: "user", content: prompt)
            ]
        )
        guard let data = await chat(request),
              let decision = try? JSONDecoder().decode(FolderDecision.self, from: data)
        else { return nil }
        let confidence = min(1, max(0, decision.confidence))
        guard confidence >= 0.82 else { return nil }
        let profile = decision.destinationIndex.flatMap { profiles.indices.contains($0) ? profiles[$0] : nil }
        return FolderRerankDecision(profile: profile, reason: decision.reason, confidence: confidence)
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

        guard let decisionData = await chat(request),
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
        return nil
    }

    private static func chat(_ request: ChatRequest) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 45
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(request) else { return nil }
        urlRequest.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try? JSONDecoder().decode(ChatResponse.self, from: data)
            else { return nil }
            return result.message.content.data(using: .utf8)
        } catch {
            return nil
        }
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
