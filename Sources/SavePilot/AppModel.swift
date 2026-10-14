import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var watchedFolders: [WatchedFolder] = []
    @Published var destinationRoots: [DestinationRoot] = []
    @Published var suggestions: [FileSuggestion] = []
    @Published var ignoredPaths: Set<String> = []
    @Published var moveHistory: [MoveRecord] = []
    @Published var state: ReviewState = .waiting
    @Published var launchAtLogin = false
    @Published var aiBackend: AIBackend = .automatic { didSet { persistAISettings() } }
    @Published var ollamaModel = "qwen3:4b" {
        didSet { persistAISettings() }
    }
    @Published var deepSeekModel = "deepseek-flash" {
        didSet { persistAISettings() }
    }
    @Published var deepSeekSendDetailedContent = false {
        didSet { persistAISettings() }
    }
    @Published var deepSeekAPIKeyDraft = ""
    @Published var deepSeekKeySaved = KeychainStore.loadDeepSeekKey() != nil
    @Published var deepSeekStatus = ""
    @Published var autoScanExisting = true {
        didSet { defaults.set(autoScanExisting, forKey: "autoScanExisting") }
    }
    @Published var existingScanStatus = ""
    @Published var folderAuditStatus = ""
    @Published var folderAuditRunning = false
    @Published var learningSummary = ""
    @Published var folderKnowledgeStatus = ""
    @Published var activeSavePanel: SavePanelContext?
    @Published var preSaveHint: FileSuggestion?
    @Published var accessibilityGranted = SavePanelObserver.accessibilityGranted
    @Published var fullDiskAccessGranted = false
    @Published var watchedFoldersReadable = false
    @Published var lastPermissionCheck: Date?

    private var monitor: FolderMonitor?
    private var savePanelObserver: SavePanelObserver?
    private let engine = SuggestionEngine()
    private let learningStore = LearningStore()
    private let defaults = UserDefaults.standard
    private var folderKnowledgeProfiles = FolderKnowledgeIndex.load()
    private var pendingURLs: [(url: URL, allowExisting: Bool)] = []
    private var processingQueue = false

    init() {
        loadSettings()
        learningSummary = learningStore.summary
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let monitor = FolderMonitor { [weak self] url in
            Task { @MainActor in self?.enqueueFile(url) }
        }
        self.monitor = monitor
        let observer = SavePanelObserver { [weak self] context in
            Task { @MainActor in await self?.handleSavePanel(context) }
        }
        self.savePanelObserver = observer
        observer.start()
        restartMonitoring()
        refreshPermissions()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self else { return }
            let hadCachedProfiles = !self.folderKnowledgeProfiles.isEmpty
            // A warm launch can classify immediately from the last good index while
            // a refreshed snapshot is built in the background for future files.
            if hadCachedProfiles, self.autoScanExisting { self.analyzeExistingFiles(limit: 12) }
            await self.refreshFolderKnowledge()
            if !hadCachedProfiles, self.autoScanExisting { self.analyzeExistingFiles(limit: 12) }
        }
    }

    var pendingCount: Int { suggestions.count }

    func restartMonitoring() {
        monitor?.start(folders: watchedFolders.map(\.url))
        state = suggestions.isEmpty ? .waiting : .ready
    }

    func addWatchedFolder() {
        guard let url = chooseFolder(prompt: "选择要监听的新文件入口") else { return }
        guard !watchedFolders.contains(where: { $0.path == url.path }) else { return }
        watchedFolders.append(WatchedFolder(path: url.path))
        persistSettings()
        restartMonitoring()
    }

    func addDestinationRoot() {
        guard let url = chooseFolder(prompt: "选择文件归档根目录") else { return }
        guard !destinationRoots.contains(where: { $0.path == url.path }) else { return }
        destinationRoots.append(DestinationRoot(path: url.path))
        persistSettings()
    }

    func enableWholeHomeMonitoring() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        watchedFolders = [WatchedFolder(path: home.path)]
        persistSettings()
        restartMonitoring()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            state = .error("无法更新登录启动设置：\(error.localizedDescription)")
        }
    }

    func requestAccessibility() {
        SavePanelObserver.requestAccessibility()
        SavePanelObserver.openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func openFullDiskAccessSettings() {
        SavePanelObserver.openFullDiskAccessSettings()
    }

    func refreshPermissions() {
        accessibilityGranted = SavePanelObserver.accessibilityGranted
        fullDiskAccessGranted = SavePanelObserver.fullDiskAccessGranted()
        watchedFoldersReadable = SavePanelObserver.watchedFoldersReadable(watchedFolders.map(\.url))
        lastPermissionCheck = Date()
        SavePanelObserver.writeDiagnostics(SystemPermissionSnapshot(
            accessibility: accessibilityGranted,
            fullDiskAccess: fullDiskAccessGranted,
            watchedFoldersReadable: watchedFoldersReadable,
            checkedAt: lastPermissionCheck ?? Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        ))
    }

    func copyPreSaveDestination() {
        guard let path = preSaveHint?.finalDestinationFolder.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func removeWatchedFolder(_ folder: WatchedFolder) {
        watchedFolders.removeAll { $0 == folder }
        persistSettings()
        restartMonitoring()
    }

    func removeDestinationRoot(_ root: DestinationRoot) {
        guard destinationRoots.count > 1 else { return }
        destinationRoots.removeAll { $0 == root }
        persistSettings()
    }

    func analyzeExistingFiles(limit: Int = 100) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let scanFolders = effectiveExistingScanFolders()
        var groups: [[(url: URL, modified: Date)]] = []
        for folder in scanFolders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var group: [(url: URL, modified: Date)] = []
            for file in files where !FolderMonitor.shouldIgnore(path: file.path) {
                let values = try? file.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                group.append((file, values?.contentModificationDate ?? .distantPast))
            }
            groups.append(group.sorted { $0.modified > $1.modified })
        }
        let totalCount = groups.reduce(0) { $0 + $1.count }
        let safeLimit = max(1, limit)
        let quota = max(1, safeLimit / max(1, groups.count))
        var selected: [(url: URL, modified: Date)] = []
        for group in groups {
            selected.append(contentsOf: group.prefix(quota))
        }
        if selected.count < safeLimit {
            let alreadySelected = Set(selected.map { $0.url.standardizedFileURL.path })
            let remaining = groups.flatMap { $0 }
                .filter { !alreadySelected.contains($0.url.standardizedFileURL.path) }
                .sorted { $0.modified > $1.modified }
            selected.append(contentsOf: remaining.prefix(safeLimit - selected.count))
        }
        let queuedCount = min(selected.count, safeLimit)
        existingScanStatus = totalCount == 0
            ? "没有发现需要分析的现有文件"
            : "发现 \(totalCount) 个现有文件，已从 \(groups.count) 个入口均衡加入 \(queuedCount) 个到分析队列"
        for candidate in selected.prefix(safeLimit) {
            enqueueFile(candidate.url, allowExisting: true)
        }
    }

    func chooseAndAuditFolder() {
        guard let folder = chooseFolder(prompt: "选择要检查主题一致性的文件夹") else { return }
        Task { await auditFolder(folder) }
    }

    func rebuildFolderKnowledge() {
        Task { await refreshFolderKnowledge() }
    }

    func confirm(_ suggestion: FileSuggestion) {
        state = .moving
        do {
            learningStore.record(
                source: suggestion.source,
                summary: suggestion.summary,
                destination: suggestion.finalDestinationFolder
            )
            learningSummary = learningStore.summary
            if suggestion.source.deletingLastPathComponent().standardizedFileURL == suggestion.finalDestinationFolder.standardizedFileURL {
                suggestions.removeAll { $0.id == suggestion.id }
                state = suggestions.isEmpty ? .waiting : .ready
                Task { await updateKnowledgeProfile(for: suggestion.finalDestinationFolder) }
                return
            }
            let record = try FileMover.move(suggestion.source, to: suggestion.finalDestinationFolder)
            ignoredPaths.insert(record.destinationPath)
            moveHistory.insert(record, at: 0)
            suggestions.removeAll { $0.id == suggestion.id }
            persistHistory()
            state = suggestions.isEmpty ? .waiting : .ready
            Task { await updateKnowledgeProfile(for: suggestion.finalDestinationFolder) }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func chooseAndConfirm(_ suggestion: FileSuggestion) {
        guard let folder = chooseFolder(prompt: "选择最终存放位置") else { return }
        if folder.standardizedFileURL != suggestion.finalDestinationFolder.standardizedFileURL {
            learningStore.recordRejection(
                source: suggestion.source,
                summary: suggestion.summary,
                destination: suggestion.finalDestinationFolder
            )
        }
        let updated = FileSuggestion(
            id: suggestion.id,
            source: suggestion.source,
            destinationFolder: folder,
            proposedFolderName: "",
            reason: "由你手动选择",
            summary: suggestion.summary,
            confidence: 1,
            createsFolder: false,
            detectedAt: suggestion.detectedAt
        )
        confirm(updated)
    }

    func confirmEditedPath(_ rawPath: String, for suggestion: FileSuggestion) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded != "/" else {
            state = .error("请输入有效的绝对文件夹路径，例如 ~/Documents/项目资料。")
            return
        }
        let folder = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        if folder != suggestion.finalDestinationFolder.standardizedFileURL {
            learningStore.recordRejection(
                source: suggestion.source,
                summary: suggestion.summary,
                destination: suggestion.finalDestinationFolder
            )
        }
        let updated = FileSuggestion(
            id: suggestion.id,
            source: suggestion.source,
            destinationFolder: folder,
            proposedFolderName: "",
            reason: "由你直接修改路径；这次纠正会加入个人训练记忆",
            summary: suggestion.summary,
            confidence: 1,
            createsFolder: !FileManager.default.fileExists(atPath: folder.path),
            detectedAt: suggestion.detectedAt
        )
        confirm(updated)
    }

    func dismiss(_ suggestion: FileSuggestion) {
        learningStore.recordRejection(
            source: suggestion.source,
            summary: suggestion.summary,
            destination: suggestion.finalDestinationFolder
        )
        learningSummary = learningStore.summary
        ignoredPaths.insert(suggestion.source.path)
        suggestions.removeAll { $0.id == suggestion.id }
        state = suggestions.isEmpty ? .waiting : .ready
    }

    func undoLastMove() {
        guard let record = moveHistory.first else { return }
        do {
            try FileMover.undo(record)
            moveHistory.removeFirst()
            persistHistory()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func resetLearning() {
        learningStore.reset()
        learningSummary = learningStore.summary
    }

    func saveDeepSeekKey() {
        do {
            try KeychainStore.saveDeepSeekKey(deepSeekAPIKeyDraft)
            deepSeekAPIKeyDraft = ""
            deepSeekKeySaved = true
            deepSeekStatus = "API Key 已安全保存到 macOS 钥匙串"
        } catch {
            deepSeekStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    func deleteDeepSeekKey() {
        KeychainStore.deleteDeepSeekKey()
        deepSeekAPIKeyDraft = ""
        deepSeekKeySaved = false
        deepSeekStatus = "API Key 已从钥匙串删除"
    }

    func testDeepSeekConnection() {
        guard let key = KeychainStore.loadDeepSeekKey() else {
            deepSeekStatus = "请先保存 API Key"
            return
        }
        deepSeekStatus = "正在连接 DeepSeek…"
        Task { [weak self] in
            guard let self else { return }
            let result = await DeepSeekRecommender.test(apiKey: key, model: self.deepSeekModel)
            self.deepSeekStatus = result
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func enqueueFile(_ url: URL, allowExisting: Bool = false) {
        guard !pendingURLs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              !suggestions.contains(where: { $0.source.standardizedFileURL == url.standardizedFileURL })
        else { return }
        pendingURLs.append((url, allowExisting))
        guard !processingQueue else { return }
        processingQueue = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingURLs.isEmpty {
                let next = self.pendingURLs.removeFirst()
                await self.handleNewFile(next.url, allowExisting: next.allowExisting)
            }
            self.processingQueue = false
        }
    }

    private func handleNewFile(_ url: URL, allowExisting: Bool = false) async {
        let personalLibraryPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path + "/"
        guard !url.standardizedFileURL.path.hasPrefix(personalLibraryPrefix),
              FileManager.default.fileExists(atPath: url.path),
              !ignoredPaths.contains(url.path),
              !suggestions.contains(where: { $0.source.path == url.path })
        else { return }

        if !allowExisting {
            let age = Date().timeIntervalSince((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            guard age < 120 else { return }
        }

        state = .analyzing(url.lastPathComponent)
        let roots = effectiveDestinationURLs()
        let content = await Task.detached(priority: .userInitiated) {
            await ContentExtractor.extract(from: url)
        }.value
        let suggestionEngine = engine
        let topic = await Task.detached(priority: .userInitiated) {
            suggestionEngine.topicName(for: url, content: content)
        }.value
        let learned = learningStore.recommendation(for: url, content: content, roots: roots)
        let profiles = folderKnowledgeProfiles
        let knowledge = learned == nil ? await Task.detached(priority: .userInitiated) {
            FolderKnowledgeIndex.recommend(source: url, content: content, profiles: profiles)
        }.value : nil
        let novelThemeReady = learned == nil
            ? learningStore.observeNovelTheme(source: url, content: content, topic: topic)
            : false
        // New folders are restricted to reusable, bounded topic categories.
        // A strong title/body signal may propose one immediately; weaker themes
        // must first recur across three distinct files. Creation still requires
        // an explicit user confirmation.
        let allowCreatingFolder = learned == nil
            && (suggestionEngine.stableNewFolderName(for: url, content: content) != nil || novelThemeReady)
        var fallback = await Task.detached(priority: .userInitiated) {
            suggestionEngine.suggest(
                for: url,
                content: content,
                roots: roots,
                allowCreatingFolder: allowCreatingFolder
            )
        }.value
        if let learned {
            fallback = FileSuggestion(
                id: fallback.id,
                source: url,
                destinationFolder: learned.destination,
                proposedFolderName: "",
                reason: "个人记忆：\(learned.evidence)，并结合当前内容得出",
                summary: fallback.summary,
                confidence: learned.confidence,
                createsFolder: false,
                detectedAt: fallback.detectedAt
            )
        } else if let knowledge {
            let terms = knowledge.evidenceTerms.joined(separator: "、")
            fallback = FileSuggestion(
                id: fallback.id,
                source: url,
                destinationFolder: knowledge.destination,
                proposedFolderName: "",
                reason: "本地混合 RAG/超图：内容主题与该目录的多数文件画像一致，并通过“\(terms)”等共享节点形成关系证据（领先第二候选 \(Int(knowledge.margin * 100)) 分）",
                summary: fallback.summary,
                confidence: min(0.96, 0.68 + knowledge.score * 0.6),
                createsFolder: false,
                detectedAt: fallback.detectedAt
            )
        }
        let refined = await refineSuggestion(
            source: url,
            content: content,
            roots: roots,
            fallback: fallback
        )
        let suggestion = sanitizeFolderCreation(
            refined,
            fallback: fallback,
            allowCreatingFolder: allowCreatingFolder
        )
        learningSummary = learningStore.summary
        suggestions.append(suggestion)
        state = .ready
        SavePanelObserver.writeRuntimeDiagnostics(RuntimeDiagnostics(
            lastAnalyzedFile: url.path,
            suggestedDestination: suggestion.finalDestinationFolder.path,
            pendingSuggestions: suggestions.count,
            processedAt: Date(),
            recentSuggestions: suggestions.suffix(30).map {
                RuntimeDiagnostics.SuggestionSnapshot(
                    file: $0.source.path,
                    destination: $0.finalDestinationFolder.path,
                    reason: $0.reason,
                    confidence: $0.confidence,
                    createsFolder: $0.createsFolder
                )
            }
        ))
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showReviewWindow, object: nil)
    }

    private func refineSuggestion(
        source: URL,
        content: ExtractedContent,
        roots: [URL],
        fallback: FileSuggestion
    ) async -> FileSuggestion {
        switch aiBackend {
        case .automatic:
            return await AppleFoundationRecommender.refine(
                source: source, content: content, roots: roots, fallback: fallback
            ) ?? fallback
        case .appleFoundation:
            return await AppleFoundationRecommender.refine(
                source: source, content: content, roots: roots, fallback: fallback
            ) ?? fallback
        case .ollama:
            return await OllamaRecommender.refine(
                source: source,
                content: content,
                roots: roots,
                fallback: fallback,
                model: ollamaModel
            ) ?? fallback
        case .deepseekCloud:
            if let apiKey = KeychainStore.loadDeepSeekKey() {
                return await DeepSeekRecommender.refine(
                    source: source,
                    content: content,
                    roots: roots,
                    fallback: fallback,
                    apiKey: apiKey,
                    model: deepSeekModel,
                    sendDetailedContent: deepSeekSendDetailedContent
                ) ?? fallback
            } else {
                return fallback
            }
        case .builtIn:
            return fallback
        }
    }

    private func sanitizeFolderCreation(
        _ suggestion: FileSuggestion,
        fallback: FileSuggestion,
        allowCreatingFolder: Bool
    ) -> FileSuggestion {
        guard suggestion.createsFolder else { return suggestion }
        guard !allowCreatingFolder else {
            // A cloud/local model may refine the reasoning, but it cannot turn
            // one file into a bespoke directory. Only the bounded fallback
            // category is allowed to become a new folder.
            guard fallback.createsFolder,
                  suggestion.proposedFolderName == fallback.proposedFolderName
            else { return fallback }
            return suggestion
        }
        return FileSuggestion(
            id: fallback.id,
            source: fallback.source,
            destinationFolder: fallback.destinationFolder,
            proposedFolderName: "",
            reason: "已有目录优先：新主题尚未积累到 3 个不同文件，因此不新建文件夹。\(fallback.reason)",
            summary: fallback.summary,
            confidence: fallback.confidence,
            createsFolder: false,
            detectedAt: fallback.detectedAt
        )
    }

    private func auditFolder(_ folder: URL) async {
        guard !folderAuditRunning else { return }
        folderAuditRunning = true
        defer { folderAuditRunning = false }

        let files = FolderAuditEngine.candidateFiles(in: folder, limit: 80)
        guard files.count >= 5 else {
            folderAuditStatus = "“\(folder.lastPathComponent)”中可分析的顶层文件不足 5 个。"
            return
        }

        var documents: [FolderAuditDocument] = []
        for start in stride(from: 0, to: files.count, by: 4) {
            let end = min(start + 4, files.count)
            let chunk = Array(files[start..<end])
            folderAuditStatus = "正在分析“\(folder.lastPathComponent)”：\(documents.count)/\(files.count)"
            let extracted = await withTaskGroup(of: FolderAuditDocument.self) { group in
                for url in chunk {
                    group.addTask {
                        FolderAuditDocument(url: url, content: await ContentExtractor.extract(from: url))
                    }
                }
                var values: [FolderAuditDocument] = []
                for await value in group { values.append(value) }
                return values
            }
            documents.append(contentsOf: extracted)
        }

        folderAuditStatus = "正在比较主题相似度…"
        let outliers = await Task.detached(priority: .userInitiated) {
            FolderAuditEngine.findOutliers(in: documents)
        }.value
        guard !outliers.isEmpty else {
            folderAuditStatus = "审计完成：\(files.count) 个文件的主题没有发现明显离群项。"
            return
        }

        let auditedPath = folder.standardizedFileURL.path
        var roots = effectiveDestinationURLs().filter { $0.standardizedFileURL.path != auditedPath }
        if roots.isEmpty {
            let documentsRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
            if documentsRoot.standardizedFileURL.path != auditedPath { roots = [documentsRoot] }
        }
        let suggestionEngine = engine
        var added = 0
        for outlier in outliers {
            if let learned = learningStore.recommendation(
                for: outlier.document.url,
                content: outlier.document.content,
                roots: roots
            ) {
                let themes = outlier.commonTerms.isEmpty ? "多数文件主题" : outlier.commonTerms.joined(separator: "、")
                let suggestion = FileSuggestion(
                    id: UUID(),
                    source: outlier.document.url,
                    destinationFolder: learned.destination,
                    proposedFolderName: "",
                    reason: "文件夹审计：与“\(themes)”明显不符；个人记忆检索：\(learned.evidence)",
                    summary: outlier.document.content.summary,
                    confidence: max(learned.confidence, min(0.98, 1 - outlier.similarity)),
                    createsFolder: false,
                    detectedAt: Date()
                )
                if !suggestions.contains(where: { $0.source.standardizedFileURL == suggestion.source.standardizedFileURL }) {
                    suggestions.append(suggestion)
                    added += 1
                }
                continue
            }
            let profiles = folderKnowledgeProfiles
            if let knowledge = await Task.detached(priority: .userInitiated, operation: {
                FolderKnowledgeIndex.recommend(
                    source: outlier.document.url,
                    content: outlier.document.content,
                    profiles: profiles,
                    excludingFolders: Set([auditedPath])
                )
            }).value {
                let themes = outlier.commonTerms.isEmpty ? "多数文件主题" : outlier.commonTerms.joined(separator: "、")
                let suggestion = FileSuggestion(
                    id: UUID(),
                    source: outlier.document.url,
                    destinationFolder: knowledge.destination,
                    proposedFolderName: "",
                    reason: "文件夹审计：与“\(themes)”明显不符；本地内容 RAG 在目标目录中找到了相似主题",
                    summary: outlier.document.content.summary,
                    confidence: min(0.97, max(1 - outlier.similarity, 0.68 + knowledge.score * 0.6)),
                    createsFolder: false,
                    detectedAt: Date()
                )
                if !suggestions.contains(where: { $0.source.standardizedFileURL == suggestion.source.standardizedFileURL }) {
                    suggestions.append(suggestion)
                    added += 1
                }
                continue
            }
            let topic = suggestionEngine.topicName(for: outlier.document.url, content: outlier.document.content)
            let novelThemeReady = learningStore.observeNovelTheme(
                source: outlier.document.url,
                content: outlier.document.content,
                topic: topic
            )
            let allowCreatingFolder = suggestionEngine.stableNewFolderName(
                for: outlier.document.url,
                content: outlier.document.content
            ) != nil || novelThemeReady
            let fallback = await Task.detached(priority: .userInitiated) {
                suggestionEngine.suggest(
                    for: outlier.document.url,
                    content: outlier.document.content,
                    roots: roots,
                    excludingFolders: Set([auditedPath]),
                    allowCreatingFolder: allowCreatingFolder
                )
            }.value
            let themes = outlier.commonTerms.isEmpty ? "多数文件主题" : outlier.commonTerms.joined(separator: "、")
            let reason = "文件夹审计：与“\(themes)”的相似度仅 \(Int(outlier.similarity * 100))%，低于本文件夹中位数 \(Int(outlier.medianSimilarity * 100))%；\(fallback.reason)"
            let suggestion = FileSuggestion(
                id: fallback.id,
                source: fallback.source,
                destinationFolder: fallback.destinationFolder,
                proposedFolderName: fallback.proposedFolderName,
                reason: reason,
                summary: fallback.summary,
                confidence: max(fallback.confidence, min(0.98, 1 - outlier.similarity)),
                createsFolder: fallback.createsFolder,
                detectedAt: fallback.detectedAt
            )
            if !suggestions.contains(where: { $0.source.standardizedFileURL == suggestion.source.standardizedFileURL }) {
                suggestions.append(suggestion)
                added += 1
            }
        }
        folderAuditStatus = "审计完成：分析 \(files.count) 个文件，发现 \(added) 个可能放错位置的文件。"
        learningSummary = learningStore.summary
        state = suggestions.isEmpty ? .waiting : .ready
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showReviewWindow, object: nil)
    }

    private func handleSavePanel(_ context: SavePanelContext?) async {
        accessibilityGranted = SavePanelObserver.accessibilityGranted
        activeSavePanel = context
        guard let context, let filename = context.proposedFilename, !filename.isEmpty else {
            preSaveHint = nil
            return
        }
        let source = watchedFolders.first?.url.appendingPathComponent(filename)
            ?? URL(fileURLWithPath: filename)
        let provisional = ExtractedContent(
            text: "\(filename) \(context.applicationName)",
            kind: "保存面板预判",
            summary: "文件尚未落盘；当前建议只根据文件名和来源应用生成，保存完成后会读取实际内容并复核。",
            signals: ["Accessibility保存面板"]
        )
        let roots = effectiveDestinationURLs()
        let suggestionEngine = engine
        preSaveHint = await Task.detached(priority: .utility) {
            suggestionEngine.suggest(for: source, content: provisional, roots: roots)
        }.value
    }

    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func effectiveExistingScanFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var result: [URL] = []
        for watched in watchedFolders.map(\.url) {
            if watched.standardizedFileURL == home {
                for name in ["Desktop", "Downloads"] {
                    let folder = home.appendingPathComponent(name, isDirectory: true)
                    if FileManager.default.fileExists(atPath: folder.path) { result.append(folder) }
                }
            } else {
                result.append(watched)
            }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func effectiveDestinationURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = destinationRoots.map(\.url)
        // Personal-structure RAG: existing folders on Desktop and Downloads are
        // valid destinations even when the user has only configured Documents.
        // The generic roots themselves are fallbacks, never semantic matches.
        for name in ["Desktop", "Downloads"] {
            let url = home.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
        }
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func refreshFolderKnowledge() async {
        folderKnowledgeStatus = folderKnowledgeProfiles.isEmpty
            ? "正在首次读取已有文件夹内容并建立本地 RAG 索引…"
            : "正在后台刷新本地文件夹内容索引…"
        let roots = effectiveDestinationURLs()
        let profiles = await Task.detached(priority: .utility) {
            await FolderKnowledgeIndex.build(roots: roots)
        }.value
        guard !profiles.isEmpty else {
            folderKnowledgeStatus = "未找到可建立内容画像的已有文件夹；仍使用个人反馈记忆。"
            return
        }
        folderKnowledgeProfiles = profiles
        await Task.detached(priority: .utility) {
            FolderKnowledgeIndex.save(profiles)
        }.value
        let samples = profiles.reduce(0) { $0 + $1.sampledFiles }
        let adaptive = profiles.filter { $0.sampledFiles > 3 }.count
        folderKnowledgeStatus = "本地内容 RAG 已就绪：\(profiles.count) 个文件夹、\(samples) 个抽样文件；\(adaptive) 个混合主题目录已自动扩大抽样。"
    }

    private func updateKnowledgeProfile(for folder: URL) async {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let genericRoots = ["Desktop", "Documents", "Downloads"].map {
            home.appendingPathComponent($0, isDirectory: true).standardizedFileURL
        }
        guard !genericRoots.contains(folder.standardizedFileURL) else { return }
        folderKnowledgeStatus = "正在根据刚确认的文件微调“\(folder.lastPathComponent)”主题画像…"
        guard let profile = await Task.detached(priority: .utility, operation: {
            await FolderKnowledgeIndex.buildProfile(folder: folder)
        }).value else { return }
        folderKnowledgeProfiles.removeAll { $0.path == profile.path }
        folderKnowledgeProfiles.append(profile)
        let profiles = folderKnowledgeProfiles
        await Task.detached(priority: .utility) { FolderKnowledgeIndex.save(profiles) }.value
        folderKnowledgeStatus = "已更新“\(folder.lastPathComponent)”：抽样 \(profile.sampledFiles) 个文件，主主题覆盖 \(profile.dominantFiles) 个，一致度 \(Int(profile.coherence * 100))%。"
    }

    private func loadSettings() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultWatched = [
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        let defaultDestination = home.appendingPathComponent("Documents", isDirectory: true)

        if let data = defaults.data(forKey: "watchedFolders"),
           let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            watchedFolders = decoded
        } else {
            watchedFolders = defaultWatched.map { WatchedFolder(path: $0.path) }
        }

        if let data = defaults.data(forKey: "destinationRoots"),
           let decoded = try? JSONDecoder().decode([DestinationRoot].self, from: data),
           !decoded.isEmpty {
            destinationRoots = decoded
        } else {
            destinationRoots = [DestinationRoot(path: defaultDestination.path)]
        }

        if let data = defaults.data(forKey: "moveHistory"),
           let decoded = try? JSONDecoder().decode([MoveRecord].self, from: data) {
            moveHistory = decoded
        }
        aiBackend = AIBackend(rawValue: defaults.string(forKey: "aiBackend") ?? "automatic") ?? .automatic
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3:4b"
        deepSeekModel = defaults.string(forKey: "deepSeekModel") ?? "deepseek-flash"
        deepSeekSendDetailedContent = defaults.bool(forKey: "deepSeekSendDetailedContent")
        if defaults.object(forKey: "autoScanExisting") != nil {
            autoScanExisting = defaults.bool(forKey: "autoScanExisting")
        }
    }

    private func persistSettings() {
        defaults.set(try? JSONEncoder().encode(watchedFolders), forKey: "watchedFolders")
        defaults.set(try? JSONEncoder().encode(destinationRoots), forKey: "destinationRoots")
    }

    private func persistHistory() {
        let trimmed = Array(moveHistory.prefix(100))
        defaults.set(try? JSONEncoder().encode(trimmed), forKey: "moveHistory")
    }

    private func persistAISettings() {
        defaults.set(aiBackend.rawValue, forKey: "aiBackend")
        defaults.set(ollamaModel, forKey: "ollamaModel")
        defaults.set(deepSeekModel, forKey: "deepSeekModel")
        defaults.set(deepSeekSendDetailedContent, forKey: "deepSeekSendDetailedContent")
    }
}

extension Notification.Name {
    static let showReviewWindow = Notification.Name("SavePilot.showReviewWindow")
}
