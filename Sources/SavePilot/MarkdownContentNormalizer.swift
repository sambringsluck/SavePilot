import Foundation

enum MarkdownContentNormalizer {
    private static let exportedRecordTypes = [
        "think", "thinking", "tool_call", "tool_result", "tool", "reasoning",
        "computer_initialize_state", "computer_screenshot", "computer_output"
    ]

    static func normalize(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        lines = removingFrontMatter(from: lines)

        let visibleLines = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isExportedMachineRecord(trimmed) else { return nil }
            if trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") { return nil }
            return line
        }

        return visibleLines.joined(separator: "\n")
            .replacingOccurrences(
                of: "!?\\[([^\\]]+)\\]\\([^\\)]+\\)",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: "(?m)^\\s{0,3}(?:#{1,6}|>|[-+*]|\\d+\\.)\\s+",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[`*_~]{1,3}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingFrontMatter(from lines: [String]) -> [String] {
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return lines
        }
        let searchLimit = min(lines.count, 80)
        guard let closingIndex = (1..<searchLimit).first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else { return lines }
        return Array(lines.dropFirst(closingIndex + 1))
    }

    private static func isExportedMachineRecord(_ line: String) -> Bool {
        guard line.hasPrefix("{"), line.hasSuffix("}") else { return false }
        let compact = line.replacingOccurrences(of: " ", with: "")
        return exportedRecordTypes.contains { compact.contains("\"type\":\"\($0)\"") }
    }
}
