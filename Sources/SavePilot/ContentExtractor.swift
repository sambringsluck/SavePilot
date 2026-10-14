import Foundation
import UniformTypeIdentifiers

enum ContentExtractor {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "xml",
        "html", "htm", "css", "scss", "js", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs",
        "java", "kt", "c", "h", "m", "mm", "cpp", "hpp", "cs", "php", "sh", "zsh", "fish",
        "sql", "log", "ini", "conf", "env", "tex", "rtf"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp", "avif"
    ]
    private static let officeExtensions: Set<String> = ["docx", "pptx", "xlsx", "pages"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "rar", "7z"]
    private static let mediaExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aiff", "mp4", "mov", "m4v", "mkv", "avi", "webm"
    ]

    static func extract(from url: URL) async -> ExtractedContent {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        var textParts: [String] = []
        var signals: [String] = []
        var metadata = baseMetadata(url: url, type: type)
        var kind = type?.localizedDescription ?? (ext.isEmpty ? "未知格式" : ext.uppercased())

        if textExtensions.contains(ext), let rawText = readText(url) {
            if ["md", "markdown"].contains(ext) {
                textParts.append(MarkdownContentNormalizer.normalize(rawText))
                signals.append("Markdown正文")
                kind = "Markdown 文档"
            } else {
                textParts.append(rawText)
                signals.append("可读文本")
            }
        } else if ext == "pdf", let result = await AdvancedExtractors.extractPDF(at: url) {
            textParts.append(result.text)
            signals.append(contentsOf: result.signals)
            kind = "PDF / OCR"
        } else if officeExtensions.contains(ext), let text = AdvancedExtractors.extractOfficeText(at: url) {
            textParts.append(text)
            signals.append("Office XML内容")
            kind = "Office 文档"
        } else if imageExtensions.contains(ext), let result = await AdvancedExtractors.analyzeImage(at: url) {
            if !result.text.isEmpty { textParts.append(result.text) }
            if !result.labels.isEmpty { textParts.append("视觉标签: " + result.labels.joined(separator: ", ")) }
            if !result.barcodes.isEmpty { textParts.append("条码内容: " + result.barcodes.joined(separator: ", ")) }
            signals.append(contentsOf: ["Vision OCR", "图像分类"])
            if result.faceCount > 0 { signals.append("检测到人脸:\(result.faceCount)") }
            if !result.barcodes.isEmpty { signals.append("条码/二维码:\(result.barcodes.count)") }
            metadata.merge(result.metadata) { current, _ in current }
            kind = "图片 / Vision"
        } else if archiveExtensions.contains(ext), let listing = AdvancedExtractors.archiveListing(at: url) {
            textParts.append("压缩包内文件:\n" + listing)
            signals.append("归档目录清单")
            kind = "压缩归档"
        } else if mediaExtensions.contains(ext), let media = await AdvancedExtractors.mediaMetadata(at: url) {
            textParts.append(media.text)
            metadata.merge(media.metadata) { current, _ in current }
            signals.append("音视频元数据")
            kind = "音视频"
        }

        if let spotlight = spotlightText(url), !spotlight.isEmpty {
            textParts.append(spotlight)
            signals.append("Spotlight索引")
        }

        if textParts.joined().count < 80,
           let preview = await AdvancedExtractors.analyzeQuickLookPreview(at: url) {
            if !preview.text.isEmpty { textParts.append("Quick Look OCR: " + preview.text) }
            if !preview.labels.isEmpty { textParts.append("Quick Look视觉标签: " + preview.labels.joined(separator: ", ")) }
            signals.append("Quick Look预览分析")
        }

        if let fileDescription = fileTypeDescription(url) {
            metadata["文件特征"] = fileDescription
        }

        let fallback = [url.deletingPathExtension().lastPathComponent, ext, metadata["文件特征"]]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let rawText = (textParts.isEmpty ? fallback : textParts.joined(separator: "\n"))
        return finalize(text: rawText, kind: kind, signals: Array(Set(signals)).sorted(), metadata: metadata)
    }

    private static func finalize(
        text: String,
        kind: String,
        signals: [String],
        metadata: [String: String]
    ) -> ExtractedContent {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(cleaned.prefix(20_000))
        let insights = AdvancedExtractors.linguisticInsights(for: bounded)
        var enrichedMetadata = metadata
        if let language = insights.language { enrichedMetadata["语言"] = language }
        let summaryBase = bounded.isEmpty ? "未提取到可读内容，已使用格式和元数据判断" : String(bounded.prefix(260))
        let signalSummary = signals.isEmpty ? "" : "\n技术信号：" + signals.joined(separator: "、")
        return ExtractedContent(
            text: bounded,
            kind: kind,
            summary: summaryBase + signalSummary,
            signals: signals,
            entities: insights.entities,
            metadata: enrichedMetadata
        )
    }

    private static func readText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 512_000)) ?? Data()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func spotlightText(_ url: URL) -> String? {
        run("/usr/bin/mdls", arguments: ["-raw", "-name", "kMDItemTextContent", url.path])
            .flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == "(null)" ? nil : trimmed
            }
    }

    private static func fileTypeDescription(_ url: URL) -> String? {
        run("/usr/bin/file", arguments: ["-b", url.path])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func baseMetadata(url: URL, type: UTType?) -> [String: String] {
        var result: [String: String] = [:]
        if let type { result["UTType"] = type.identifier }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]) {
            if let size = values.fileSize { result["大小"] = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
            if let date = values.creationDate { result["创建"] = date.formatted() }
            if let date = values.contentModificationDate { result["修改"] = date.formatted() }
        }
        return result
    }

    private static func run(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
