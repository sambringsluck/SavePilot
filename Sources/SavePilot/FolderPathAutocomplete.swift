import Foundation

enum FolderPathAutocomplete {
    struct Index: Sendable {
        private struct Entry: Sendable {
            let path: String
            let pathKey: String
            let leafKey: String
            let componentKeys: [String]
            let tokens: Set<String>
            let depth: Int
        }

        private let entries: [Entry]

        init(paths: [String]) {
            entries = paths.map { path in
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let pathKey = normalized(path)
                return Entry(
                    path: path,
                    pathKey: pathKey,
                    leafKey: normalized(url.lastPathComponent),
                    componentKeys: url.pathComponents.map(normalized),
                    tokens: Set(pathKey.split(separator: " ").map(String.init)),
                    depth: url.pathComponents.count
                )
            }
        }

        func matches(query: String, limit: Int = 8) -> [String] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return [] }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let queryKey = normalized(expanded)
            let queryTokens = Set(queryKey.split(separator: " ").map(String.init))
            return entries.compactMap { entry -> (Entry, Int)? in
                let score: Int
                if entry.path == expanded || entry.leafKey == queryKey {
                    score = 120
                } else if entry.leafKey.hasPrefix(queryKey) {
                    score = 108
                } else if entry.leafKey.contains(queryKey) {
                    score = 98
                } else if let componentIndex = entry.componentKeys.lastIndex(of: queryKey) {
                    let descendants = entry.componentKeys.distance(
                        from: componentIndex, to: entry.componentKeys.endIndex
                    ) - 1
                    score = 94 - min(18, descendants * 3)
                } else if entry.pathKey.hasPrefix(queryKey) || entry.pathKey.contains("/" + queryKey) {
                    score = 82
                } else {
                    guard !queryTokens.isEmpty, queryTokens.isSubset(of: entry.tokens) else { return nil }
                    score = 70
                }
                return (entry, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.depth != $1.0.depth { return $0.0.depth < $1.0.depth }
                return $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0.path)
        }
    }

    static func discover(
        roots: [URL],
        knownPaths: [String] = [],
        maximumDirectories: Int = 12_000,
        maximumDepth: Int = 7
    ) -> [String] {
        var paths = Set(knownPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        })
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let excludedNames: Set<String> = [
            ".git", ".build", "node_modules", "Library", "Applications",
            "Pods", "DerivedData", "Caches", "Cache"
        ]

        for root in roots.map(\.standardizedFileURL) {
            guard paths.count < maximumDirectories,
                  manager.fileExists(atPath: root.path)
            else { continue }
            paths.insert(root.path)
            // Walk a bounded queue explicitly so path completion stays cheap.
            let rootStartCount = paths.count
            var queue: [(URL, Int)] = [(root, 0)]
            var cursor = 0
            while cursor < queue.count,
                  paths.count < maximumDirectories,
                  paths.count - rootStartCount < 2_500 {
                let (folder, depth) = queue[cursor]
                cursor += 1
                guard depth < maximumDepth,
                      let children = try? manager.contentsOfDirectory(
                          at: folder,
                          includingPropertiesForKeys: keys,
                          options: [.skipsHiddenFiles]
                      )
                else { continue }
                for child in children {
                    guard paths.count < maximumDirectories,
                          !excludedNames.contains(child.lastPathComponent),
                          let values = try? child.resourceValues(forKeys: Set(keys)),
                          values.isDirectory == true,
                          values.isSymbolicLink != true,
                          values.isPackage != true
                    else { continue }
                    let path = child.standardizedFileURL.path
                    if paths.insert(path).inserted { queue.append((child, depth + 1)) }
                }
            }
        }
        return paths.sorted()
    }

    static func matches(query: String, candidates: [String], limit: Int = 8) -> [String] {
        Index(paths: candidates).matches(query: query, limit: limit)
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
