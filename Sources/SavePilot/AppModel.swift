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
    @Published var ollamaEmbeddingModel = "qwen3-embedding:4b" {
        didSet { persistAISettings() }
    }
    @Published var embeddingStatus = ""
    @Published var ollamaSetupStatus = "尚未检测"
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
    @Published var userProfileSummary = ""
    @Published var folderKnowledgeStatus = ""
    @Published var activeSavePanel: SavePanelContext?
    @Published var preSaveHint: FileSuggestion?
    @Published var accessibilityGranted = SavePanelObserver.accessibilityGranted
    @Published var fullDiskAccessGranted = false
    @Published var watchedFoldersReadable = false
    @Published var lastPermissionCheck: Date?
    @Published var showWelcome = false
    @Published var availableUpdate: AppUpdateInfo?
    @Published var updateCheckStatus = ""
    @Published var updateCheckRunning = false
    @Published private(set) var knownFolderPaths: [String] = []

    private var monitor: FolderMonitor?
    private var savePanelObserver: SavePanelObserver?
    private let engine = SuggestionEngine()
    private let learningStore = LearningStore()
    private let userProfileStore = UserProfileStore()
    private let defaults = UserDefaults.standard
    private var folderKnowledgeProfiles = FolderKnowledgeIndex.load()
    private var pendingURLs: [(url: URL, allowExisting: Bool)] = []
    private var processingQueue = false
    private var recentContentByPath: [String: ExtractedContent] = [:]
    private var hasStartedInitialAnalysis = false
    private var relationshipScanTask: Task<Void, Never>?

    init() {
        loadSettings()
        refreshPathAutocompleteIndex()
        showWelcome = !defaults.bool(forKey: "didCompleteWelcome")
        learningSummary = learningStore.summary
        userProfileSummary = userProfileStore.snapshot.summary
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
            guard let self, !self.showWelcome else { return }
            await self.startInitialAnalysis()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self?.checkForUpdates()
        }
    }

    func checkOllamaSetup() async {
        ollamaSetupStatus = "正在检测 Ollama 与高精度模型…"
        ollamaSetupStatus = await OllamaRecommender.setupStatus(
            requiredModels: [ollamaEmbeddingModel, ollamaModel]
        )
    }

    var pendingCount: Int { suggestions.count }

    func pathSuggestions(for query: String, limit: Int = 8) -> [String] {
        FolderPathAutocomplete.matches(query: query, candidates: knownFolderPaths, limit: limit)
    }

    func checkForUpdates(manual: Bool = false) async {
        guard !updateCheckRunning else { return }
        updateCheckRunning = true
        if manual { updateCheckStatus = "正在检查…" }
        defer { updateCheckRunning = false }
        do {
            availableUpdate = try await UpdateChecker.latest()
            if manual {
                updateCheckStatus = availableUpdate == nil ? "当前已经是最新版本" : "发现新版本 \(availableUpdate!.version)"
            }
        } catch {
            if manual { updateCheckStatus = "暂时无法检查更新，请稍后重试" }
        }
    }

    func downloadAvailableUpdate() {
        guard let url = availableUpdate?.downloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openUpdateReleasePage() {
        guard let url = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

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
        refreshPathAutocompleteIndex()
    }

    func addDestinationRoot() {
        guard let url = chooseFolder(prompt: "选择文件归档根目录") else { return }
        guard !destinationRoots.contains(where: { $0.path == url.path }) else { return }
        destinationRoots.append(DestinationRoot(path: url.path))
        persistSettings()
        refreshPathAutocompleteIndex()
    }

    func enableWholeHomeMonitoring() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        watchedFolders = [WatchedFolder(path: home.path)]
        persistSettings()
        restartMonitoring()
        refreshPathAutocompleteIndex()
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

    func completeWelcome() {
        defaults.set(true, forKey: "didCompleteWelcome")
        showWelcome = false
        Task { await startInitialAnalysis() }
    }

    private func startInitialAnalysis() async {
        guard !hasStartedInitialAnalysis else { return }
        hasStartedInitialAnalysis = true
        let hadCachedProfiles = !folderKnowledgeProfiles.isEmpty
        // A warm launch can classify immediately from the last good index while
        // a refreshed snapshot is built in the background for future files.
        if hadCachedProfiles, autoScanExisting { analyzeExistingFiles(limit: 12) }
        await refreshFolderKnowledge()
        await checkOllamaSetup()
        if !hadCachedProfiles, autoScanExisting { analyzeExistingFiles(limit: 12) }
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
        refreshPathAutocompleteIndex()
    }

    func removeDestinationRoot(_ root: DestinationRoot) {
        guard destinationRoots.count > 1 else { return }
        destinationRoots.removeAll { $0 == root }
        persistSettings()
        refreshPathAutocompleteIndex()
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
        let filesToQueue = Array(selected.prefix(safeLimit))
        guard !filesToQueue.isEmpty else {
            existingScanStatus = "没有发现需要分析的现有文件"
            return
        }
        // Relationship inference must not depend on queue order. Pre-read a
        // larger but bounded, root-balanced corpus before publishing the first
        // suggestion. Mix recent and evenly-spaced historical files so one
        // recent burst cannot redefine the user's whole relationship graph.
        let corpusLimit = min(totalCount, min(240, max(160, safeLimit * 2)))
        var corpus: [(url: URL, modified: Date)] = []
        var corpusPaths = Set<String>()
        let perGroupTarget = max(1, Int(ceil(Double(corpusLimit) / Double(max(1, groups.count)))))
        var balancedGroups: [[(url: URL, modified: Date)]] = []
        for group in groups where !group.isEmpty {
            let target = min(group.count, perGroupTarget)
            let recentCount = min(target, max(8, target / 2))
            var sampled: [(url: URL, modified: Date)] = []
            var sampledPaths = Set<String>()
            for candidate in group.prefix(recentCount) {
                if sampledPaths.insert(candidate.url.standardizedFileURL.path).inserted { sampled.append(candidate) }
            }
            let historicalSlots = target - recentCount
            if historicalSlots > 0 {
                for slot in 0..<historicalSlots {
                    let position = Int(
                        (Double(slot + 1) / Double(historicalSlots + 1)) * Double(group.count - 1)
                    )
                    let candidate = group[position]
                    if sampledPaths.insert(candidate.url.standardizedFileURL.path).inserted { sampled.append(candidate) }
                }
            }
            balancedGroups.append(sampled)
        }
        let maximumDepth = balancedGroups.map(\.count).max() ?? 0
        for depth in 0..<maximumDepth {
            for sampled in balancedGroups where sampled.indices.contains(depth) {
                let candidate = sampled[depth]
                if corpusPaths.insert(candidate.url.standardizedFileURL.path).inserted { corpus.append(candidate) }
            }
        }
        if corpus.count < corpusLimit {
            for candidate in groups.flatMap({ $0 }).sorted(by: { $0.modified > $1.modified }) {
                guard corpus.count < corpusLimit else { break }
                if corpusPaths.insert(candidate.url.standardizedFileURL.path).inserted { corpus.append(candidate) }
            }
        }
        let relationshipCorpus = Array(corpus.prefix(corpusLimit))
        let immediateCorpus = Array(relationshipCorpus.prefix(min(96, relationshipCorpus.count)))
        let enrichmentCorpus = Array(relationshipCorpus.dropFirst(immediateCorpus.count))
        existingScanStatus = "发现 \(totalCount) 个现有文件，正在预读 \(immediateCorpus.count) 个文件并建立关系图…"
        relationshipScanTask?.cancel()
        relationshipScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.preloadRelationshipContent(immediateCorpus)
            guard !Task.isCancelled else { return }
            self.trimRelationshipCorpus(keeping: Set(filesToQueue.map { $0.url.standardizedFileURL.path }))
            self.existingScanStatus = enrichmentCorpus.isEmpty
                ? "关系图已就绪；已从 \(groups.count) 个入口均衡加入 \(filesToQueue.count) 个到分析队列"
                : "核心关系图已就绪；正在后台扩充到 \(relationshipCorpus.count) 个文件"
            for candidate in filesToQueue { self.enqueueFile(candidate.url, allowExisting: true) }
            guard !enrichmentCorpus.isEmpty else { return }
            await self.preloadRelationshipContent(enrichmentCorpus)
            guard !Task.isCancelled else { return }
            self.trimRelationshipCorpus(keeping: Set(filesToQueue.map { $0.url.standardizedFileURL.path }))
            self.suggestions = RelatedFileConsensus.consolidate(
                self.suggestions,
                contents: self.recentContentByPath,
                roots: self.effectiveDestinationURLs()
            )
            self.existingScanStatus = "关系图已扩充到 \(relationshipCorpus.count) 个文件；当前建议已重新校准"
        }
    }

    func chooseAndAuditFolder() {
        guard let folder = chooseFolder(prompt: "选择要检查主题一致性的文件夹") else { return }
        Task { await auditFolder(folder) }
    }

    func rebuildFolderKnowledge() {
        Task { await refreshFolderKnowledge() }
    }

    func confirm(_ suggestion: FileSuggestion, fileName rawFileName: String? = nil) {
        if let prerequisite = relocationPrerequisite(for: suggestion) {
            state = .error("请先处理文件夹“\(prerequisite.source.lastPathComponent)”的迁移建议；完成后本文件会自动使用其实际新路径。")
            return
        }
        state = .moving
        do {
            let originalQueuedSuggestion = suggestions.first { $0.id == suggestion.id }
            let plannedDirectoryPath = originalQueuedSuggestion.flatMap { queued -> URL? in
                (try? queued.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    ? queued.finalDestinationURL
                    : nil
            }
            let approvedFileName = normalizedFileName(
                rawFileName ?? suggestion.proposedFileName,
                source: suggestion.source
            )
            learningStore.record(
                source: suggestion.source,
                summary: suggestion.summary,
                destination: suggestion.finalDestinationFolder,
                proposedFileName: suggestion.proposedFileName,
                approvedFileName: approvedFileName
            )
            learningSummary = learningStore.summary
            if suggestion.source.deletingLastPathComponent().standardizedFileURL == suggestion.finalDestinationFolder.standardizedFileURL,
               approvedFileName == suggestion.source.lastPathComponent {
                suggestions.removeAll { $0.id == suggestion.id }
                state = suggestions.isEmpty ? .waiting : .ready
                Task { await updateKnowledgeProfile(for: suggestion.finalDestinationFolder) }
                return
            }
            let record = try FileMover.move(
                suggestion.source,
                to: suggestion.finalDestinationFolder,
                preferredFileName: approvedFileName
            )
            ignoredPaths.insert(record.destinationPath)
            moveHistory.insert(record, at: 0)
            if let plannedDirectoryPath {
                suggestions = SuggestionDependencyResolver.retargetDependents(
                    in: suggestions,
                    from: plannedDirectoryPath,
                    to: URL(fileURLWithPath: record.destinationPath, isDirectory: true),
                    reasonSuffix: "；候选文件夹已迁移，目标已同步为实际落地路径"
                )
            }
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
            detectedAt: suggestion.detectedAt,
            proposedFileName: suggestion.proposedFileName
        )
        confirm(updated)
    }

    func confirmEditedPath(_ rawPath: String, fileName: String? = nil, for suggestion: FileSuggestion) {
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
            detectedAt: suggestion.detectedAt,
            proposedFileName: fileName ?? suggestion.proposedFileName
        )
        confirm(updated, fileName: fileName)
    }

    func dismiss(_ suggestion: FileSuggestion) {
        learningStore.recordRejection(
            source: suggestion.source,
            summary: suggestion.summary,
            destination: suggestion.finalDestinationFolder
        )
        learningSummary = learningStore.summary
        ignoredPaths.insert(suggestion.source.path)
        if (try? suggestion.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            suggestions = SuggestionDependencyResolver.retargetDependents(
                in: suggestions,
                from: suggestion.finalDestinationURL,
                to: suggestion.source,
                reasonSuffix: "；你已拒绝候选文件夹迁移，目标已回退到该文件夹当前位置"
            )
        }
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

    func relocationPrerequisite(for suggestion: FileSuggestion) -> FileSuggestion? {
        SuggestionDependencyResolver.relocationPrerequisite(for: suggestion, in: suggestions)
    }

    func resetLearning() {
        learningStore.reset()
        userProfileStore.resetObservations()
        learningSummary = learningStore.summary
        userProfileSummary = userProfileStore.snapshot.summary
    }

    private func normalizedFileName(_ rawName: String, source: URL) -> String {
        var name = URL(fileURLWithPath: rawName.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
        name = name.replacingOccurrences(of: #"[/:\\\x00-\x1F]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !name.isEmpty else { return source.lastPathComponent }
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory { return String(name.prefix(180)) }
        let originalExtension = source.pathExtension
        if !originalExtension.isEmpty {
            let candidate = URL(fileURLWithPath: name)
            let base = candidate.pathExtension.isEmpty
                ? candidate.lastPathComponent
                : candidate.deletingPathExtension().lastPathComponent
            name = "\(String(base.prefix(160))).\(originalExtension)"
            return name
        }
        return String(name.prefix(180))
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
              !FolderMonitor.shouldIgnore(path: url.path),
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
        let path = url.standardizedFileURL.path
        let content: ExtractedContent
        if let cached = recentContentByPath[path] {
            content = cached
        } else {
            content = await Task.detached(priority: .userInitiated) {
                await ContentExtractor.extract(from: url)
            }.value
        }
        recentContentByPath[url.standardizedFileURL.path] = content
        trimRelationshipCorpus(keeping: [url.standardizedFileURL.path])
        let suggestionEngine = engine
        let userProfile = userProfileStore.snapshot
        let academicTopic = suggestionEngine.specificTopicMatch(
            for: url, content: content, profile: userProfile
        )
        let contentIntent = suggestionEngine.strongContentIntent(for: url, content: content)
        let directProjectTopic = DocumentRelationshipEngine.specificTopicName(
            for: url, content: content
        )
        let topic = await Task.detached(priority: .userInitiated) {
            suggestionEngine.topicName(for: url, content: content, profile: userProfile)
        }.value
        let retrievedMemory = learningStore.recommendation(for: url, content: content, roots: roots)
        let learned = retrievedMemory.flatMap {
            suggestionEngine.acceptsPersonalMemory(
                $0, academicMatch: academicTopic, contentIntent: contentIntent
            ) ? $0 : nil
        }
        let profiles = folderKnowledgeProfiles
        var knowledgeCandidate = learned == nil ? await Task.detached(priority: .userInitiated) {
            FolderKnowledgeIndex.recommend(source: url, content: content, profiles: profiles)
        }.value : nil
        var embeddingShortlist: [FolderKnowledgeProfile] = []
        if learned == nil,
           aiBackend == .ollama || aiBackend == .automatic {
            embeddingStatus = "Ollama embedding 正在检索最相关的本地目录…"
            if let shortlist = await OllamaEmbeddingRetriever.shared.shortlist(
                source: url,
                content: content,
                profiles: profiles,
                model: ollamaEmbeddingModel
            ) {
                embeddingShortlist = shortlist
                knowledgeCandidate = await Task.detached(priority: .userInitiated) {
                    FolderKnowledgeIndex.recommend(source: url, content: content, profiles: shortlist)
                }.value
                embeddingStatus = knowledgeCandidate == nil
                    ? "Embedding 已召回候选，但证据门控选择拒绝推荐。"
                    : "Embedding 已缩小到 \(shortlist.count) 个候选，并通过本地多证据复核。"
            } else {
                embeddingStatus = "Ollama embedding 不可用或没有拉开候选差距，已安全回退。"
            }
        }
        if learned == nil, !embeddingShortlist.isEmpty,
           aiBackend == .ollama || aiBackend == .automatic,
           let rerank = await OllamaRecommender.rerankFolders(
                source: url,
                content: content,
                profiles: embeddingShortlist,
                model: ollamaModel
           ) {
            if let profile = rerank.profile {
                knowledgeCandidate = FolderKnowledgeRecommendation(
                    destination: URL(fileURLWithPath: profile.path, isDirectory: true),
                    score: rerank.confidence,
                    margin: rerank.confidence,
                    evidenceTerms: [rerank.reason],
                    evidenceChannels: ["Embedding 召回", "Ollama 语义复核"],
                    confidence: rerank.confidence
                )
                embeddingStatus = "本地模型已复核 embedding 候选。"
            } else {
                knowledgeCandidate = nil
                embeddingStatus = "本地模型判定候选主题均不可靠，已拒绝误归类。"
            }
        }
        let strongTitleCategory = suggestionEngine.strongTitleCategoryName(for: url)
        let knowledge = knowledgeCandidate.flatMap { candidate in
            if let contentIntent {
                return suggestionEngine.destination(
                    candidate.destination,
                    matchesCategoryNamed: contentIntent.folderName
                ) ? candidate : nil
            }
            if let academicTopic {
                if suggestionEngine.destination(
                    candidate.destination,
                    matchesCategoryNamed: academicTopic.folderName
                ) || candidate.evidenceChannels.contains("文件名/专属目录名") {
                    return candidate
                }
                return nil
            }
            guard let strongTitleCategory else { return candidate }
            return suggestionEngine.destination(
                candidate.destination,
                matchesCategoryNamed: strongTitleCategory
            ) ? candidate : nil
        }
        let novelThemeReady = learned == nil
            ? learningStore.observeNovelTheme(source: url, content: content, topic: topic)
            : false
        // New folders are restricted to reusable, bounded topic categories.
        // A strong title/body signal may propose one immediately; weaker themes
        // must first recur across three distinct files. Creation still requires
        // an explicit user confirmation.
        let allowCreatingFolder = learned == nil
            && (suggestionEngine.stableNewFolderName(
                for: url, content: content, profile: userProfile
            ) != nil || novelThemeReady)
        let contentFallback = await Task.detached(priority: .userInitiated) {
            suggestionEngine.suggest(
                for: url,
                content: content,
                roots: roots,
                allowCreatingFolder: allowCreatingFolder,
                profile: userProfile
            )
        }.value
        var fallback = contentFallback
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
            let channels = knowledge.evidenceChannels.joined(separator: " + ")
            fallback = FileSuggestion(
                id: fallback.id,
                source: url,
                destinationFolder: knowledge.destination,
                proposedFolderName: "",
                reason: "本地多证据 RAG：\(channels) 一致指向该目录；关键证据“\(terms)”（领先第二候选 \(Int(knowledge.margin * 100)) 分）",
                summary: fallback.summary,
                confidence: knowledge.confidence,
                createsFolder: false,
                detectedAt: fallback.detectedAt
            )
        }
        let refined = await refineSuggestion(
            source: url,
            content: content,
            roots: roots,
            fallback: fallback,
            hasGroundedRecommendation: learned != nil || knowledge != nil
        )
        var suggestion = sanitizeFolderCreation(
            refined,
            fallback: fallback,
            allowCreatingFolder: allowCreatingFolder
        )
        if let group = DocumentRelationshipEngine.namedRecommendation(
            for: url,
            content: content,
            corpus: recentContentByPath
        ), let root = roots.first?.standardizedFileURL {
            let target = root.appendingPathComponent(group.topicName, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: target.path)
            suggestion = FileSuggestion(
                id: suggestion.id,
                source: suggestion.source,
                destinationFolder: exists ? target : root,
                proposedFolderName: exists ? "" : group.topicName,
                reason: "文件关系图（发布前校验）：与“\(group.peerNames.joined(separator: "、"))”具有同一结构化主题，直接归入“\(group.topicName)”，不发布较弱的目录近似结果。",
                summary: suggestion.summary,
                confidence: max(0.86, group.score),
                createsFolder: !exists,
                detectedAt: suggestion.detectedAt,
                proposedFileName: suggestion.proposedFileName
            )
        }
        suggestion = sanitizeHierarchyConflict(
            suggestion,
            source: url,
            content: content,
            roots: roots,
            profiles: profiles
        )
        suggestion = enforceAcademicBoundary(
            suggestion,
            academicTopic: academicTopic,
            fallback: contentFallback
        )
        suggestion = enforceContentIntentBoundary(
            suggestion,
            contentIntent: contentIntent,
            fallback: contentFallback
        )
        if let directProjectTopic, let root = roots.first?.standardizedFileURL {
            let target = root.appendingPathComponent(directProjectTopic, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: target.path)
            suggestion = FileSuggestion(
                id: suggestion.id,
                source: suggestion.source,
                destinationFolder: exists ? target : root,
                proposedFolderName: exists ? "" : directProjectTopic,
                reason: "专属项目识别：文件名中的项目标识与正文主题共同指向“\(directProjectTopic)”，优先于宽泛学科和目录近似结果。",
                summary: suggestion.summary,
                confidence: max(0.92, suggestion.confidence),
                createsFolder: !exists,
                detectedAt: suggestion.detectedAt,
                proposedFileName: suggestion.proposedFileName
            )
        }
        if let fileName = FileNameSuggester.suggest(
            source: url,
            content: content,
            academic: academicTopic,
            preferredSeparator: learningStore.preferredFileNameSeparator
        ) {
            suggestion = FileSuggestion(
                id: suggestion.id,
                source: suggestion.source,
                destinationFolder: suggestion.destinationFolder,
                proposedFolderName: suggestion.proposedFolderName,
                reason: suggestion.reason + "；命名建议：" + fileName.reason,
                summary: suggestion.summary,
                confidence: max(suggestion.confidence, fileName.confidence),
                createsFolder: suggestion.createsFolder,
                detectedAt: suggestion.detectedAt,
                proposedFileName: fileName.fileName
            )
        }
        learningSummary = learningStore.summary
        userProfileStore.observe(source: url, content: content)
        userProfileSummary = userProfileStore.snapshot.summary
        suggestions.append(suggestion)
        suggestions = SeriesConsensus.consolidate(suggestions, roots: roots)
        suggestions = RelatedFileConsensus.consolidate(
            suggestions,
            contents: recentContentByPath,
            roots: roots
        )
        // Consensus is the final mutation stage, so apply the same semantic
        // boundary once more at the publication edge. No late graph, series,
        // RAG, model, or memory decision may reintroduce a subject conflict.
        if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            suggestions[index] = enforceAcademicBoundary(
                suggestions[index],
                academicTopic: academicTopic,
                fallback: contentFallback
            )
            suggestions[index] = enforceContentIntentBoundary(
                suggestions[index],
                contentIntent: contentIntent,
                fallback: contentFallback
            )
        }
        let emittedSuggestion = suggestions.first(where: { $0.id == suggestion.id }) ?? suggestion
        state = .ready
        SavePanelObserver.writeRuntimeDiagnostics(RuntimeDiagnostics(
            lastAnalyzedFile: url.path,
            suggestedDestination: emittedSuggestion.finalDestinationFolder.path,
            pendingSuggestions: suggestions.count,
            processedAt: Date(),
            recentSuggestions: suggestions.suffix(30).map {
                RuntimeDiagnostics.SuggestionSnapshot(
                    file: $0.source.path,
                    destination: $0.finalDestinationFolder.path,
                    reason: $0.reason,
                    confidence: $0.confidence,
                    createsFolder: $0.createsFolder,
                    suggestedFileName: $0.proposedFileName
                )
            }
        ))
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showReviewWindow, object: nil)
    }

    private func trimRelationshipCorpus(keeping protectedPaths: Set<String>) {
        guard recentContentByPath.count > 360 else { return }
        let active = Set(suggestions.suffix(120).map { $0.source.standardizedFileURL.path })
            .union(protectedPaths)
        let retained = recentContentByPath.keys.sorted().filter { active.contains($0) }
        var result = Dictionary(uniqueKeysWithValues: retained.compactMap { path in
            recentContentByPath[path].map { (path, $0) }
        })
        for path in recentContentByPath.keys.sorted() where result.count < 320 {
            if let content = recentContentByPath[path] { result[path] = content }
        }
        recentContentByPath = result
    }

    private func preloadRelationshipContent(_ candidates: [(url: URL, modified: Date)]) async {
        for start in stride(from: 0, to: candidates.count, by: 6) {
            guard !Task.isCancelled else { return }
            let chunk = Array(candidates[start..<min(start + 6, candidates.count)])
            let missing = chunk.filter { recentContentByPath[$0.url.standardizedFileURL.path] == nil }
            let extracted = await withTaskGroup(of: (String, ExtractedContent).self) { group in
                for candidate in missing {
                    group.addTask {
                        let value = await ContentExtractor.extract(from: candidate.url)
                        return (candidate.url.standardizedFileURL.path, value)
                    }
                }
                var values: [(String, ExtractedContent)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (path, content) in extracted { recentContentByPath[path] = content }
        }
    }

    private func sanitizeHierarchyConflict(
        _ suggestion: FileSuggestion,
        source: URL,
        content: ExtractedContent,
        roots: [URL],
        profiles: [FolderKnowledgeProfile]
    ) -> FileSuggestion {
        guard let conflict = FolderKnowledgeIndex.hierarchyConflict(
            containing: suggestion.finalDestinationFolder,
            profiles: profiles
        ), let root = roots.first?.standardizedFileURL else { return suggestion }
        let project = DocumentRelationshipEngine.specificTopicName(for: source, content: content)
        let plannedFolder = ensureHierarchyRelocationSuggestion(
            conflict: conflict,
            projectName: project,
            root: root,
            profiles: profiles
        )
        let child = URL(fileURLWithPath: conflict.childPath, isDirectory: true).standardizedFileURL
        return FileSuggestion(
            id: suggestion.id,
            source: suggestion.source,
            destinationFolder: plannedFolder,
            proposedFolderName: "",
            reason: "目录层级图校验：文件内容适合候选目录“\(child.lastPathComponent)”，但该目录与上级“\(URL(fileURLWithPath: conflict.parentPath).lastPathComponent)”存在 \(conflict.parentSubject)→\(conflict.childSubject) 主题冲突。已先生成文件夹迁移建议；本文件的目标使用迁移后的正确路径“\(plannedFolder.path)”。",
            summary: suggestion.summary,
            confidence: max(0.78, min(suggestion.confidence, conflict.confidence)),
            createsFolder: false,
            detectedAt: suggestion.detectedAt,
            proposedFileName: suggestion.proposedFileName
        )
    }

    private func enforceAcademicBoundary(
        _ suggestion: FileSuggestion,
        academicTopic: AcademicSubjectMatch?,
        fallback: FileSuggestion
    ) -> FileSuggestion {
        guard let academicTopic,
              engine.destinationConflictsWithAcademicTopic(
                suggestion.finalDestinationFolder,
                match: academicTopic
              ),
              let destinationTopic = AcademicSubjectClassifier.classify(
                title: suggestion.finalDestinationFolder.lastPathComponent, body: ""
              )
        else { return suggestion }
        return FileSuggestion(
            id: fallback.id,
            source: fallback.source,
            destinationFolder: fallback.destinationFolder,
            proposedFolderName: fallback.proposedFolderName,
            reason: "学科边界校验：正文以 \(Int(academicTopic.confidence * 100))% 置信度识别为“\(academicTopic.folderName)”，已拒绝冲突的“\(destinationTopic.folderName)”目录候选。\(fallback.reason)",
            summary: fallback.summary,
            confidence: academicTopic.confidence,
            createsFolder: fallback.createsFolder,
            detectedAt: fallback.detectedAt,
            proposedFileName: fallback.proposedFileName
        )
    }

    private func enforceContentIntentBoundary(
        _ suggestion: FileSuggestion,
        contentIntent: StrongContentIntent?,
        fallback: FileSuggestion
    ) -> FileSuggestion {
        guard let contentIntent,
              !engine.destination(
                  suggestion.finalDestinationFolder,
                  matchesCategoryNamed: contentIntent.folderName
              )
        else { return suggestion }
        return FileSuggestion(
            id: fallback.id,
            source: fallback.source,
            destinationFolder: fallback.destinationFolder,
            proposedFolderName: fallback.proposedFolderName,
            reason: "内容用途边界：以 \(Int(contentIntent.confidence * 100))% 置信度识别为“\(contentIntent.folderName)”（\(contentIntent.evidence.joined(separator: "、"))），已拒绝用途不兼容的目录候选。\(fallback.reason)",
            summary: fallback.summary,
            confidence: contentIntent.confidence,
            createsFolder: fallback.createsFolder,
            detectedAt: fallback.detectedAt,
            proposedFileName: fallback.proposedFileName
        )
    }

    private func ensureHierarchyRelocationSuggestion(
        conflict: FolderHierarchyConflict,
        projectName: String?,
        root: URL,
        profiles: [FolderKnowledgeProfile]
    ) -> URL {
        let child = URL(fileURLWithPath: conflict.childPath, isDirectory: true).standardizedFileURL
        let plan = FolderKnowledgeIndex.relocationPlan(
            for: conflict,
            root: root,
            projectName: projectName
        )
        let plannedFolder = plan.finalFolder
        guard FileManager.default.fileExists(atPath: child.path),
              !suggestions.contains(where: { $0.source.standardizedFileURL == child })
        else { return plannedFolder }
        let profile = profiles.first { $0.path == conflict.childPath }
        suggestions.append(FileSuggestion(
            id: UUID(),
            source: child,
            destinationFolder: plan.destinationContainer,
            proposedFolderName: "",
            reason: "目录关系建议：该子文件夹的多数内容属于“\(conflict.childSubject)”，与上级“\(URL(fileURLWithPath: conflict.parentPath).lastPathComponent)”的“\(conflict.parentSubject)”用途冲突。建议将整个文件夹迁出；这是一条独立建议，可单独确认。",
            summary: "抽样 \(profile?.sampledFiles ?? 0) 个文件；主题一致度 \(Int((profile?.coherence ?? 0) * 100))%。",
            confidence: conflict.confidence,
            createsFolder: false,
            detectedAt: Date(),
            proposedFileName: plan.finalFolderName
        ))
        return plannedFolder
    }

    private func refineSuggestion(
        source: URL,
        content: ExtractedContent,
        roots: [URL],
        fallback: FileSuggestion,
        hasGroundedRecommendation: Bool
    ) async -> FileSuggestion {
        // Personal feedback and the local folder-content index are grounded in
        // this user's real files. A generative model that only sees a compact
        // prompt must never overwrite that stronger evidence.
        if hasGroundedRecommendation { return fallback }
        let validate: (FileSuggestion?) -> FileSuggestion = { candidate in
            guard let candidate,
                  candidate.confidence >= 0.78,
                  self.engine.isPlausibleModelDestination(
                    source: source,
                    content: content,
                    destination: candidate.finalDestinationFolder
                  )
            else { return fallback }
            return candidate
        }
        switch aiBackend {
        case .automatic:
            return validate(await AppleFoundationRecommender.refine(
                source: source, content: content, roots: roots, fallback: fallback
            ))
        case .appleFoundation:
            return validate(await AppleFoundationRecommender.refine(
                source: source, content: content, roots: roots, fallback: fallback
            ))
        case .ollama:
            return validate(await OllamaRecommender.refine(
                source: source,
                content: content,
                roots: roots,
                fallback: fallback,
                model: ollamaModel
            ))
        case .deepseekCloud:
            if let apiKey = KeychainStore.loadDeepSeekKey() {
                return validate(await DeepSeekRecommender.refine(
                    source: source,
                    content: content,
                    roots: roots,
                    fallback: fallback,
                    apiKey: apiKey,
                    model: deepSeekModel,
                    sendDetailedContent: deepSeekSendDetailedContent
                ))
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

        let files = FolderAuditEngine.candidateEntries(in: folder, limit: 160)
        guard files.count >= 5 else {
            folderAuditStatus = "“\(folder.lastPathComponent)”中可分析的顶层文件或子文件夹不足 5 个。"
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
                        await FolderAuditEngine.auditDocument(for: url)
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
            FolderAuditEngine.findOutliers(in: documents, parentFolder: folder)
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
        let auditUserProfile = userProfileStore.snapshot
        var added = 0
        for outlier in outliers {
            let isDirectory = (try? outlier.document.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                || outlier.document.content.signals.contains("子文件夹主题")
            if isDirectory,
               let projectTopic = DocumentRelationshipEngine.specificTopicName(
                for: outlier.document.url, content: outlier.document.content
               ),
               let root = roots.first?.standardizedFileURL {
                let target = root.appendingPathComponent(projectTopic, isDirectory: true)
                let exists = FileManager.default.fileExists(atPath: target.path)
                let suggestion = FileSuggestion(
                    id: UUID(),
                    source: outlier.document.url,
                    destinationFolder: exists ? target : root,
                    proposedFolderName: exists ? "" : projectTopic,
                    reason: "文件夹审计：子目录内容与父目录用途不一致；文件关系图识别为独立项目“\(projectTopic)”",
                    summary: outlier.document.content.summary,
                    confidence: 0.90,
                    createsFolder: !exists,
                    detectedAt: Date()
                )
                if !suggestions.contains(where: { $0.source.standardizedFileURL == suggestion.source.standardizedFileURL }) {
                    suggestions.append(suggestion)
                    added += 1
                }
                continue
            }
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
            let topic = suggestionEngine.topicName(
                for: outlier.document.url,
                content: outlier.document.content,
                profile: auditUserProfile
            )
            let novelThemeReady = learningStore.observeNovelTheme(
                source: outlier.document.url,
                content: outlier.document.content,
                topic: topic
            )
            let allowCreatingFolder = suggestionEngine.stableNewFolderName(
                for: outlier.document.url,
                content: outlier.document.content,
                profile: auditUserProfile
            ) != nil || novelThemeReady
            let fallback = await Task.detached(priority: .userInitiated) {
                suggestionEngine.suggest(
                    for: outlier.document.url,
                    content: outlier.document.content,
                    roots: roots,
                    excludingFolders: Set([auditedPath]),
                    allowCreatingFolder: allowCreatingFolder,
                    profile: auditUserProfile
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
        userProfileStore.rebuild(from: profiles)
        userProfileSummary = userProfileStore.snapshot.summary
        await Task.detached(priority: .utility) {
            FolderKnowledgeIndex.save(profiles)
        }.value
        let samples = profiles.reduce(0) { $0 + $1.sampledFiles }
        let adaptive = profiles.filter { $0.sampledFiles > 3 }.count
        let hierarchyConflicts = FolderKnowledgeIndex.hierarchyConflicts(in: profiles)
        let hierarchyNote = hierarchyConflicts.isEmpty
            ? "父子目录关系未发现明显冲突"
            : "发现 \(hierarchyConflicts.count) 个父子目录主题冲突，已阻止继续向错位子目录推荐"
        folderKnowledgeStatus = "本地内容 RAG 已就绪：\(profiles.count) 个文件夹、\(samples) 个抽样文件；\(adaptive) 个混合主题目录已自动扩大抽样；\(hierarchyNote)。"
        refreshPathAutocompleteIndex()
    }

    private func refreshPathAutocompleteIndex() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardFolders = ["Desktop", "Documents", "Downloads"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        let roots = effectiveDestinationURLs() + watchedFolders.map(\.url) + standardFolders
        let known = folderKnowledgeProfiles.map(\.path)
        Task { @MainActor [weak self] in
            let paths = await Task.detached(priority: .utility) {
                FolderPathAutocomplete.discover(roots: roots, knownPaths: known)
            }.value
            self?.knownFolderPaths = paths
        }
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
        userProfileStore.rebuild(from: folderKnowledgeProfiles)
        userProfileSummary = userProfileStore.snapshot.summary
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
        ollamaEmbeddingModel = defaults.string(forKey: "ollamaEmbeddingModel") ?? "qwen3-embedding:4b"
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
        defaults.set(ollamaEmbeddingModel, forKey: "ollamaEmbeddingModel")
        defaults.set(deepSeekModel, forKey: "deepSeekModel")
        defaults.set(deepSeekSendDetailedContent, forKey: "deepSeekSendDetailedContent")
    }
}

extension Notification.Name {
    static let showReviewWindow = Notification.Name("SavePilot.showReviewWindow")
}
