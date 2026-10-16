import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("监听目录") {
                Text("写入完成后自动分析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.watchedFolders) { folder in
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        Text(folder.path).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            model.removeWatchedFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("添加监听目录…") { model.addWatchedFolder() }
                Button("监听所有个人文件（不含 Library）") { model.enableWholeHomeMonitoring() }
                Toggle("启动后自动分析桌面与下载中的现有文件", isOn: $model.autoScanExisting)
                if !model.existingScanStatus.isEmpty {
                    Text(model.existingScanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.folderAuditStatus.isEmpty {
                    Label(model.folderAuditStatus, systemImage: "folder.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.folderKnowledgeStatus.isEmpty {
                    Label(model.folderKnowledgeStatus, systemImage: "books.vertical")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("归档根目录") {
                Text("优先复用这里已有的文件夹；证据不足时保持原位。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.destinationRoots) { root in
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(root.path).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            model.removeDestinationRoot(root)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(model.destinationRoots.count <= 1)
                    }
                }
                Button("添加归档根目录…") { model.addDestinationRoot() }
            }

            Section("隐私与安全") {
                Label("内容分析完全在本机执行", systemImage: "lock.shield")
                Label("移动前必须人工确认", systemImage: "hand.raised")
                Label("同名文件永不覆盖，会自动添加序号", systemImage: "doc.on.doc")
            }

            Section("智能引擎") {
                Picker("模型", selection: $model.aiBackend) {
                    ForEach(AIBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                TextField("Ollama 复核模型", text: $model.ollamaModel)
                    .disabled(model.aiBackend != .ollama)
                TextField("Ollama Embedding 模型", text: $model.ollamaEmbeddingModel)
                    .disabled(model.aiBackend != .ollama)
                if model.aiBackend == .ollama {
                    Text("Embedding 找候选，复核模型处理歧义；离线时自动回退。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.embeddingStatus.isEmpty {
                        Text(model.embeddingStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(model.ollamaSetupStatus, systemImage: model.ollamaSetupStatus.contains("已就绪") ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.caption)
                        Spacer()
                        Button("重新检测") { Task { await model.checkOllamaSetup() } }
                    }
                }
                if model.aiBackend == .deepseekCloud {
                    TextField("DeepSeek 模型", text: $model.deepSeekModel)
                    SecureField("粘贴 DeepSeek API Key", text: $model.deepSeekAPIKeyDraft)
                    HStack {
                        Button("保存到钥匙串") { model.saveDeepSeekKey() }
                            .disabled(model.deepSeekAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("测试连接") { model.testDeepSeekConnection() }
                            .disabled(!model.deepSeekKeySaved)
                        Button("删除密钥", role: .destructive) { model.deleteDeepSeekKey() }
                            .disabled(!model.deepSeekKeySaved)
                        Spacer()
                        Label(
                            model.deepSeekKeySaved ? "钥匙串中已有密钥" : "尚未保存密钥",
                            systemImage: model.deepSeekKeySaved ? "key.fill" : "key"
                        )
                        .font(.caption)
                    }
                    Toggle("发送更详细的内容（最多 4,000 字符）", isOn: $model.deepSeekSendDetailedContent)
                    Text("关闭时只发送文件名、类型、实体和最多 600 字符的本机摘要。目录路径只发送末级名称；原文件不会上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.deepSeekStatus.isEmpty {
                        Text(model.deepSeekStatus)
                            .font(.caption)
                            .foregroundStyle(model.deepSeekStatus.contains("成功") ? .green : .secondary)
                            .textSelection(.enabled)
                    }
                }
                Text("自动模式优先本机模型；DeepSeek 仅在主动选择后联网。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(model.learningSummary, systemImage: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(model.userProfileSummary, systemImage: "person.text.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重建已有文件夹内容索引") {
                    model.rebuildFolderKnowledge()
                }
                Button("清除从确认操作中学到的规则", role: .destructive) {
                    model.resetLearning()
                }
            }

            Section("系统权限") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                HStack {
                    Label("辅助功能：\(model.accessibilityGranted ? "已授权" : "未授权")", systemImage: model.accessibilityGranted ? "checkmark.shield" : "exclamationmark.shield")
                    Spacer()
                    Button("授权…") { model.requestAccessibility() }
                }
                HStack {
                    Label(
                        "完全磁盘访问（可选）：\(model.fullDiskAccessGranted ? "检测通过" : "未检测到")",
                        systemImage: model.fullDiskAccessGranted ? "checkmark.shield" : "exclamationmark.shield"
                    )
                    Spacer()
                    Button("打开系统设置…") { model.openFullDiskAccessSettings() }
                }
                Label(
                    "监听目录：\(model.watchedFoldersReadable ? "均可读取" : "存在无法读取的目录")",
                    systemImage: model.watchedFoldersReadable ? "checkmark.circle" : "exclamationmark.triangle"
                )
                HStack {
                    Button("重新检测权限") { model.refreshPermissions() }
                    Spacer()
                    if let date = model.lastPermissionCheck {
                        Text("检测于 \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("辅助功能仅识别保存面板；系统目录、隐藏文件和应用数据始终跳过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 660, height: 650)
        .onAppear { model.refreshPermissions() }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = model.activeSavePanel, let hint = model.preSaveHint {
                Text("\(context.applicationName) 正在保存")
                    .font(.headline)
                Text(context.proposedFilename ?? "未命名文件")
                    .lineLimit(1)
                Label(hint.finalDestinationFolder.path, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(2)
                Button("复制推荐路径") { model.copyPreSaveDestination() }
            } else if model.pendingCount > 0 {
                Text("有 \(model.pendingCount) 个文件等待确认")
                    .font(.headline)
                ForEach(model.suggestions.prefix(4)) { suggestion in
                    Button {
                        openWindow(id: "review")
                    } label: {
                        HStack {
                            Image(systemName: "doc")
                            VStack(alignment: .leading) {
                                Text(suggestion.source.lastPathComponent).lineLimit(1)
                                Text("→ \(suggestion.finalDestinationFolder.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Label("正在监听 \(model.watchedFolders.count) 个目录", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Divider()
            Button("打开审核窗口") { openWindow(id: "review") }
            Button("扫描现有文件") {
                model.analyzeExistingFiles()
                openWindow(id: "review")
            }
            Button("检查文件夹归类…") {
                model.chooseAndAuditFolder()
                openWindow(id: "review")
            }
            .disabled(model.folderAuditRunning)
            Button("撤销上次移动") { model.undoLastMove() }
                .disabled(model.moveHistory.isEmpty)
            SettingsLink { Text("设置…") }
            Divider()
            Button("退出 SavePilot") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }
}
