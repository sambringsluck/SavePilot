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
        try testMarkdownExportNormalization()
        try testEvidenceFusionAndAbstention()
        try testMemoryRejectsUnrelatedSameFormat()
        try testKeywordBoundaryMatching()
        try testAmbiguousTitleNeedsBodyEvidence()
        try testGenericTechnicalFolderNeedsProjectContext()
        try testMemoryKeepsSeparateTopicsAndHonorsRejection()
        try testNumberedSeriesConsensus()
        try testFileNameSuggestionAndRename()
        print("SavePilot self-test: 18/18 passed")
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
        let musicLibraryInternal = home.appendingPathComponent("Music/Music/Music Library.musiclibrary/Library.musicdb").path
        let tvLibraryInternal = home.appendingPathComponent("Movies/Videos/Videos Library.tvlibrary/Library.tvdb").path
        guard FolderMonitor.shouldIgnore(path: libraryItem),
              FolderMonitor.shouldIgnore(path: buildArtifact),
              FolderMonitor.shouldIgnore(path: browserJournal),
              FolderMonitor.shouldIgnore(path: browserCache),
              FolderMonitor.shouldIgnore(path: browserProfilePreference),
              FolderMonitor.shouldIgnore(path: codexWorkspace),
              FolderMonitor.shouldIgnore(path: photosLibraryInternal),
              FolderMonitor.shouldIgnore(path: musicLibraryInternal),
              FolderMonitor.shouldIgnore(path: tvLibraryInternal),
              !FolderMonitor.shouldIgnore(path: normalDocument)
        else { throw SelfTestError.failed("system data exclusion") }
    }

    private static func testMarkdownExportNormalization() throws {
        let hidden = String(repeating: "irrelevant hidden token ", count: 12_000)
        let markdown = """
        ---
        export: conversation
        ---
        # 金融数据问题讨论
        **User**
        请分析股票、债券与资产配置的风险收益关系。
        {"type":"think","think":"\(hidden)"}
        **Assistant**
        投资组合应关注分散化、波动率、回撤和长期收益。
        """
        let normalized = MarkdownContentNormalizer.normalize(markdown)
        guard normalized.contains("金融数据问题讨论"),
              normalized.contains("投资组合应关注分散化"),
              !normalized.contains("irrelevant hidden token"),
              !normalized.contains("export: conversation")
        else { throw SelfTestError.failed("markdown exported conversation normalization") }
    }

    private static func testEvidenceFusionAndAbstention() throws {
        let strong = FolderEvidenceCandidate(
            identifier: "finance", semantic: 0.23, hypergraph: 0.12,
            pathMatch: 0.09, extensionMatch: 1, coherence: 0.82, evidenceTermCount: 7
        )
        let weak = FolderEvidenceCandidate(
            identifier: "travel", semantic: 0.07, hypergraph: 0,
            pathMatch: 0, extensionMatch: 1, coherence: 0.9, evidenceTermCount: 2
        )
        guard EvidenceRanker.rank([strong, weak])?.identifier == "finance" else {
            throw SelfTestError.failed("multi-evidence ranking")
        }

        let tiedA = FolderEvidenceCandidate(
            identifier: "a", semantic: 0.15, hypergraph: 0.07,
            pathMatch: 0, extensionMatch: 1, coherence: 0.8, evidenceTermCount: 4
        )
        let tiedB = FolderEvidenceCandidate(
            identifier: "b", semantic: 0.148, hypergraph: 0.069,
            pathMatch: 0, extensionMatch: 1, coherence: 0.8, evidenceTermCount: 4
        )
        guard EvidenceRanker.rank([tiedA, tiedB]) == nil else {
            throw SelfTestError.failed("ambiguous evidence abstention")
        }
    }

    private static func testMemoryRejectsUnrelatedSameFormat() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("金融研究", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let suiteName = "SavePilotMemoryTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw SelfTestError.failed("memory defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let memory = LearningStore(defaults: defaults)
        memory.record(
            source: root.appendingPathComponent("portfolio-analysis.pdf"),
            summary: "股票 债券 投资组合 风险 收益",
            destination: destination
        )
        let unrelated = ExtractedContent(
            text: "hotel flight museum beach",
            kind: "PDF",
            summary: "旅行 酒店 航班 博物馆"
        )
        guard memory.recommendation(
            for: root.appendingPathComponent("vacation-plan.pdf"),
            content: unrelated,
            roots: [root]
        ) == nil else { throw SelfTestError.failed("same-format memory false positive") }
    }

    private static func testKeywordBoundaryMatching() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = ExtractedContent(
            text: "A borderline discussion about coordination and ordinary language.",
            kind: "文本",
            summary: "linguistics discussion"
        )
        let source = root.appendingPathComponent("borderline-coordination.txt")
        let propaganda = ExtractedContent(
            text: "People may reach agreement about claims, persuasion, media and public opinion.",
            kind: "Office 文档",
            summary: "propaganda and misinformation"
        )
        let physics = ExtractedContent(
            text: "force mass energy mechanics thermodynamics project report",
            kind: "PDF",
            summary: "physics textbook for scientists and engineers"
        )
        let engine = SuggestionEngine()
        guard engine.stableNewFolderName(for: source, content: content) != "收据" else {
            throw SelfTestError.failed("keyword substring false positive")
        }
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("Propaganda.docx"), content: propaganda
        ) != "合同与法律" else { throw SelfTestError.failed("weak legal signal") }
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("Physics_for_Scientists_and_Engineers.pdf"), content: physics
        ) != "工作" else { throw SelfTestError.failed("physics routed to work") }
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("hw3.pdf"), content: physics
        ) == "物理" else { throw SelfTestError.failed("homework subject hierarchy") }
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("1014 面试问题.docx"), content: content
        ) == "工作" else { throw SelfTestError.failed("interview title pattern") }

        let financeModel = ExtractedContent(
            text: "investment return risk correlation historical data optimal portfolio bank stock",
            kind: "Office 文档",
            summary: "portfolio optimization with historical data"
        )
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("建模2.docx"), content: financeModel
        ) != "历史" else { throw SelfTestError.failed("incidental historical data is not history") }

        let explicitPhysicsHomework = ExtractedContent(
            text: "AP Physics C Mechanics Homework. Questions on force, motion, energy and momentum.",
            kind: "PDF",
            summary: "AP Physics C mechanics homework"
        )
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("hw3.pdf"), content: explicitPhysicsHomework
        ) == "物理" else { throw SelfTestError.failed("physics homework content") }

        let ambiguousHomework = ExtractedContent(
            text: "Complete questions 1 through 10 before next class.",
            kind: "PDF",
            summary: "Homework assignment"
        )
        let physicsHeavyProfile = UserProfileSnapshot(
            academicAffinity: ["物理": 100], observedLooseFiles: 20,
            profiledFolders: 8, sampledFiles: 80, updatedAt: Date()
        )
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("hw4.pdf"),
            content: ambiguousHomework,
            profile: physicsHeavyProfile
        ) == "学习" else { throw SelfTestError.failed("profile must not hallucinate subject") }
    }

    private static func testAmbiguousTitleNeedsBodyEvidence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = ExtractedContent(
            text: "I affirm that this submission is my original academic work and follows the honor code.",
            kind: "PDF",
            summary: "academic integrity declaration"
        )
        let engine = SuggestionEngine()
        guard engine.stableNewFolderName(
            for: root.appendingPathComponent("integrity_statement.pdf"), content: content
        ) != "财务" else { throw SelfTestError.failed("ambiguous statement title") }
    }

    private static func testGenericTechnicalFolderNeedsProjectContext() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("unrelated-project", isDirectory: true)
        let images = project.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("family-photo-01.png")
        let content = ExtractedContent(text: "people outdoors", kind: "图片 / Vision", summary: "photo")
        let suggestion = SuggestionEngine().suggest(for: source, content: content, roots: [root])
        guard suggestion.finalDestinationFolder.standardizedFileURL != images.standardizedFileURL else {
            throw SelfTestError.failed("generic images folder hijack")
        }
    }

    private static func testMemoryKeepsSeparateTopicsAndHonorsRejection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("参考资料", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let suiteName = "SavePilotMemoryClusterTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw SelfTestError.failed("cluster defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let memory = LearningStore(defaults: defaults)
        memory.record(
            source: root.appendingPathComponent("portfolio-risk.pdf"),
            summary: "portfolio investment stocks bonds risk return",
            destination: destination
        )
        memory.record(
            source: root.appendingPathComponent("museum-itinerary.pdf"),
            summary: "travel flight hotel museum itinerary visa",
            destination: destination
        )
        memory.recordRejection(
            source: root.appendingPathComponent("portfolio-risk-update.pdf"),
            summary: "portfolio investment stocks bonds risk return",
            destination: destination
        )
        let finance = ExtractedContent(
            text: "portfolio investment stocks bonds risk return",
            kind: "PDF",
            summary: "portfolio investment risk return"
        )
        let travel = ExtractedContent(
            text: "travel flight hotel museum itinerary visa",
            kind: "PDF",
            summary: "travel flight hotel itinerary"
        )
        guard memory.recommendation(
            for: root.appendingPathComponent("portfolio-risk-new.pdf"), content: finance, roots: [root]
        ) == nil else { throw SelfTestError.failed("negative memory abstention") }
        guard memory.recommendation(
            for: root.appendingPathComponent("museum-trip-2.pdf"), content: travel, roots: [root]
        )?.destination.standardizedFileURL == destination.standardizedFileURL else {
            throw SelfTestError.failed("separate memory topics")
        }
    }

    private static func testNumberedSeriesConsensus() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("YEC", isDirectory: true)
        let platform = project.appendingPathComponent("平台文档", isDirectory: true)
        let website = project.appendingPathComponent("website", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        for folder in [platform, website, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destinations = [platform, website, platform, other, root.appendingPathComponent("images")]
        let suggestions = destinations.enumerated().map { index, destination in
            FileSuggestion(
                id: UUID(),
                source: root.appendingPathComponent("经济宣讲_\(index + 1).png"),
                destinationFolder: destination,
                proposedFolderName: "",
                reason: index < 4 ? "本地多证据 RAG：测试" : "普通回退",
                summary: "经济社团宣讲",
                confidence: 0.75,
                createsFolder: false,
                detectedAt: Date()
            )
        }
        let resolved = SeriesConsensus.consolidate(suggestions, roots: [root])
        guard resolved.allSatisfy({ $0.finalDestinationFolder.standardizedFileURL == project.standardizedFileURL }) else {
            throw SelfTestError.failed("numbered series consensus")
        }
    }

    private static func testFileNameSuggestionAndRename() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("hw3.pdf")
        try Data("physics homework".utf8).write(to: source)
        let content = ExtractedContent(
            text: "AP Physics C: Mechanics Homework #3 force motion energy momentum",
            kind: "PDF",
            summary: "AP Physics C mechanics homework 3"
        )
        guard let academic = AcademicSubjectClassifier.classify(source: source, content: content),
              academic.folderName == "物理",
              let naming = FileNameSuggester.suggest(source: source, content: content, academic: academic),
              naming.fileName == "AP物理C_力学_作业3.pdf"
        else { throw SelfTestError.failed("content-aware filename suggestion") }
        let record = try FileMover.move(source, to: root, preferredFileName: naming.fileName)
        guard URL(fileURLWithPath: record.destinationPath).lastPathComponent == naming.fileName else {
            throw SelfTestError.failed("confirmed rename")
        }
        try FileMover.undo(record)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SelfTestError.failed("rename undo")
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavePilotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
