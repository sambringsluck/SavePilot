import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSuggestionID: UUID?

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
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.suggestions.map(\.id)) { _, _ in
            selectFirstIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.analyzeExistingFiles()
                } label: {
                    Label("扫描现有文件", systemImage: "arrow.clockwise")
                }
                Button {
                    model.chooseAndAuditFolder()
                } label: {
                    Label("审计文件夹主题", systemImage: "folder.badge.questionmark")
                }
                .disabled(model.folderAuditRunning)
                Button {
                    model.undoLastMove()
                } label: {
                    Label("撤销上次移动", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.moveHistory.isEmpty)
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
                Text(suggestion.finalDestinationFolder.lastPathComponent)
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
                            .textSelection(.enabled)
                        Text(suggestion.source.deletingLastPathComponent().path)
                            .foregroundStyle(.secondary)
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
                        Text(suggestion.reason)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text("直接修改目标路径")
                            .font(.caption.bold())
                        TextField("~/Documents/目标文件夹", text: $editedPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { model.confirmEditedPath(editedPath, fileName: editedFileName, for: suggestion) }
                        HStack {
                            Label(
                                editedFolderExists ? "目录已存在" : "目录不存在，确认后新建",
                                systemImage: editedFolderExists ? "folder.fill" : "folder.badge.plus"
                            )
                            .font(.caption)
                            .foregroundStyle(editedPathIsValid ? Color.secondary : Color.red)
                            Spacer()
                            Button("按此路径存放") {
                                model.confirmEditedPath(editedPath, fileName: editedFileName, for: suggestion)
                            }
                            .disabled(!editedPathIsValid)
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
                    Button("选择其他位置…") { model.chooseAndConfirm(suggestion) }
                    Button(isKeepingOriginalLocationAndName ? "确认保留原位" : "确认存放") {
                        model.confirm(suggestion, fileName: editedFileName)
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
        }
    }

    private var expandedEditedPath: String {
        (editedPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private var editedPathIsValid: Bool {
        expandedEditedPath.hasPrefix("/") && expandedEditedPath != "/"
    }

    private var editedFolderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expandedEditedPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var isKeepingOriginalLocationAndName: Bool {
        suggestion.source.deletingLastPathComponent().standardizedFileURL == suggestion.finalDestinationFolder.standardizedFileURL
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
                Text("把文件保存到监听目录后，SavePilot 会读取内容并提出存放建议。未经确认不会移动任何文件。")
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
                Button("扫描全部现有文件") {
                    model.analyzeExistingFiles(limit: 100)
                }
                .buttonStyle(.borderedProminent)
                SettingsLink { Text("检查权限与设置") }
                Button(model.folderAuditRunning ? "正在审计文件夹…" : "检查一个文件夹中可能放错的文件") {
                    model.chooseAndAuditFolder()
                }
                .disabled(model.folderAuditRunning)
            }
        }
    }
}
