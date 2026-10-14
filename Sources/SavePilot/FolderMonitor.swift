import CoreServices
import Foundation

final class FolderMonitor {
    private let queue = DispatchQueue(label: "SavePilot.FSEvents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var stabilityTimer: DispatchSourceTimer?
    private var pendingFiles: [String: PendingStamp] = [:]
    private let onStableFile: (URL) -> Void

    struct FileStamp: Equatable {
        let size: Int64
        let modifiedAt: Date
    }

    struct PendingStamp {
        var stamp: FileStamp?
        var unchangedChecks: Int
        var firstSeen: Date
    }

    init(onStableFile: @escaping (URL) -> Void) {
        self.onStableFile = onStableFile
    }

    deinit { stop() }

    func start(folders: [URL]) {
        stop()
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let monitor = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            for index in 0..<min(count, paths.count) {
                let flag = eventFlags[index]
                let relevant = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
                    || (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
                    || (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0
                let isDirectory = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0
                if relevant && !isDirectory { monitor.enqueue(path: paths[index]) }
            }
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            folders.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.25, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkStability() }
        timer.resume()
        stabilityTimer = timer
    }

    func stop() {
        stabilityTimer?.cancel()
        stabilityTimer = nil
        pendingFiles.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func enqueue(path: String) {
        guard !Self.shouldIgnore(path: path) else { return }
        if pendingFiles[path] == nil {
            pendingFiles[path] = PendingStamp(stamp: nil, unchangedChecks: 0, firstSeen: Date())
        }
    }

    static func shouldIgnore(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let components = url.pathComponents
        let lowercasedComponents = Set(components.map { $0.lowercased() })
        let cacheDirectoryNames: Set<String> = [
            "cache", "caches", "cache_data", "code cache", "gpucache",
            "service worker", "shadercache", "dawncache", "blob_storage"
        ]
        let personalLibraryPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path + "/"
        let codexWorkspacePrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Codex", isDirectory: true).path + "/"
        return name.hasPrefix(".")
            || name.hasPrefix("~$")
            || name.hasSuffix(".download")
            || name.hasSuffix(".crdownload")
            || name.hasSuffix(".part")
            || name.hasSuffix(".tmp")
            || name.hasSuffix("-journal")
            || name.hasSuffix("-wal")
            || name.hasSuffix("-shm")
            || name.hasSuffix(".lock")
            || path.contains("/.Trash/")
            || path.hasPrefix(personalLibraryPrefix)
            || path.hasPrefix(codexWorkspacePrefix)
            || path.lowercased().contains("-profile/default/")
            || path.contains("/Library/Caches/")
            || path.contains("/Library/Containers/")
            || path.contains("/Library/Application Support/SavePilot/")
            || path.contains("/.build/")
            || path.contains("/.git/")
            || path.contains("/node_modules/")
            || path.contains("/DerivedData/")
            || path.contains(".app/Contents/")
            || path.lowercased().contains(".photoslibrary/")
            || path.lowercased().contains(".photolibrary/")
            || !lowercasedComponents.isDisjoint(with: cacheDirectoryNames)
            || components.dropFirst().contains(where: { $0.hasPrefix(".") })
    }

    private func checkStability() {
        for (path, var pending) in pendingFiles {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else {
                if Date().timeIntervalSince(pending.firstSeen) > 30 { pendingFiles[path] = nil }
                continue
            }
            let stamp = FileStamp(
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
            if pending.stamp == stamp {
                pending.unchangedChecks += 1
            } else {
                pending.stamp = stamp
                pending.unchangedChecks = 0
            }
            if pending.unchangedChecks >= 2 {
                pendingFiles[path] = nil
                onStableFile(url)
            } else {
                pendingFiles[path] = pending
            }
        }
    }
}
