import Foundation

enum FolderPathAutocomplete {
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let queryKey = normalized(expanded)
        let queryTokens = Set(queryKey.split(separator: " ").map(String.init))

        return candidates.compactMap { path -> (String, Int)? in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let pathKey = normalized(path)
            let leafKey = normalized(url.lastPathComponent)
            let componentKeys = url.pathComponents.map(normalized)
            let score: Int
            if path == expanded || leafKey == queryKey {
                score = 120
            } else if leafKey.hasPrefix(queryKey) {
                score = 108
            } else if leafKey.contains(queryKey) {
                score = 98
            } else if let componentIndex = componentKeys.lastIndex(of: queryKey) {
                let descendants = componentKeys.distance(from: componentIndex, to: componentKeys.endIndex) - 1
                score = 94 - min(18, descendants * 3)
            } else if pathKey.hasPrefix(queryKey) || pathKey.contains("/" + queryKey) {
                score = 82
            } else {
                let pathTokens = Set(pathKey.split(separator: " ").map(String.init))
                guard !queryTokens.isEmpty, queryTokens.isSubset(of: pathTokens) else { return nil }
                score = 70
            }
            return (path, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let lhsDepth = URL(fileURLWithPath: $0.0).pathComponents.count
            let rhsDepth = URL(fileURLWithPath: $1.0).pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
