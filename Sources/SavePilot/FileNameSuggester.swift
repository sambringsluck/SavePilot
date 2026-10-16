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

        let evidence = "\(originalBase) \(content.summary) \(String(content.text.prefix(4_000)))".lowercased()
        if academic == nil {
            return nonAcademicSuggestion(source: source, evidence: evidence, preferredSeparator: preferredSeparator)
        }
        guard let academic else { return nil }
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

    private static func nonAcademicSuggestion(
        source: URL,
        evidence: String,
        preferredSeparator: String
    ) -> FileNameRecommendation? {
        let descriptors: [(name: String, signals: [String], minimum: Int)] = [
            ("发票", ["invoice", "invoice number", "amount due", "tax", "发票", "税额", "价税合计"], 2),
            ("收据", ["receipt", "paid", "total", "purchase", "收据", "已付", "小票"], 2),
            ("会议记录", ["meeting minutes", "attendees", "agenda", "action items", "会议纪要", "参会人", "待办"], 2),
            ("面试记录", ["interview", "candidate", "hiring", "resume", "面试", "候选人", "简历"], 2),
            ("合同", ["agreement", "contract", "parties", "signature", "terms", "合同", "协议", "签署"], 3),
            ("行程单", ["itinerary", "flight", "hotel", "booking", "行程", "航班", "酒店", "预订"], 3),
            ("医疗报告", ["diagnosis", "patient", "hospital", "prescription", "诊断", "患者", "医院", "处方"], 3)
        ]
        let ranked = descriptors.map { descriptor in
            (descriptor, descriptor.signals.filter { evidence.contains($0) }.count)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= best.0.minimum,
              best.1 > (ranked.dropFirst().first?.1 ?? 0)
        else { return nil }

        let separator = ["_", "-", " - ", " "].contains(preferredSeparator) ? preferredSeparator : "_"
        var parts = [best.0.name]
        if let date = normalizedDate(in: evidence) { parts.append(date) }
        let base = sanitize(parts.joined(separator: separator))
        let ext = source.pathExtension
        let fileName = ext.isEmpty ? base : "\(base).\(ext)"
        guard fileName.caseInsensitiveCompare(source.lastPathComponent) != .orderedSame else { return nil }
        return FileNameRecommendation(
            fileName: fileName,
            reason: "原文件名信息量较低，已根据正文中的文档类型和日期生成可检索名称",
            confidence: min(0.92, 0.70 + Double(best.1) * 0.055)
        )
    }

    private static func normalizedDate(in evidence: String) -> String? {
        let patterns = [
            #"\b(20\d{2})[\-\/.](\d{1,2})[\-\/.](\d{1,2})\b"#,
            #"(20\d{2})年(\d{1,2})月(\d{1,2})日"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: evidence,
                    range: NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
                  ), match.numberOfRanges == 4,
                  let yearRange = Range(match.range(at: 1), in: evidence),
                  let monthRange = Range(match.range(at: 2), in: evidence),
                  let dayRange = Range(match.range(at: 3), in: evidence),
                  let month = Int(evidence[monthRange]),
                  let day = Int(evidence[dayRange])
            else { continue }
            return String(format: "%@-%02d-%02d", String(evidence[yearRange]), month, day)
        }
        return nil
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
