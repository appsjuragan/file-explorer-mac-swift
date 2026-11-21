import Foundation
import CoreServices

/// Watches one folder for changes to its direct children (creations, deletions, renames,
/// writes) using FSEvents, and calls `onChange` once per burst of changes.
///
/// FSEvents streams are recursive, so the events are filtered down to the watched folder's
/// own entries. Unfiltered, watching the home folder reloaded the list several times a
/// second from background writes deep inside ~/Library.
final class DirectoryWatcher: @unchecked Sendable {
    /// FSEvents coalescing window.
    private static let latency: CFTimeInterval = 0.1
    /// Quiet time before reporting a burst.
    private static let debounce: TimeInterval = 0.25
    /// Upper bound on delay while changes keep coming (e.g. a download being written).
    private static let maxDelay: TimeInterval = 1.0

    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
    private static let rootChangedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)

    private let queue = DispatchQueue(label: "com.fileexplorer.directorywatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()

    // Confined to `queue`.
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    /// Normalized spellings of the watched folder that FSEvents may report.
    private var watchedForms: [String] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var burstStartedAt: TimeInterval?

    var onChange: (@Sendable () -> Void)?

    init(onChange: (@Sendable () -> Void)? = nil) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // Must finish before the memory goes away: the stream's callback holds an unretained
        // pointer to self. (A `[weak self]` hop here would see nil and leak a live stream.)
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopStream()
        } else {
            queue.sync { stopStream() }
        }
    }

    /// Starts or updates the watched directory path.
    func watch(path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.watchedPath == path && self.stream != nil { return }
            self.stopStream()
            self.watchedPath = path

            guard !path.isEmpty, path != PathUtils.home, FileManager.default.fileExists(atPath: path) else {
                return
            }
            self.watchedForms = Self.comparableForms(of: path)

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let clientInfo else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                // kFSEventStreamCreateFlagUseCFTypes: eventPaths is a CFArray of CFString.
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
                watcher.handleEvents(paths: paths, flags: flags)
            }

            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.latency,
                flags
            ) else { return }

            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
        }
    }

    /// Stops watching the current directory.
    func stop() {
        queue.async { [weak self] in
            self?.stopStream()
            self?.watchedPath = nil
        }
    }

    // MARK: - Queue-confined

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        burstStartedAt = nil
        watchedForms = []
    }

    private func handleEvents(paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        guard zip(paths, flags).contains(where: { isRelevant($0, flags: $1) }) else { return }

        // Trailing debounce, but never postponed beyond `maxDelay` from the first event.
        let now = ProcessInfo.processInfo.systemUptime
        let start = burstStartedAt ?? now
        burstStartedAt = start
        let delay = max(0, min(Self.debounce, start + Self.maxDelay - now))

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.burstStartedAt = nil
            self?.onChange?()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// True for the watched folder itself or one of its direct children, and for events
    /// that tell us FSEvents lost track of what changed at or above the watched folder.
    private func isRelevant(_ rawPath: String, flags: FSEventStreamEventFlags) -> Bool {
        if flags & Self.rootChangedFlag != 0 { return true }
        let path = Self.normalize(rawPath)
        if flags & Self.rescanFlags != 0 {
            return watchedForms.contains { PathUtils.isInside($0, root: path) }
        }
        let parent = PathUtils.parent(path)
        return watchedForms.contains { path == $0 || parent == $0 }
    }

    /// FSEvents reports resolved paths ("/private/tmp", "/System/Volumes/Data/…"), and the
    /// volume is usually case-insensitive, so compare normalized spellings.
    private static func comparableForms(of path: String) -> [String] {
        var forms = [path]
        if let resolved = realpath(path, nil) {
            forms.append(String(cString: resolved))
            free(resolved)
        }
        forms += forms.map { "/System/Volumes/Data" + $0 }
        return Array(Set(forms.map(normalize)))
    }

    private static func normalize(_ path: String) -> String {
        var path = path.precomposedStringWithCanonicalMapping.lowercased()
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
