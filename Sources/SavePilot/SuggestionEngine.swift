import Foundation
import NaturalLanguage

struct SuggestionEngine {
    struct Category {
        let folder: String
        let aliases: [String]
        let keywords: [String]
    }

    private let categories: [Category] = [
        .init(folder: "工作", aliases: ["work", "business", "office", "interview", "resume", "cv", "项目", "客户", "面试", "简历"], keywords: ["project", "meeting", "report", "proposal", "client", "interview", "resume", "工作", "会议", "报告", "方案", "客户", "面试", "简历"]),
        .init(folder: "财务", aliases: ["finance", "financial", "money", "bank", "portfolio", "税务", "金融", "投资"], keywords: ["bank", "statement", "tax", "budget", "finance", "financial", "invoice", "portfolio", "investment", "stock", "bond", "银行", "税", "预算", "账单", "发票", "金融", "投资", "股票", "债券", "资产配置"]),
        .init(folder: "收据", aliases: ["receipts", "receipt", "报销"], keywords: ["receipt", "purchase", "order", "paid", "total", "收据", "小票", "订单", "付款", "报销"]),
        .init(folder: "合同与法律", aliases: ["legal", "contracts", "contract"], keywords: ["agreement", "contract", "legal", "terms", "signature", "合同", "协议", "法律", "签署"]),
        .init(folder: "历史", aliases: ["history", "historical", "world history", "global history", "世界史", "通史"], keywords: ["history", "historical", "civilization", "empire", "ancient", "modern history", "历史", "世界史", "全球史", "通史", "文明", "帝国", "古代史", "近代史"]),
        .init(folder: "学习", aliases: ["study", "school", "education", "research", "course", "homework", "hw", "textbook", "physics", "课程", "教材"], keywords: ["course", "lecture", "homework", "textbook", "physics", "research", "学习", "课程", "作业", "论文", "研究", "教材"]),
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

    func strongTitleCategoryName(for source: URL) -> String? {
        let title = source.deletingPathExtension().lastPathComponent.lowercased()
        if isHomeworkTitle(title) { return "学习" }
        let contentCategories = categories.dropLast().filter {
            !["截图", "图片", "代码", "安装包", "压缩包", "音视频"].contains($0.folder)
        }
        let matches = contentCategories.compactMap { category -> (Category, Int)? in
            let count = directTitleSignals(for: category).filter { containsSignal($0, in: title) }.count
            return count > 0 ? (category, count) : nil
        }.sorted { $0.1 > $1.1 }
        guard let best = matches.first,
              matches.dropFirst().first?.1 != best.1
        else { return nil }
        return best.0.folder
    }

    func destination(_ destination: URL, matchesCategoryNamed name: String) -> Bool {
        guard let category = categories.first(where: { $0.folder == name }) else { return false }
        return destination.pathComponents.suffix(2).contains { component in
            let normalized = component.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if category.folder.contains(where: { !$0.isASCII }),
               normalized.contains(category.folder.lowercased()) {
                return true
            }
            return category.aliases.contains { normalized == $0.lowercased() }
        }
    }

    /// Returns a bounded, reusable category rather than a one-off folder named
    /// after the file. A title keyword is sufficient; otherwise the body needs
    /// at least two independent category signals. Format categories are stable
    /// by construction (for example, 安装包 or 音视频).
    func stableNewFolderName(for source: URL, content: ExtractedContent) -> String? {
        let evidence = "\(source.lastPathComponent) \(content.summary) \(content.entities.joined(separator: " ")) \(String(content.text.prefix(4_000)))".lowercased()
        let title = source.deletingPathExtension().lastPathComponent.lowercased()
        if isHomeworkTitle(title) { return "学习" }
        let category = bestCategory(for: source, evidence: evidence)
        guard category.folder != "待整理" else { return nil }

        let formatCategories: Set<String> = ["截图", "图片", "代码", "安装包", "压缩包", "音视频"]
        if formatCategories.contains(category.folder) { return category.folder }

        let titleSignals = directTitleSignals(for: category)
        if titleSignals.contains(where: { containsSignal($0, in: title) }) {
            return category.folder
        }
        let bodyHits = Set(category.keywords.filter { containsSignal($0, in: evidence) })
        let anchors = strongAnchors[category.folder] ?? category.keywords
        let anchorHits = anchors.filter { containsSignal($0, in: evidence) }
        let requiredHits = ["工作", "学习", "个人"].contains(category.folder) ? 3 : 2
        return bodyHits.count >= requiredHits && !anchorHits.isEmpty ? category.folder : nil
    }

    func isPlausibleModelDestination(source: URL, content: ExtractedContent, destination: URL) -> Bool {
        if destination.standardizedFileURL == source.deletingLastPathComponent().standardizedFileURL { return true }
        let evidence = "\(source.lastPathComponent) \(content.summary) \(String(content.text.prefix(1_200)))".lowercased()
        let category = bestCategory(for: source, evidence: evidence)
        if folderNameMatches(category: category, folder: destination) { return true }

        let titleTerms = tokens(source.deletingPathExtension().lastPathComponent).filter { $0.count >= 3 }
        let pathTerms = tokens(destination.pathComponents.suffix(2).joined(separator: " "))
        if !titleTerms.intersection(pathTerms).isEmpty { return true }

        let target = destination.pathComponents.suffix(2).joined(separator: " ")
        return semanticSimilarity(evidence: String(evidence.prefix(420)), target: target) >= 0.64
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
        let title = source.deletingPathExtension().lastPathComponent.lowercased()
        if let strongTitle = strongTitleCategoryName(for: source),
           let category = categories.first(where: { $0.folder == strongTitle }) {
            return category
        }

        let keywordRanked = contentCategories.map { category in
            (category, Double(score(category: category, evidence: evidence)))
        }.sorted { $0.1 > $1.1 }
        if let best = keywordRanked.first {
            let titleHasDirectSignal = directTitleSignals(for: best.0).contains {
                containsSignal($0, in: title)
            }
            if best.1 >= 4 || (best.1 >= 2 && titleHasDirectSignal) { return best.0 }
        }

        let semanticRanked = contentCategories.map { category in
            (category, semanticSimilarity(
                evidence: String(evidence.prefix(360)),
                target: ([category.folder] + category.aliases + category.keywords).joined(separator: " ")
            ))
        }.sorted { $0.1 > $1.1 }
        guard let best = semanticRanked.first else { return categories.last! }
        let second = semanticRanked.dropFirst().first?.1 ?? 0
        guard best.1 >= 0.64, best.1 - second >= 0.06 else {
            return categories.last!
        }
        return best.0
    }

    private func score(category: Category, evidence: String) -> Int {
        category.keywords.reduce(0) { score, keyword in
            score + (containsSignal(keyword, in: evidence) ? 2 : 0)
        }
    }

    private func bestExistingFolder(category: Category, evidence: String, folders: [URL], sourceExtension: String) -> URL? {
        let lexicalRanked = folders.map { folder -> (URL, Int) in
            let folderName = folder.lastPathComponent.lowercased()
            var value = 0
            let folderTokens = tokens(folder.lastPathComponent)
            let evidenceTokens = tokens(evidence)
            let folderOverlap = folderTokens.intersection(evidenceTokens).count
            let genericTechnical = isGenericTechnicalFolder(folder)
            if !genericTechnical {
                if folderName.contains(category.folder.lowercased()) { value += 8 }
                for alias in category.aliases where folderName == alias.lowercased() { value += 6 }
                value += folderOverlap * 6
            } else {
                // A folder called “images”, “data” or “output” belongs to its
                // parent project; it is never a global destination merely
                // because the incoming file is an image or data file.
                let contextTerms = tokens(folder.pathComponents.suffix(2).joined(separator: " "))
                    .subtracting(folderTokens)
                let contextOverlap = contextTerms.intersection(evidenceTokens).count
                value += contextOverlap * 8
            }
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
            if genericTechnical, value == 0 { value -= 12 }
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
        let hits = category.keywords.filter { containsSignal($0, in: evidence) }.count
        let semantic = hits == 0 ? semanticSimilarity(
            evidence: String(evidence.prefix(360)),
            target: ([category.folder] + category.aliases + category.keywords).joined(separator: " ")
        ) : 0
        return min(0.98, 0.48 + Double(hits) * 0.07 + semantic * 0.22 + (matchedExisting ? 0.1 : 0))
    }

    private func containsSignal(_ signal: String, in evidence: String) -> Bool {
        let normalized = signal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return false }
        if normalized.contains(where: { !$0.isASCII }) || normalized.contains(" ") {
            return evidence.contains(normalized)
        }
        return tokens(evidence).contains(normalized)
    }

    private func isHomeworkTitle(_ title: String) -> Bool {
        let parts = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return parts.contains { token in
            if token == "hw" || token == "homework" { return true }
            guard token.hasPrefix("hw") else { return false }
            let suffix = token.dropFirst(2)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }
    }

    private func directTitleSignals(for category: Category) -> [String] {
        // A title is strong evidence only when it contains a category alias or
        // a high-specificity anchor. Broad words such as “statement”,
        // “report” and “order” need corroboration from the document body.
        Array(Set(category.aliases + (strongAnchors[category.folder] ?? [])))
    }

    private var strongAnchors: [String: [String]] {
        [
            "工作": ["client", "proposal", "meeting", "business", "interview", "resume", "客户", "方案", "会议", "工作", "面试", "简历"],
            "财务": ["finance", "financial", "bank", "tax", "invoice", "portfolio", "investment", "金融", "银行", "税", "发票", "投资"],
            "收据": ["receipt", "paid", "purchase", "报销", "收据", "小票", "付款"],
            "合同与法律": ["contract", "legal", "signature", "合同", "法律", "签署"],
            "历史": ["history", "historical", "civilization", "empire", "历史", "通史", "文明", "帝国"],
            "学习": ["course", "homework", "textbook", "research", "课程", "作业", "论文", "研究", "教材"],
            "医疗": ["medical", "hospital", "prescription", "diagnosis", "医疗", "医院", "处方", "诊断"],
            "旅行": ["flight", "hotel", "itinerary", "visa", "旅行", "航班", "酒店", "签证"],
            "个人": ["family", "personal", "家庭", "个人"]
        ]
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
