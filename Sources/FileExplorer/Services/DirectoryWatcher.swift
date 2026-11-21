import Foundation
import CoreServices

/// Monitors a directory for live file-system changes (creations, deletions, renames, writes)
/// using Apple's FSEvents framework, debouncing rapid changes.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var debounceWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.fileexplorer.directorywatcher", qos: .utility)

    var onChange: (@Sendable () -> Void)?

    init(onChange: (@Sendable () -> Void)? = nil) {
        self.onChange = onChange
    }

    deinit {
        stop()
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

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { (streamRef, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let clientInfo else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                watcher.handleEvent()
            }

            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
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

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func handleEvent() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
