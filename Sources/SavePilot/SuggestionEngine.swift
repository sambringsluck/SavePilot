import Foundation
import NaturalLanguage

struct SuggestionEngine {
    struct Category {
        let folder: String
        let aliases: [String]
        let keywords: [String]
    }

    private let categories: [Category] = [
        .init(folder: "工作", aliases: ["work", "business", "office", "项目", "客户"], keywords: ["project", "meeting", "report", "proposal", "client", "工作", "会议", "报告", "方案", "客户"]),
        .init(folder: "财务", aliases: ["finance", "money", "bank", "税务"], keywords: ["bank", "statement", "tax", "budget", "finance", "invoice", "银行", "税", "预算", "账单", "发票"]),
        .init(folder: "收据", aliases: ["receipts", "receipt", "报销"], keywords: ["receipt", "purchase", "order", "paid", "total", "收据", "小票", "订单", "付款", "报销"]),
        .init(folder: "合同与法律", aliases: ["legal", "contracts", "contract"], keywords: ["agreement", "contract", "legal", "terms", "signature", "合同", "协议", "法律", "签署"]),
        .init(folder: "历史", aliases: ["history", "historical", "world history", "global history", "世界史", "通史"], keywords: ["history", "historical", "civilization", "empire", "ancient", "modern history", "历史", "世界史", "全球史", "通史", "文明", "帝国", "古代史", "近代史"]),
        .init(folder: "学习", aliases: ["study", "school", "education", "research", "课程"], keywords: ["course", "lecture", "homework", "paper", "research", "学习", "课程", "作业", "论文", "研究"]),
        .init(folder: "医疗", aliases: ["health", "medical"], keywords: ["medical", "health", "hospital", "prescription", "diagnosis", "医疗", "健康", "医院", "处方", "诊断"]),
        .init(folder: "旅行", aliases: ["travel", "trip"], keywords: ["flight", "hotel", "booking", "itinerary", "visa", "旅行", "航班", "酒店", "预订", "签证"]),
        .init(folder: "截图", aliases: ["screenshots", "screenshot"], keywords: ["screenshot", "screen shot", "截屏", "截图"]),
        .init(folder: "图片", aliases: ["images", "photos", "pictures", "photo"], keywords: ["image", "photo", "portrait", "camera", "图片", "照片", "相机"]),
        .init(folder: "代码", aliases: ["code", "development", "dev", "source"], keywords: ["function", "class", "import", "repository", "source code", "代码", "开发", "函数"]),
        .init(folder: "安装包", aliases: ["installers", "installer", "setup"], keywords: ["installer", "installation", "setup", "安装包", "安装程序"]),
        .init(folder: "压缩包", aliases: ["archives", "archive", "compressed"], keywords: ["zip", "archive", "compressed", "压缩", "归档"]),
        .init(folder: "音视频", aliases: ["media", "video", "audio", "music"], keywords: ["video", "audio", "music", "recording", "视频", "音频", "音乐", "录音"]),
        .init(folder: "个人", aliases: ["personal", "family"], keywords: ["personal", "family", "private", "个人", "家庭", "私人"]),
        .init(folder: "待整理", aliases: ["inbox", "unsorted", "review"], keywords: [])
    ]

    func suggest(
        for source: URL,
        content: ExtractedContent,
        roots: [URL],
        excludingFolders: Set<String> = [],
        allowCreatingFolder: Bool = false
    ) -> FileSuggestion {
        let evidence = "\(source.lastPathComponent) \(content.text)".lowercased()
        // Folder-name routing uses the filename only. Automatically extracted
        // entities are intentionally excluded: generic entities such as
        // “model”, “article” or “student” caused unrelated template folders to
        // win with misleading confidence.
        let retrievalEvidence = source.deletingPathExtension().lastPathComponent.lowercased()
        let category = bestCategory(for: source, evidence: evidence)
        let existingFolders = discoverFolders(in: roots, excludingFolders: excludingFolders)
        let existing = bestExistingFolder(category: category, evidence: retrievalEvidence, folders: existingFolders, sourceExtension: source.pathExtension.lowercased())

        let destination = existing ?? bestInbox(in: existingFolders) ?? source.deletingLastPathComponent()
        let createsFolder = existing == nil && allowCreatingFolder && category.folder != "待整理"
        let folderName = createsFolder ? category.folder : ""
        let reason: String
        if let existing {
            reason = "内容与现有文件夹“\(existing.lastPathComponent)”最匹配（\(content.kind)）"
        } else if createsFolder {
            reason = "没有找到足够匹配的现有目录，建议新建“\(category.folder)”（\(content.kind)）"
        } else {
            reason = "现有目录中没有足够可靠的匹配，建议暂时保留原位；可直接修改目标路径来教会我（\(content.kind)）"
        }

        let confidence = confidenceFor(category: category, evidence: evidence, matchedExisting: existing != nil)
        return FileSuggestion(
            id: UUID(),
            source: source,
            destinationFolder: destination,
            proposedFolderName: folderName,
            reason: reason,
            summary: content.summary,
            confidence: confidence,
            createsFolder: createsFolder,
            detectedAt: Date()
        )
    }

    func topicName(for source: URL, content: ExtractedContent) -> String {
        bestCategory(for: source, evidence: "\(source.lastPathComponent) \(content.text)".lowercased()).folder
    }

    /// Returns a bounded, reusable category rather than a one-off folder named
    /// after the file. A title keyword is sufficient; otherwise the body needs
    /// at least two independent category signals. Format categories are stable
    /// by construction (for example, 安装包 or 音视频).
    func stableNewFolderName(for source: URL, content: ExtractedContent) -> String? {
        let evidence = "\(source.lastPathComponent) \(content.summary) \(content.entities.joined(separator: " ")) \(String(content.text.prefix(4_000)))".lowercased()
        let title = source.deletingPathExtension().lastPathComponent.lowercased()
        let category = bestCategory(for: source, evidence: evidence)
        guard category.folder != "待整理" else { return nil }

        let formatCategories: Set<String> = ["截图", "图片", "代码", "安装包", "压缩包", "音视频"]
        if formatCategories.contains(category.folder) { return category.folder }

        let titleSignals = category.aliases + category.keywords
        if titleSignals.contains(where: { signal in
            let normalized = signal.lowercased()
            return normalized.count >= 2 && title.contains(normalized)
        }) {
            return category.folder
        }
        let bodyHits = Set(category.keywords.filter { evidence.contains($0.lowercased()) })
        return bodyHits.count >= 2 ? category.folder : nil
    }

    private func bestCategory(for source: URL, evidence: String) -> Category {
        let ext = source.pathExtension.lowercased()
        let forced: String?
        switch ext {
        case "png", "jpg", "jpeg", "heic", "tiff", "bmp", "webp":
            forced = source.lastPathComponent.lowercased().contains("screen") || source.lastPathComponent.contains("截") ? "截图" : "图片"
        case "zip", "rar", "7z", "tar", "gz": forced = "压缩包"
        case "dmg", "pkg", "iso": forced = "安装包"
        case "mp4", "mov", "mkv", "mp3", "wav", "m4a", "flac": forced = "音视频"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h", "hpp": forced = "代码"
        default: forced = nil
        }
        if let forced, let category = categories.first(where: { $0.folder == forced }) {
            return category
        }

        let contentCategories = categories.dropLast().filter {
            !["截图", "图片", "代码", "安装包", "压缩包", "音视频"].contains($0.folder)
        }
        let keywordRanked = contentCategories.map { category in
            (category, Double(score(category: category, evidence: evidence)))
        }.sorted { $0.1 > $1.1 }
        if let best = keywordRanked.first, best.1 >= 2 {
            return best.0
        }

        let semanticRanked = contentCategories.map { category in
            (category, semanticSimilarity(
                evidence: String(evidence.prefix(360)),
                target: ([category.folder] + category.aliases + category.keywords).joined(separator: " ")
            ))
        }.sorted { $0.1 > $1.1 }
        guard let best = semanticRanked.first, best.1 >= 0.54 else {
            return categories.last!
        }
        return best.0
    }

    private func score(category: Category, evidence: String) -> Int {
        category.keywords.reduce(0) { score, keyword in
            score + (evidence.contains(keyword.lowercased()) ? 2 : 0)
        }
    }

    private func bestExistingFolder(category: Category, evidence: String, folders: [URL], sourceExtension: String) -> URL? {
        let lexicalRanked = folders.map { folder -> (URL, Int) in
            let folderName = folder.lastPathComponent.lowercased()
            var value = 0
            if folderName.contains(category.folder.lowercased()) { value += 8 }
            for alias in category.aliases where folderName == alias.lowercased() { value += 6 }
            let folderTokens = tokens(folder.lastPathComponent)
            let evidenceTokens = tokens(evidence)
            let folderOverlap = folderTokens.intersection(evidenceTokens).count
            value += folderOverlap * 6
            let residentTokens = residentFileTokens(in: folder)
            let residentOverlap = residentTokens.intersection(evidenceTokens).count
            // Existing filenames may strengthen an already explainable folder
            // name match, but never select a folder by themselves.
            if folderOverlap > 0, residentOverlap >= 2 { value += residentOverlap * 2 }
            let extensions = residentExtensions(in: folder)
            if extensions.sampleCount >= 8,
               !sourceExtension.isEmpty,
               !extensions.values.contains(sourceExtension) {
                value -= 5
            }
            if isGenericTechnicalFolder(folder), !folderNameMatches(category: category, folder: folder) {
                value -= 12
            }
            return (folder, value)
        }.sorted { $0.1 > $1.1 }
        if let best = lexicalRanked.first, best.1 >= 4 { return best.0 }
        // Apple's generic sentence embeddings produced confident but plainly
        // wrong folder matches on short directory names. Existing-folder
        // retrieval therefore requires auditable lexical evidence here; an
        // enabled LLM may still refine the conservative result afterwards.
        return nil
    }

    private func isGenericTechnicalFolder(_ folder: URL) -> Bool {
        let names: Set<String> = [
            "images", "image", "archive", "output", "out", "tmp", "temp", "docs", "doc", "content",
            "src", "source", "data", "results", "scripts", "tools", "backup", "backups",
            "附件", "补充材料"
        ]
        return names.contains(folder.lastPathComponent.lowercased())
    }

    private func folderNameMatches(category: Category, folder: URL) -> Bool {
        let name = folder.lastPathComponent.lowercased()
        return name.contains(category.folder.lowercased())
            || category.aliases.contains(where: { name.contains($0.lowercased()) })
    }

    private func bestInbox(in folders: [URL]) -> URL? {
        let names = ["待整理", "inbox", "unsorted", "review", "收件箱"]
        return folders.first { names.contains($0.lastPathComponent.lowercased()) }
    }

    /// A lightweight local RAG corpus: folder path plus the names of files that
    /// already live there. It lets a user's real filing structure outrank a
    /// generic category name without uploading any content.
    private func residentFileTokens(in folder: URL) -> Set<String> {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let sample = children.prefix(80).map {
            $0.deletingPathExtension().lastPathComponent + " " + $0.pathExtension
        }.joined(separator: " ")
        return tokens(sample)
    }

    private func residentExtensions(in folder: URL) -> (values: Set<String>, sampleCount: Int) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], 0) }
        let files = children.prefix(80).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return (Set(files.map { $0.pathExtension.lowercased() }.filter { !$0.isEmpty }), files.count)
    }

    private func confidenceFor(category: Category, evidence: String, matchedExisting: Bool) -> Double {
        let hits = category.keywords.filter { evidence.contains($0.lowercased()) }.count
        let semantic = hits == 0 ? semanticSimilarity(
            evidence: String(evidence.prefix(360)),
            target: ([category.folder] + category.aliases + category.keywords).joined(separator: " ")
        ) : 0
        return min(0.98, 0.48 + Double(hits) * 0.07 + semantic * 0.22 + (matchedExisting ? 0.1 : 0))
    }

    private func discoverFolders(in roots: [URL], excludingFolders: Set<String>) -> [URL] {
        var result: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            var addedForRoot = 0
            if !isExcluded(root, exclusions: excludingFolders), !isGenericPersonalRoot(root) {
                result.append(root)
                addedForRoot += 1
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathComponents.count - root.pathComponents.count <= 2 else {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isDirectory == true,
                   values?.isHidden != true,
                   !FolderMonitor.shouldIgnore(path: url.path),
                   !isExcluded(url, exclusions: excludingFolders) {
                    result.append(url)
                    addedForRoot += 1
                }
                if addedForRoot >= 160 { break }
            }
        }
        return result
    }

    private func isGenericPersonalRoot(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return ["Desktop", "Documents", "Downloads"].contains { name in
            url.standardizedFileURL == home.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        }
    }

    private func isExcluded(_ url: URL, exclusions: Set<String>) -> Bool {
        let path = url.standardizedFileURL.path
        return exclusions.contains { excluded in
            path == excluded || path.hasPrefix(excluded + "/")
        }
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter {
            $0.count >= 2
                && $0.contains(where: { $0.isLetter })
                && !Self.lexicalStopWords.contains($0)
        })
    }

    /// Filename retrieval must ignore connective and template words. Without
    /// this gate, names such as “Physics ... for ... by ...” can falsely match
    /// a folder whose only overlap is “of / for / by / article / template”.
    private static let lexicalStopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "into", "about", "over", "under",
        "of", "to", "in", "is", "it", "as", "an", "be", "by", "on", "or", "a", "are", "was", "were",
        "model", "article", "student", "students", "template", "version", "document", "file", "day",
        "的", "了", "和", "与", "及", "是", "在", "为", "对", "将", "中", "有", "一个", "文件", "文档"
    ]

    private func semanticSimilarity(evidence: String, target: String) -> Double {
        guard !evidence.isEmpty, !target.isEmpty else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(evidence)
        let language = recognizer.dominantLanguage ?? .english
        let supported: NLLanguage = language == .simplifiedChinese || language == .traditionalChinese ? .simplifiedChinese : .english
        guard let embedding = NLEmbedding.sentenceEmbedding(for: supported) else { return 0 }
        let distance = embedding.distance(between: evidence, and: target, distanceType: .cosine)
        guard distance.isFinite else { return 0 }
        return max(0, min(1, 1 - (distance / 2)))
    }
}
