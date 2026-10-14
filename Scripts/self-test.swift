import Foundation

enum SelfTestError: Error {
    case failed(String)
}

@main
struct SavePilotSelfTest {
    static func main() throws {
        try testExistingFolderSuggestion()
        try testNewFolderSuggestion()
        try testStableHistoryFolderSuggestion()
        try testPersonalMemoryAndNovelThemeThreshold()
        try testFolderThemeAudit()
        try testMoveCollisionAndUndo()
        try testUnknownFormatSuggestion()
        try testFilenameStopWordsDoNotRoute()
        try testSystemDataExclusions()
        print("SavePilot self-test: 9/9 passed")
    }

    private static func testExistingFolderSuggestion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let finance = root.appendingPathComponent("财务", isDirectory: true)
        try FileManager.default.createDirectory(at: finance, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("invoice-2026.pdf")
        let content = ExtractedContent(text: "Invoice total paid bank account", kind: "PDF", summary: "Invoice")
        let suggestion = SuggestionEngine().suggest(for: source, content: content, roots: [root])
        guard !suggestion.createsFolder,
              suggestion.finalDestinationFolder.standardizedFileURL == finance.standardizedFileURL
        else { throw SelfTestError.failed("existing folder suggestion") }
    }

    private static func testNewFolderSuggestion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("medical-record.txt")
        let content = ExtractedContent(text: "Hospital medical diagnosis and prescription", kind: "文本", summary: "Hospital")
        let firstSuggestion = SuggestionEngine().suggest(for: source, content: content, roots: [root])
        let clusteredSuggestion = SuggestionEngine().suggest(
            for: source,
            content: content,
            roots: [root],
            allowCreatingFolder: true
        )
        guard !firstSuggestion.createsFolder,
              clusteredSuggestion.createsFolder,
              clusteredSuggestion.proposedFolderName == "医疗"
        else { throw SelfTestError.failed("new folder threshold") }
    }

    private static func testStableHistoryFolderSuggestion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("全球通史.docx")
        let content = ExtractedContent(
            text: "古代文明、帝国、地理与经济共同塑造世界历史的发展。",
            kind: "Office 文档",
            summary: "世界文明通史"
        )
        let engine = SuggestionEngine()
        guard engine.stableNewFolderName(for: source, content: content) == "历史" else {
            throw SelfTestError.failed("stable history category")
        }
        let suggestion = engine.suggest(
            for: source,
            content: content,
            roots: [root],
            allowCreatingFolder: true
        )
        guard suggestion.createsFolder,
              suggestion.proposedFolderName == "历史",
              suggestion.finalDestinationFolder.lastPathComponent == "历史"
        else { throw SelfTestError.failed("history folder creation suggestion") }
    }

    private static func testPersonalMemoryAndNovelThemeThreshold() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Acme客户", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let suiteName = "SavePilotSelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failed("isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let memory = LearningStore(defaults: defaults)
        let content = ExtractedContent(
            text: "Acme quarterly client project proposal",
            kind: "PDF",
            summary: "Acme client proposal"
        )
        let source1 = root.appendingPathComponent("acme-proposal-q1.pdf")
        memory.record(source: source1, summary: content.summary, destination: destination)
        let source2 = root.appendingPathComponent("acme-proposal-q2.pdf")
        guard memory.recommendation(for: source2, content: content, roots: [root])?.destination.standardizedFileURL == destination.standardizedFileURL
        else { throw SelfTestError.failed("personal retrieval memory") }

        let first = memory.observeNovelTheme(source: root.appendingPathComponent("trip-1.pdf"), content: content, topic: "旅行")
        let second = memory.observeNovelTheme(source: root.appendingPathComponent("trip-2.pdf"), content: content, topic: "旅行")
        let third = memory.observeNovelTheme(source: root.appendingPathComponent("trip-3.pdf"), content: content, topic: "旅行")
        guard !first, !second, third else { throw SelfTestError.failed("novel theme threshold") }
    }

    private static func testFolderThemeAudit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let financeText = "invoice budget account payment tax finance quarterly revenue"
        let documents = (1...5).map { index in
            FolderAuditDocument(
                url: root.appendingPathComponent("finance-\(index).txt"),
                content: ExtractedContent(text: financeText + " period \(index)", kind: "文本", summary: "finance")
            )
        } + [
            FolderAuditDocument(
                url: root.appendingPathComponent("vacation-itinerary.txt"),
                content: ExtractedContent(text: "flight hotel visa beach museum travel booking", kind: "文本", summary: "travel")
            )
        ]
        let outliers = FolderAuditEngine.findOutliers(in: documents)
        guard outliers.contains(where: { $0.document.url.lastPathComponent == "vacation-itinerary.txt" })
        else { throw SelfTestError.failed("folder theme outlier") }
    }

    private static func testMoveCollisionAndUndo() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let source = inbox.appendingPathComponent("note.txt")
        let occupied = archive.appendingPathComponent("note.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: occupied)
        let record = try FileMover.move(source, to: archive)
        guard URL(fileURLWithPath: record.destinationPath).lastPathComponent == "note 2.txt",
              FileManager.default.fileExists(atPath: occupied.path)
        else { throw SelfTestError.failed("collision avoidance") }
        try FileMover.undo(record)
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: record.destinationPath)
        else { throw SelfTestError.failed("undo") }
    }

    private static func testUnknownFormatSuggestion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("opaque-sample.custombin")
        let content = ExtractedContent(
            text: "opaque sample metadata without a registered decoder",
            kind: "未知格式",
            summary: "使用文件名、文件特征和元数据兜底"
        )
        let start = Date()
        let suggestion = SuggestionEngine().suggest(for: source, content: content, roots: [root])
        guard !suggestion.finalDestinationFolder.path.isEmpty,
              Date().timeIntervalSince(start) < 30
        else { throw SelfTestError.failed("unknown format fallback") }
    }

    private static func testFilenameStopWordsDoNotRoute() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let misleading = root.appendingPathComponent(
            "Template_of_A_Model_Driven_Article_for_School_Students",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: misleading, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(
            "Physics_for_Scientists_and_Engineers_with_Modern_Physics_by_Tipler.pdf"
        )
        let content = ExtractedContent(
            text: "mass force energy field mechanics thermodynamics",
            kind: "PDF",
            summary: "physics textbook"
        )
        let suggestion = SuggestionEngine().suggest(for: source, content: content, roots: [root])
        guard suggestion.finalDestinationFolder.standardizedFileURL == root.standardizedFileURL
        else { throw SelfTestError.failed("filename stop-word false positive") }
    }

    private static func testSystemDataExclusions() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let libraryItem = home.appendingPathComponent("Library/Mail/example.emlx").path
        let normalDocument = home.appendingPathComponent("Documents/report.pdf").path
        let buildArtifact = home.appendingPathComponent("Documents/project/.build/output.o").path
        let browserJournal = home.appendingPathComponent("Documents/profile/Cookies-journal").path
        let browserCache = home.appendingPathComponent("Documents/tool-profile/Default/Cache/Cache_Data/index").path
        let browserProfilePreference = home.appendingPathComponent("Documents/tool-profile/Default/Preferences").path
        let codexWorkspace = home.appendingPathComponent("Documents/Codex/2026-10-14/task/work/output.dat").path
        let photosLibraryInternal = home.appendingPathComponent("Pictures/Photos Library.photoslibrary/resources/internal.plist").path
        guard FolderMonitor.shouldIgnore(path: libraryItem),
              FolderMonitor.shouldIgnore(path: buildArtifact),
              FolderMonitor.shouldIgnore(path: browserJournal),
              FolderMonitor.shouldIgnore(path: browserCache),
              FolderMonitor.shouldIgnore(path: browserProfilePreference),
              FolderMonitor.shouldIgnore(path: codexWorkspace),
              FolderMonitor.shouldIgnore(path: photosLibraryInternal),
              !FolderMonitor.shouldIgnore(path: normalDocument)
        else { throw SelfTestError.failed("system data exclusion") }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavePilotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
