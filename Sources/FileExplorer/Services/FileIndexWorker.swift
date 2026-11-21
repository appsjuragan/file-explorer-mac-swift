import Foundation

// MARK: - Folder Stats

struct FolderStats: Sendable, Equatable {
    var totalSize: Int64
    var objectCount: Int
    var lastModified: TimeInterval
    /// False when the scan hit its depth or time limit, so the numbers are a lower bound.
    var isComplete: Bool

    static let empty = FolderStats(totalSize: 0, objectCount: 0, lastModified: 0, isComplete: true)

    mutating func add(_ other: FolderStats) {
        totalSize += other.totalSize
        objectCount += other.objectCount
        lastModified = max(lastModified, other.lastModified)
        isComplete = isComplete && other.isComplete
    }
}

// MARK: - Indexing Worker

/// In-memory index of file entries the app has already seen, plus recursive folder stats
/// for tooltips and an index-backed search.
///
/// Cost model (the reason for most of the structure below):
/// - Nothing is crawled just because a folder was opened. Recursive work only happens for
///   folder stats that something asked for, and for search.
/// - Crawls run one at a time on a private serial queue, newest request first, each with a
///   depth and time budget. Blocking disk I/O never runs on Swift's cooperative thread pool,
///   where it would starve the app's user-initiated async work.
/// - The lock is held only to read or update dictionaries, never across disk I/O or string
///   matching, so the main thread never waits behind a crawl or a search.
/// - Memory is capped: past `maxEntries` the index starts over instead of growing forever.
final class FileIndexWorker: @unchecked Sendable {
    static let shared = FileIndexWorker()

    private enum Limits {
        /// Roughly 30 MB of entries; enough for search to stay index-backed in typical trees.
        static let maxEntries = 100_000
        static let maxCachedStats = 20_000
        /// Pending stats requests kept; older ones are dropped (the user scrolled past them).
        static let maxStatsBacklog = 24
        static let statsDepth = 6
        static let statsTimeLimit: TimeInterval = 3
        static let searchDepth = 6
        static let searchTimeLimit: TimeInterval = 6
        /// How long a fully indexed subtree is trusted for search without rescanning disk.
        static let subtreeTrustWindow: TimeInterval = 60
    }

    private let fs: FileSystemService
    private let crawlQueue = DispatchQueue(label: "fe.file-index-worker.crawl", qos: .utility)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var entriesByPath: [String: FileItem] = [:]
    private var childrenByDirectory: [String: [String]] = [:]
    /// Folder → uptime when its whole subtree was last ingested.
    private var completeSubtrees: [String: TimeInterval] = [:]
    private var statsByPath: [String: FolderStats] = [:]
    private var statsBacklog: [String] = []          // newest last
    private var isCrawling = false
    /// Bumped when the index is reset, so a crawl that started earlier can't vouch for it.
    private var generation = 0

    init(fs: FileSystemService = FileSystemService()) {
        self.fs = fs
    }

    // MARK: - Ingesting loaded items

    /// Records a directory listing the app already read. Cheap: no disk access.
    func indexLoadedItems(_ items: [FileItem], in parent: String) {
        synchronized { ingestLocked(items, in: parent) }
    }

    // MARK: - Folder Stats

    /// Cached recursive stats, or nil while they are being computed. Never touches the disk
    /// on the caller's thread; a miss queues a background crawl.
    func folderStats(for path: String) -> FolderStats? {
        if let cached = synchronized({ statsByPath[path] }) { return cached }
        requestStats(for: path)
        return nil
    }

    /// Queues a background crawl so the stats are ready by the time a tooltip asks.
    func prefetchStats(for path: String) {
        guard synchronized({ statsByPath[path] }) == nil else { return }
        requestStats(for: path)
    }

    private func requestStats(for path: String) {
        let startDrain: Bool = synchronized {
            if let i = statsBacklog.firstIndex(of: path) { statsBacklog.remove(at: i) }
            statsBacklog.append(path)                                  // most recent request runs first
            if statsBacklog.count > Limits.maxStatsBacklog { statsBacklog.removeFirst() }
            guard !isCrawling else { return false }
            isCrawling = true
            return true
        }
        if startDrain { crawlQueue.async { [weak self] in self?.drainStatsBacklog() } }
    }

    private func drainStatsBacklog() {
        while let path = synchronized({ () -> String? in
            guard let next = statsBacklog.popLast() else { isCrawling = false; return nil }
            return next
        }) {
            guard synchronized({ statsByPath[path] }) == nil else { continue }
            let generationAtStart = synchronized { generation }
            _ = crawl(path, depth: 0, deadline: Date().addingTimeInterval(Limits.statsTimeLimit),
                      generation: generationAtStart)
        }
    }

    /// Post-order crawl: stats for `path`, recording stats for every subfolder on the way
    /// (hovering a parent makes its children's tooltips instant). nil when unreadable.
    private func crawl(_ path: String, depth: Int, deadline: Date, generation: Int) -> FolderStats? {
        guard let children = try? fs.readDirectory(path) else { return nil }
        synchronized { ingestLocked(children, in: path) }

        var stats = FolderStats.empty
        stats.objectCount = children.count
        for child in children {
            stats.lastModified = max(stats.lastModified, child.modified)
            guard child.isDirectory else { stats.totalSize += child.size; continue }
            guard child.opensAsFolder, !child.isSymbolicLink else { continue }   // app bundles, links: not entered
            if let known = synchronized({ statsByPath[child.path] }), known.isComplete {
                stats.add(known)
            } else if depth < Limits.statsDepth, Date() < deadline,
                      let sub = crawl(child.path, depth: depth + 1, deadline: deadline, generation: generation) {
                stats.add(sub)
            } else {
                stats.isComplete = false
            }
        }

        synchronized {
            storeStatsLocked(stats, for: path)
            if stats.isComplete && self.generation == generation {
                completeSubtrees[path] = ProcessInfo.processInfo.systemUptime
            }
        }
        return stats
    }

    // MARK: - Search

    /// Matches names (and `ext:`, `.ext`, `size:>…` / `size:<…` filters) below `root`.
    /// Answers from the index when the subtree was fully indexed recently, otherwise scans the
    /// disk (bounded by depth, time and result count) and indexes what it reads.
    func search(root: String, query: String, maxResults: Int = 500) async -> [FileItem] {
        let parsed = SearchQuery(query)
        guard !parsed.isEmpty, maxResults > 0 else { return [] }

        if let snapshot = indexedSubtree(of: root) {
            return Array(snapshot.lazy.filter { parsed.matches($0) }.prefix(maxResults))
        }

        // The worker is a process-wide singleton, so capturing it strongly is fine.
        return await Task.detached(priority: .userInitiated) { () -> [FileItem] in
            var results: [FileItem] = []
            let generationAtStart = self.synchronized { self.generation }
            let complete = self.fs.walk(root, maxDepth: Limits.searchDepth,
                                        deadline: Date().addingTimeInterval(Limits.searchTimeLimit)) { dir, children in
                self.synchronized { self.ingestLocked(children, in: dir) }
                for item in children where parsed.matches(item) {
                    results.append(item)
                    if results.count >= maxResults { return false }
                }
                return true
            }
            if complete {
                self.synchronized {
                    if self.generation == generationAtStart {
                        self.completeSubtrees[root] = ProcessInfo.processInfo.systemUptime
                    }
                }
            }
            return results
        }.value
    }

    /// Everything under `root` when the index is known to hold the whole subtree; else nil.
    private func indexedSubtree(of root: String) -> [FileItem]? {
        synchronized {
            guard let indexedAt = completeSubtrees[root],
                  ProcessInfo.processInfo.systemUptime - indexedAt < Limits.subtreeTrustWindow else { return nil }
            // Cheap prefix filter under the lock; the costly name matching happens after.
            return entriesByPath.values.filter { $0.path != root && PathUtils.isInside($0.path, root: root) }
        }
    }

    // MARK: - Invalidation

    func removeEntry(at path: String) {
        synchronized {
            removeSubtreeLocked(path)
            let parent = PathUtils.parent(path)
            childrenByDirectory[parent]?.removeAll { $0 == path }
            invalidateLocked(parent)
        }
    }

    func invalidateFolderStats(for path: String) {
        synchronized { invalidateLocked(path) }
    }

    // MARK: - Locked helpers (call only inside `synchronized`)

    private func ingestLocked(_ items: [FileItem], in parent: String) {
        if entriesByPath.count + items.count > Limits.maxEntries { resetIndexLocked() }

        let newPaths = items.map(\.path)
        if let oldPaths = childrenByDirectory[parent] {
            let fresh = Set(newPaths)
            var changed = oldPaths.count != newPaths.count
            for old in oldPaths where !fresh.contains(old) {
                removeSubtreeLocked(old)                       // deleted or renamed since last seen
                changed = true
            }
            if !changed { changed = items.contains { entriesByPath[$0.path] != $0 } }
            if changed { invalidateLocked(parent) }
        }
        for item in items { entriesByPath[item.path] = item }
        childrenByDirectory[parent] = newPaths
    }

    private func removeSubtreeLocked(_ path: String) {
        entriesByPath.removeValue(forKey: path)
        statsByPath.removeValue(forKey: path)
        completeSubtrees.removeValue(forKey: path)
        if let children = childrenByDirectory.removeValue(forKey: path) {
            children.forEach(removeSubtreeLocked)
        }
    }

    /// A change inside `path` makes its stats, and those of every ancestor, stale.
    private func invalidateLocked(_ path: String) {
        for affected in PathUtils.ancestors(of: path) + [path] {
            statsByPath.removeValue(forKey: affected)
            completeSubtrees.removeValue(forKey: affected)
        }
    }

    private func storeStatsLocked(_ stats: FolderStats, for path: String) {
        if statsByPath.count >= Limits.maxCachedStats { statsByPath.removeAll(keepingCapacity: true) }
        statsByPath[path] = stats
    }

    /// Stats go too: a cached "complete" child would otherwise let a later crawl vouch for
    /// a subtree whose entries were just dropped.
    private func resetIndexLocked() {
        entriesByPath.removeAll(keepingCapacity: true)
        childrenByDirectory.removeAll(keepingCapacity: true)
        completeSubtrees.removeAll()
        statsByPath.removeAll()
        generation += 1
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Search Query

/// Parsed search box text: plain words must all appear in the name (or extension);
/// `ext:pdf`, `.pdf`, `*.pdf` filter by extension; `size:>10mb`, `>10mb`, `size:<1k`, `<1k` by size.
struct SearchQuery: Sendable {
    let nameNeedles: [String]
    let requiredExtension: String?
    let minSize: Int64?
    let maxSize: Int64?

    var isEmpty: Bool { nameNeedles.isEmpty && requiredExtension == nil && minSize == nil && maxSize == nil }

    init(_ raw: String) {
        var needles: [String] = []
        var ext: String?
        var minSize: Int64?
        var maxSize: Int64?

        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = token.lowercased()
            if lower.hasPrefix("ext:") {
                ext = String(lower.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else if lower.hasPrefix("*.") && lower.count > 2 {
                ext = String(lower.dropFirst(2))
            } else if lower.hasPrefix(".") && lower.count > 1 {
                ext = String(lower.dropFirst(1))
            } else if let bound = Self.sizeBound(lower, operator: ">") {
                minSize = bound
            } else if let bound = Self.sizeBound(lower, operator: "<") {
                maxSize = bound
            } else {
                needles.append(token)
            }
        }
        self.nameNeedles = needles
        self.requiredExtension = ext
        self.minSize = minSize
        self.maxSize = maxSize
    }

    func matches(_ item: FileItem) -> Bool {
        if let requiredExtension, item.ext != requiredExtension { return false }
        if let minSize, item.size < minSize { return false }
        if let maxSize, item.size > maxSize { return false }
        for needle in nameNeedles {
            if item.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
               item.ext.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return true
    }

    /// "size:>10mb" / ">10mb" → bytes. nil when the token isn't a size filter.
    private static func sizeBound(_ token: String, operator op: Character) -> Int64? {
        var rest = Substring(token)
        if rest.hasPrefix("size:") { rest = rest.dropFirst(5) }
        guard rest.first == op else { return nil }
        return parseBytes(String(rest.dropFirst()))
    }

    static func parseBytes(_ string: String) -> Int64? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let units: [(suffix: String, factor: Double)] = [
            ("gb", 1_073_741_824), ("g", 1_073_741_824), ("mb", 1_048_576), ("m", 1_048_576),
            ("kb", 1024), ("k", 1024), ("b", 1)
        ]
        for unit in units where text.hasSuffix(unit.suffix) {
            guard let value = Double(text.dropLast(unit.suffix.count)), value >= 0 else { return nil }
            return Int64(value * unit.factor)
        }
        guard let value = Double(text), value >= 0 else { return nil }
        return Int64(value)
    }
}
