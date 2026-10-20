import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSuggestionID: UUID?
    @State private var showingUpdate = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSuggestionID) {
                Section("等待确认 · \(model.suggestions.count)") {
                    ForEach(model.suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion)
                            .tag(suggestion.id)
                    }
                }

                if !model.moveHistory.isEmpty {
                    Section("最近移动") {
                        ForEach(model.moveHistory.prefix(10)) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: record.destinationPath).lastPathComponent)
                                    .lineLimit(1)
                                Text(URL(fileURLWithPath: record.destinationPath).deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("SavePilot")
            .frame(minWidth: 250)
        } detail: {
            if let suggestion = selectedSuggestion {
                SuggestionDetail(suggestion: suggestion)
                    .id(suggestion.id)
            } else if let hint = model.preSaveHint, let context = model.activeSavePanel {
                PreSaveHintView(suggestion: hint, context: context)
            } else {
                EmptyReviewView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .sheet(isPresented: $model.showWelcome) {
            WelcomeView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingUpdate) {
            if let update = model.availableUpdate {
                UpdateView(update: update)
                    .environmentObject(model)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.suggestions.map(\.id)) { _, _ in
            selectFirstIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup {
                if let update = model.availableUpdate {
                    Button {
                        showingUpdate = true
                    } label: {
                        Label("新版本", systemImage: "arrow.down.circle.fill")
                    }
                    .help("下载 SavePilot \(update.version)")
                }
                Button {
                    model.analyzeExistingFiles()
                } label: {
                    Label("扫描现有文件", systemImage: "arrow.clockwise")
                }
                .help("重新扫描桌面、下载与监听目录")
                Button {
                    model.chooseAndAuditFolder()
                } label: {
                    Label("检查文件夹归类", systemImage: "magnifyingglass")
                }
                .disabled(model.folderAuditRunning)
                .help("检查文件夹中可能放错的文件和子文件夹")
                Button {
                    model.undoLastMove()
                } label: {
                    Label("撤销上次移动", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.moveHistory.isEmpty)
                .help("撤销最近一次由 SavePilot 完成的移动")
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("打开 SavePilot 设置（⌘,）")
            }
        }
    }

    private var selectedSuggestion: FileSuggestion? {
        if let selectedSuggestionID,
           let selected = model.suggestions.first(where: { $0.id == selectedSuggestionID }) {
            return selected
        }
        return model.suggestions.first
    }

    private func selectFirstIfNeeded() {
        guard !model.suggestions.isEmpty else {
            selectedSuggestionID = nil
            return
        }
        if selectedSuggestionID == nil || !model.suggestions.contains(where: { $0.id == selectedSuggestionID }) {
            selectedSuggestionID = model.suggestions.first?.id
        }
    }
}

private struct UpdateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let update: AppUpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现新版本 \(update.version)")
                        .font(.title2.bold())
                    Text(update.title)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(update.notes.isEmpty ? "包含最新的功能改进和问题修复。" : update.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("查看发布页") { model.openUpdateReleasePage() }
                Spacer()
                Button("稍后") { dismiss() }
                Button("下载更新") { model.downloadAvailableUpdate() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 360)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text("欢迎使用 SavePilot")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("监听桌面与下载", systemImage: "tray.and.arrow.down")
                Label("默认归档到文稿，可在设置中更改", systemImage: "folder")
                Label("任何移动都需要你确认", systemImage: "hand.raised")
                HStack {
                    Label("可选：Ollama 提升语义匹配", systemImage: "sparkles")
                    Spacer()
                    Link("下载…", destination: URL(string: "https://ollama.com/download")!)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            HStack {
                Button(model.accessibilityGranted ? "辅助功能已开启" : "开启辅助功能") {
                    if model.accessibilityGranted {
                        model.refreshPermissions()
                    } else {
                        model.requestAccessibility()
                    }
                }
                .disabled(model.accessibilityGranted)
                Spacer()
                Button("开始使用") { model.completeWelcome() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}

private struct PreSaveHintView: View {
    @EnvironmentObject private var model: AppModel
    let suggestion: FileSuggestion
    let context: SavePanelContext

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.system(size: 54))
                .foregroundStyle(.blue)
            Text("检测到 \(context.applicationName) 正在保存")
                .font(.title2.bold())
            Text(context.proposedFilename ?? "未命名文件")
                .font(.headline)
            GroupBox("落盘前初步建议") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(suggestion.finalDestinationFolder.path)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text("此时只能根据文件名和来源应用预判；文件写完后会读取真实内容并再次确认。")
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("复制推荐路径") { model.copyPreSaveDestination() }
                .buttonStyle(.borderedProminent)
            Text("可在系统保存面板按 ⌘⇧G，然后粘贴路径快速跳转。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: 620)
    }
}

private struct SuggestionRow: View {
    let suggestion: FileSuggestion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.source.lastPathComponent)
                    .lineLimit(1)
                Text("→ \(suggestion.finalDestinationFolder.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        if isDirectory { return "folder" }
        switch suggestion.source.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic": return "photo"
        case "zip", "rar", "7z": return "archivebox"
        default: return "doc"
        }
    }

    private var isDirectory: Bool {
        (try? suggestion.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct SuggestionDetail: View {
    @EnvironmentObject private var model: AppModel
    let suggestion: FileSuggestion
    @State private var editedPath: String
    @State private var editedFileName: String
    @State private var displayedPathSuggestions: [String] = []
    @State private var pathSearchTask: Task<Void, Never>?
    @FocusState private var pathFieldFocused: Bool

    init(suggestion: FileSuggestion) {
        self.suggestion = suggestion
        _editedPath = State(initialValue: suggestion.finalDestinationFolder.path)
        _editedFileName = State(initialValue: suggestion.proposedFileName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.source.lastPathComponent)
                            .font(.title2.bold())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(suggestion.source.deletingLastPathComponent().path)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    ConfidenceBadge(value: suggestion.confidence)
                }

                GroupBox("推荐存放位置") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: suggestion.createsFolder ? "folder.badge.plus" : "folder")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            Text(suggestion.finalDestinationFolder.path)
                                .font(.headline)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            if suggestion.createsFolder {
                                Text("将新建")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.blue.opacity(0.12), in: Capsule())
                            }
                        }
                        DisclosureGroup("推荐依据") {
                            Text(suggestion.reason)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        if let prerequisite = editedRelocationPrerequisite {
                            Label(
                                "请先在左侧确认或拒绝“\(prerequisite.source.lastPathComponent)”的文件夹迁移建议",
                                systemImage: "arrow.triangle.branch"
                            )
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        }
                        Divider()
                        Text("直接修改目标路径")
                            .font(.caption.bold())
                        TextField("~/Documents/目标文件夹", text: $editedPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .focused($pathFieldFocused)
                            .onSubmit { confirmCurrentChoice() }
                            .onChange(of: editedPath) { _, value in schedulePathSearch(value) }
                            .onChange(of: pathFieldFocused) { _, focused in
                                if focused { schedulePathSearch(editedPath) }
                                else {
                                    pathSearchTask?.cancel()
                                    displayedPathSuggestions = []
                                }
                            }
                        if pathFieldFocused, !displayedPathSuggestions.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(displayedPathSuggestions, id: \.self) { path in
                                    Button {
                                        editedPath = path
                                        displayedPathSuggestions = []
                                        pathFieldFocused = false
                                    } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: "folder")
                                                .foregroundStyle(.blue)
                                            Text(path)
                                                .font(.system(.caption, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    if path != displayedPathSuggestions.last { Divider() }
                                }
                            }
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        }
                        HStack {
                            Label(
                                editedFolderExists ? "目录已存在" : "目录不存在，确认后新建",
                                systemImage: editedFolderExists ? "folder.fill" : "folder.badge.plus"
                            )
                            .font(.caption)
                            .foregroundStyle(editedPathIsValid ? Color.secondary : Color.red)
                            Spacer()
                            Button("按此路径存放") {
                                confirmCurrentChoice()
                            }
                            .disabled(!canConfirmCurrentChoice)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox("识别到的内容") {
                    Text(suggestion.summary.isEmpty ? "没有可显示的摘要" : suggestion.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }

                if suggestion.proposedFileName != suggestion.source.lastPathComponent {
                    GroupBox(isDirectory ? "推荐文件夹名称" : "推荐文件名") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField(suggestion.source.lastPathComponent, text: $editedFileName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            HStack {
                                if editedFileName != suggestion.source.lastPathComponent {
                                    Label("将从“\(suggestion.source.lastPathComponent)”重命名", systemImage: "pencil.and.outline")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Label(isDirectory ? "保持原文件夹名称" : "保持原文件名", systemImage: isDirectory ? "folder" : "doc")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("使用原名") { editedFileName = suggestion.source.lastPathComponent }
                            }
                            Text(isDirectory ? "确认后会移动整个文件夹及其内容；可随时撤销。" : "扩展名会强制保留；只有确认后才会重命名。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                }

                HStack {
                    Button("在 Finder 中查看") { model.reveal(suggestion.source) }
                    Spacer()
                    Button("保留原位") { model.dismiss(suggestion) }
                        .help("拒绝当前建议，不移动或重命名该项目")
                    Button("其他位置…") { model.chooseAndConfirm(suggestion) }
                    Button(isKeepingOriginalLocationAndName ? "确认保留" : "确认") {
                        confirmCurrentChoice()
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConfirmCurrentChoice)
                }
            }
            .padding(28)
        }
        .onDisappear { pathSearchTask?.cancel() }
    }

    private var expandedEditedPath: String {
        (editedPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private func schedulePathSearch(_ query: String) {
        pathSearchTask?.cancel()
        guard pathFieldFocused else { return }
        pathSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, pathFieldFocused, editedPath == query else { return }
            displayedPathSuggestions = model.pathSuggestions(for: query)
                .filter { $0 != expandedEditedPath }
        }
    }

    private var editedPathIsValid: Bool {
        expandedEditedPath.hasPrefix("/") && expandedEditedPath != "/"
    }

    private var editedFolderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expandedEditedPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var editedSuggestion: FileSuggestion? {
        guard editedPathIsValid else { return nil }
        return FileSuggestion(
            id: suggestion.id,
            source: suggestion.source,
            destinationFolder: URL(fileURLWithPath: expandedEditedPath, isDirectory: true).standardizedFileURL,
            proposedFolderName: "",
            reason: suggestion.reason,
            summary: suggestion.summary,
            confidence: suggestion.confidence,
            createsFolder: false,
            detectedAt: suggestion.detectedAt,
            proposedFileName: editedFileName
        )
    }

    private var editedRelocationPrerequisite: FileSuggestion? {
        editedSuggestion.flatMap { model.relocationPrerequisite(for: $0) }
    }

    private var canConfirmCurrentChoice: Bool {
        editedPathIsValid && editedRelocationPrerequisite == nil
    }

    private func confirmCurrentChoice() {
        guard canConfirmCurrentChoice else { return }
        model.confirmEditedPath(editedPath, fileName: editedFileName, for: suggestion)
    }

    private var isKeepingOriginalLocationAndName: Bool {
        guard let destination = editedSuggestion?.finalDestinationFolder else { return false }
        return suggestion.source.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL
            && editedFileName == suggestion.source.lastPathComponent
    }

    private var isDirectory: Bool {
        (try? suggestion.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct ConfidenceBadge: View {
    let value: Double

    var body: some View {
        Text("置信度 \(Int(value * 100))%")
            .font(.caption.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        value >= 0.8 ? .green : value >= 0.65 ? .orange : .secondary
    }
}

private struct EmptyReviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("正在守候新文件", systemImage: "tray.and.arrow.down")
        } description: {
            VStack(spacing: 5) {
                Text("保存到监听目录后，建议会出现在这里。")
                if !model.existingScanStatus.isEmpty {
                    Text(model.existingScanStatus)
                        .font(.caption)
                }
                if !model.folderAuditStatus.isEmpty {
                    Text(model.folderAuditStatus)
                        .font(.caption)
                }
            }
        } actions: {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Label(
                        model.accessibilityGranted ? "保存面板识别已开启" : "保存面板识别未授权",
                        systemImage: model.accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield"
                    )
                    Label(
                        model.watchedFoldersReadable ? "监听目录可读取" : "监听目录权限不足",
                        systemImage: model.watchedFoldersReadable ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                }
                .font(.caption)
                Button("扫描现有文件") {
                    model.analyzeExistingFiles(limit: 100)
                }
                .buttonStyle(.borderedProminent)
                SettingsLink { Text("设置") }
                Button(model.folderAuditRunning ? "正在检查…" : "检查文件夹归类") {
                    model.chooseAndAuditFolder()
                }
                .disabled(model.folderAuditRunning)
            }
        }
    }
}
