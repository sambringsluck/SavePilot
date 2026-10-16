import Foundation

struct FileNameRecommendation: Sendable {
    let fileName: String
    let reason: String
    let confidence: Double
}

enum FileNameSuggester {
    static func suggest(
        source: URL,
        content: ExtractedContent,
        academic: AcademicSubjectMatch?,
        preferredSeparator: String = "_"
    ) -> FileNameRecommendation? {
        let originalBase = source.deletingPathExtension().lastPathComponent
        guard isLowInformation(originalBase) else { return nil }
        guard let academic else { return nil }

        let evidence = "\(originalBase) \(content.summary) \(String(content.text.prefix(4_000)))".lowercased()
        var parts: [String] = []
        if academic.folderName == "物理", evidence.contains("ap physics c") {
            parts.append("AP物理C")
        } else {
            parts.append(academic.folderName)
        }
        if academic.folderName == "物理" {
            if evidence.contains("mechanics") || evidence.contains("mech-") || evidence.contains("力学") { parts.append("力学") }
            else if evidence.contains("electric") || evidence.contains("gauss") || evidence.contains("电磁") { parts.append("电磁学") }
        }
        if let homeworkNumber = homeworkNumber(in: evidence) {
            parts.append("作业\(homeworkNumber)")
        } else if evidence.contains("homework") || evidence.contains("作业") {
            parts.append("作业")
        } else if evidence.contains("textbook") || evidence.contains("chapter") || evidence.contains("教材") {
            parts.append("教材")
        } else {
            parts.append("学习资料")
        }

        let safeSeparator = ["_", "-", " - ", " "].contains(preferredSeparator) ? preferredSeparator : "_"
        let base = sanitize(parts.joined(separator: safeSeparator))
        guard !base.isEmpty else { return nil }
        let ext = source.pathExtension
        let fileName = ext.isEmpty ? base : "\(base).\(ext)"
        guard fileName.caseInsensitiveCompare(source.lastPathComponent) != .orderedSame else { return nil }
        return FileNameRecommendation(
            fileName: fileName,
            reason: "原文件名信息量较低，已根据正文中的学科、课程和作业编号生成可检索名称",
            confidence: min(0.96, academic.confidence + 0.04)
        )
    }

    private static func isLowInformation(_ base: String) -> Bool {
        let normalized = base.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.range(of: #"^(hw|homework|assignment)[ _-]*\d{0,3}$"#, options: .regularExpression) != nil { return true }
        if normalized.range(of: #"^(untitled|document|doc|scan|scanned|image|img|download|file)[ _-]*\d{0,6}$"#, options: .regularExpression) != nil { return true }
        if normalized.allSatisfy(\.isNumber) { return true }
        return normalized.count < 4 || normalized.count > 120
    }

    private static func homeworkNumber(in evidence: String) -> String? {
        let patterns = [#"\bhw[ _-]*(\d{1,3})\b"#, #"homework[ #_-]*(\d{1,3})\b"#, #"作业[ _-]*(\d{1,3})"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
            guard let match = regex.firstMatch(in: evidence, range: range), match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: evidence)
            else { continue }
            return String(evidence[numberRange])
        }
        return nil
    }

    private static func sanitize(_ value: String) -> String {
        String(value
            .replacingOccurrences(of: #"[/:\\\x00-\x1F]"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            .prefix(90))
    }
}
