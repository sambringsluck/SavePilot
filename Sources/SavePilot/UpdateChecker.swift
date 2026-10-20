import Foundation

struct AppUpdateInfo: Identifiable, Equatable {
    let version: String
    let title: String
    let notes: String
    let downloadURL: URL
    let releaseURL: URL

    var id: String { version }
}

enum UpdateChecker {
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/sambringsluck/SavePilot/releases?per_page=12"
    )!
    private static let releasesAtomURL = URL(
        string: "https://github.com/sambringsluck/SavePilot/releases.atom"
    )!

    static var currentReleaseTag: String {
        if let tag = Bundle.main.object(forInfoDictionaryKey: "SavePilotReleaseTag") as? String,
           !tag.isEmpty {
            return tag
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
        return "v\(version)"
    }

    static func latest() async throws -> AppUpdateInfo? {
        // The public GitHub REST API has a low shared, unauthenticated rate
        // limit. The Releases Atom feed is public, contains only published
        // releases and is not tied to that API quota, so use it first.
        do {
            var request = URLRequest(url: releasesAtomURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue("SavePilot/\(currentReleaseTag)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            if let update = latestFromAtomDocument(
                String(decoding: data, as: UTF8.self),
                currentTag: currentReleaseTag
            ) {
                return update
            }
            return nil
        } catch {
            return try await latestFromAPI()
        }
    }

    private static func latestFromAPI() async throws -> AppUpdateInfo? {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 8
        request.setValue("SavePilot/\(currentReleaseTag)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let release = releases.first(where: {
            !$0.draft && isNewer(candidate: $0.tagName, than: currentReleaseTag)
        }) else { return nil }

        let preferredAsset = release.assets.first(where: { $0.name == "SavePilot-macOS.zip" })
            ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
        return AppUpdateInfo(
            version: release.tagName.removingPrefix("v"),
            title: release.name ?? release.tagName,
            notes: release.body ?? "包含最新的功能改进和问题修复。",
            downloadURL: preferredAsset?.browserDownloadURL ?? release.htmlURL,
            releaseURL: release.htmlURL
        )
    }

    static func latestFromAtomDocument(_ atom: String, currentTag: String) -> AppUpdateInfo? {
        guard let regex = try? NSRegularExpression(
            pattern: #"releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+(?:-preview\.[0-9]+)?)"#
        ) else { return nil }
        let range = NSRange(atom.startIndex..<atom.endIndex, in: atom)
        let tags = regex.matches(in: atom, range: range).compactMap { match -> String? in
            guard let capture = Range(match.range(at: 1), in: atom) else { return nil }
            return String(atom[capture])
        }
        let candidate = Array(Set(tags)).compactMap { tag -> (String, ReleaseVersion)? in
            guard isNewer(candidate: tag, than: currentTag), let version = ReleaseVersion(tag) else { return nil }
            return (tag, version)
        }.max { $0.1 < $1.1 }?.0
        guard let candidate,
              let releaseURL = URL(string: "https://github.com/sambringsluck/SavePilot/releases/tag/\(candidate)"),
              let downloadURL = URL(string: "https://github.com/sambringsluck/SavePilot/releases/download/\(candidate)/SavePilot-macOS.zip")
        else { return nil }
        return AppUpdateInfo(
            version: candidate.removingPrefix("v"),
            title: "SavePilot \(candidate)",
            notes: "包含最新的功能改进和问题修复。",
            downloadURL: downloadURL,
            releaseURL: releaseURL
        )
    }

    static func isNewer(candidate: String, than current: String) -> Bool {
        guard candidate != current else { return false }
        guard let candidateVersion = ReleaseVersion(candidate),
              let currentVersion = ReleaseVersion(current) else { return false }
        if currentVersion.core == (1, 2, 0), currentVersion.preview == nil,
           candidateVersion.core == currentVersion.core, candidateVersion.preview != nil {
            return true // Compatibility with preview builds that previously reported 1.2.0.
        }
        return candidateVersion > currentVersion
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, assets
        case htmlURL = "html_url"
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let preview: Int?

    var core: (Int, Int, Int) { (major, minor, patch) }

    init?(_ tag: String) {
        let value = tag.removingPrefix("v")
        let pieces = value.split(separator: "-", maxSplits: 1).map(String.init)
        let coreParts = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard coreParts.count == 3 else { return nil }
        major = coreParts[0]
        minor = coreParts[1]
        patch = coreParts[2]
        if pieces.count == 2, pieces[1].hasPrefix("preview."),
           let number = Int(pieces[1].dropFirst("preview.".count)) {
            preview = number
        } else {
            preview = nil
        }
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.preview, rhs.preview) {
        case let (.some(left), .some(right)): return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return false
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
