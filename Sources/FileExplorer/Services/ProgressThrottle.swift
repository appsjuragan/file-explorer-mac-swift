import Foundation

/// Rate-limits progress callbacks from background work.
///
/// File operations report per item; every report becomes a main-actor hop and a SwiftUI
/// update, so a 10,000-file copy used to queue ~20,000 of them. This forwards the first
/// and last report of an operation and at most one in between per `interval`.
/// Safe to call from any thread.
final class ProgressThrottle: @unchecked Sendable {
    private let sink: (@Sendable (OpProgress) -> Void)?
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastForwarded: TimeInterval = -.infinity

    init(_ sink: (@Sendable (OpProgress) -> Void)?, interval: TimeInterval = 0.05) {
        self.sink = sink
        self.interval = interval
    }

    func report(_ progress: OpProgress) {
        guard let sink else { return }
        let now = ProcessInfo.processInfo.systemUptime   // monotonic, unaffected by clock changes
        let isEdge = progress.done <= 0 || progress.done >= progress.total
        lock.lock()
        let due = isEdge || now - lastForwarded >= interval
        if due { lastForwarded = now }
        lock.unlock()
        if due { sink(progress) }
    }
}
