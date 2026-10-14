import AppKit
import ApplicationServices
import Foundation

struct SavePanelContext: Equatable {
    let applicationName: String
    let proposedFilename: String?
    let detectedAt: Date

    static func == (lhs: SavePanelContext, rhs: SavePanelContext) -> Bool {
        lhs.applicationName == rhs.applicationName && lhs.proposedFilename == rhs.proposedFilename
    }
}

struct SystemPermissionSnapshot: Codable {
    let accessibility: Bool
    let fullDiskAccess: Bool
    let watchedFoldersReadable: Bool
    let checkedAt: Date
    let appVersion: String
}

struct RuntimeDiagnostics: Codable {
    struct SuggestionSnapshot: Codable {
        let file: String
        let destination: String
        let reason: String
        let confidence: Double
        let createsFolder: Bool
    }

    let lastAnalyzedFile: String
    let suggestedDestination: String
    let pendingSuggestions: Int
    let processedAt: Date
    let recentSuggestions: [SuggestionSnapshot]
}

final class SavePanelObserver {
    private var timer: Timer?
    private var lastContext: SavePanelContext?
    private let onChange: (SavePanelContext?) -> Void

    init(onChange: @escaping (SavePanelContext?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func fullDiskAccessGranted() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedLocations = [
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
        ]
        for location in protectedLocations {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: location.path),
               !contents.isEmpty || FileManager.default.fileExists(atPath: location.path) {
                return true
            }
        }
        return false
    }

    static func watchedFoldersReadable(_ folders: [URL]) -> Bool {
        guard !folders.isEmpty else { return false }
        return folders.allSatisfy { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) != nil
        }
    }

    static func writeDiagnostics(_ snapshot: SystemPermissionSnapshot) {
        writeJSON(snapshot, filename: "diagnostics.json")
    }

    static func writeRuntimeDiagnostics(_ snapshot: RuntimeDiagnostics) {
        writeJSON(snapshot, filename: "runtime.json")
    }

    private static func writeJSON<T: Encodable>(_ value: T, filename: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SavePilot", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(
                to: directory.appendingPathComponent(filename),
                options: .atomic
            )
        } catch {
            // Diagnostics must never prevent the app from launching.
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func poll() {
        guard Self.accessibilityGranted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            publish(nil)
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let focusedWindow
        else {
            publish(nil)
            return
        }

        let root = focusedWindow as! AXUIElement
        var buttons: [String] = []
        var textFields: [String] = []
        collect(element: root, depth: 0, buttons: &buttons, textFields: &textFields)
        let saveWords = ["save", "save as", "保存", "存储", "另存为", "export", "导出", "download", "下载"]
        let isSavePanel = buttons.contains { title in
            saveWords.contains { title.lowercased().contains($0) }
        }
        guard isSavePanel else {
            publish(nil)
            return
        }

        let filename = textFields.first { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count < 260 && !trimmed.contains("\n")
        }
        publish(SavePanelContext(
            applicationName: app.localizedName ?? "未知应用",
            proposedFilename: filename,
            detectedAt: Date()
        ))
    }

    private func publish(_ context: SavePanelContext?) {
        if context != lastContext {
            lastContext = context
            onChange(context)
        }
    }

    private func collect(
        element: AXUIElement,
        depth: Int,
        buttons: inout [String],
        textFields: inout [String]
    ) {
        guard depth <= 5 else { return }
        let role = attribute(element, kAXRoleAttribute) ?? ""
        if role == kAXButtonRole as String,
           let title = attribute(element, kAXTitleAttribute), !title.isEmpty {
            buttons.append(title)
        }
        if role == kAXTextFieldRole as String,
           let value = attribute(element, kAXValueAttribute), !value.isEmpty {
            textFields.append(value)
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return }
        for child in children.prefix(80) {
            collect(element: child, depth: depth + 1, buttons: &buttons, textFields: &textFields)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
