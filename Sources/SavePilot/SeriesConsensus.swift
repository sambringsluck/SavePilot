import Foundation

/// Uses high-quality recommendations from a numbered batch as context for its
/// siblings. This is deliberately conservative: it needs at least three
/// grounded votes and a clear 70% project-level majority before changing any
/// result. A screenshot or exported-page sequence is then kept together even
/// when OCR quality varies from page to page.
enum SeriesConsensus {
    static func consolidate(_ suggestions: [FileSuggestion], roots: [URL]) -> [FileSuggestion] {
        var result = suggestions
        var groups: [String: [Int]] = [:]
        for index in result.indices {
            if let key = seriesKey(for: result[index].source) {
                groups[key, default: []].append(index)
            }
        }

        for indices in groups.values where indices.count >= 4 {
            let grounded = indices.compactMap { index -> URL? in
                let suggestion = result[index]
                guard suggestion.reason.contains("本地多证据 RAG")
                        || suggestion.reason.contains("个人记忆")
                else { return nil }
                return projectBucket(for: suggestion.finalDestinationFolder, roots: roots)
            }
            guard grounded.count >= 4 else { continue }
            let counts = Dictionary(grouping: grounded.map(\.standardizedFileURL.path), by: { $0 })
                .mapValues(\.count)
            guard let winner = counts.max(by: { $0.value < $1.value }),
                  winner.value >= 3,
                  Double(winner.value) / Double(grounded.count) >= 0.70
            else { continue }

            let destination = URL(fileURLWithPath: winner.key, isDirectory: true)
            for index in indices {
                let original = result[index]
                result[index] = FileSuggestion(
                    id: original.id,
                    source: original.source,
                    destinationFolder: destination,
                    proposedFolderName: "",
                    reason: "系列文件一致性：同批编号文件的多证据结果集中指向项目“\(destination.lastPathComponent)”；已合并逐页 OCR 波动。原判断：\(original.reason)",
                    summary: original.summary,
                    confidence: max(0.72, original.confidence),
                    createsFolder: false,
                    detectedAt: original.detectedAt,
                    proposedFileName: original.proposedFileName
                )
            }
        }
        return result
    }

    private static func seriesKey(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let patterns = [
            #"(?:[_\- ]+(?:page|slide|img|image|scan|screen|截图)?[_\- ]*\d{1,3})$"#,
            #"(?:\(\d{1,3}\))$"#
        ]
        var stem = name
        var matched = false
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
            if let match = regex.firstMatch(in: stem, range: range), match.range.location != NSNotFound,
               let swiftRange = Range(match.range, in: stem) {
                stem.removeSubrange(swiftRange)
                matched = true
                break
            }
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "_-")))
        guard matched, stem.count >= 3 else { return nil }
        return [
            url.deletingLastPathComponent().standardizedFileURL.path,
            url.pathExtension.lowercased(),
            stem
        ].joined(separator: "|")
    }

    private static func projectBucket(for destination: URL, roots: [URL]) -> URL? {
        let path = destination.standardizedFileURL.path
        let eligible = roots.compactMap { root -> (URL, Int)? in
            let root = root.standardizedFileURL
            let rootPath = root.path
            guard path.hasPrefix(rootPath + "/") else { return nil }
            return (root, rootPath.count)
        }.sorted { $0.1 > $1.1 }
        guard let root = eligible.first?.0 else { return nil }
        let relative = String(path.dropFirst(root.path.count + 1))
        guard let first = relative.split(separator: "/").first, !first.isEmpty else { return nil }
        return root.appendingPathComponent(String(first), isDirectory: true)
    }
}
