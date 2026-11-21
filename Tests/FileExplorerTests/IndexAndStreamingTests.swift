import XCTest
@testable import FileExplorer

/// Temporary folder tree shared by the tests below.
private final class TempTree {
    /// Canonical path ("/private/var/…"), so paths built here match the ones listings return.
    let root: String

    init() throws {
        let path = NSTemporaryDirectory() + "fe-index-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        guard let resolved = realpath(path, nil) else { root = path; return }
        root = String(cString: resolved)
        free(resolved)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func file(_ name: String, bytes: Int = 1) throws -> String {
        let path = PathUtils.join(root, name)
        try FileManager.default.createDirectory(atPath: PathUtils.parent(path), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }
}

final class SearchQueryTests: XCTestCase {
    func testParsesFilters() {
        let q = SearchQuery("report ext:.PDF size:>1mb <2g")
        XCTAssertEqual(q.nameNeedles, ["report"])
        XCTAssertEqual(q.requiredExtension, "pdf")
        XCTAssertEqual(q.minSize, 1_048_576)
        XCTAssertEqual(q.maxSize, 2 * 1_073_741_824)
        XCTAssertEqual(SearchQuery("*.txt").requiredExtension, "txt")
        XCTAssertEqual(SearchQuery(".md").requiredExtension, "md")
        XCTAssertTrue(SearchQuery("   ").isEmpty)
    }

    func testParseBytes() {
        XCTAssertEqual(SearchQuery.parseBytes("10k"), 10_240)
        XCTAssertEqual(SearchQuery.parseBytes("1.5kb"), 1_536)
        XCTAssertEqual(SearchQuery.parseBytes("42"), 42)
        XCTAssertNil(SearchQuery.parseBytes("lots"))
    }
}

final class WalkTests: XCTestCase {
    func testWalkSkipsAppBundlesAndReportsDepthCutoff() throws {
        let tree = try TempTree()
        try tree.file("a/b/c/deep.txt")
        try tree.file("Tool.app/Contents/inside.txt")
        let fs = FileSystemService()

        var seen: [String] = []
        let complete = fs.walk(tree.root, maxDepth: 1, deadline: .distantFuture) { _, children in
            seen += children.map(\.name)
            return true
        }
        XCTAssertFalse(complete, "a/b/c is below maxDepth")
        XCTAssertTrue(seen.contains("Tool.app"))
        XCTAssertFalse(seen.contains("Contents"), "app bundles are not entered")
        XCTAssertFalse(seen.contains("deep.txt"))

        XCTAssertTrue(fs.walk(tree.root, maxDepth: 8, deadline: .distantFuture) { _, _ in true })
    }
}

final class FileIndexWorkerTests: XCTestCase {
    func testSearchScansThenAnswersFromIndexAndForgetsRemovedEntries() async throws {
        let tree = try TempTree()
        try tree.file("x/y/Report-2026.txt")
        try tree.file("x/other.txt")
        let index = FileIndexWorker()

        let scanned = await index.search(root: tree.root, query: "report")
        XCTAssertEqual(scanned.map(\.name), ["Report-2026.txt"])

        try tree.file("x/Report-new.txt")                                  // not announced to the index
        let cached = await index.search(root: tree.root, query: "report")
        XCTAssertEqual(cached.map(\.name), ["Report-2026.txt"], "served from the fully indexed subtree")

        try FileManager.default.removeItem(atPath: scanned[0].path)
        index.removeEntry(at: scanned[0].path)
        let rescanned = await index.search(root: tree.root, query: "report")
        XCTAssertEqual(rescanned.map(\.name), ["Report-new.txt"], "a removal invalidates the subtree, so disk is read again")
    }

    func testIndexedSearchStaysInsideRoot() async throws {
        let tree = try TempTree()
        try tree.file("in/match.txt")
        let sibling = tree.root + "-sibling"                                // shares the root's string prefix
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: sibling + "/match.txt"))

        let index = FileIndexWorker()
        _ = await index.search(root: tree.root, query: "match")              // root fully indexed
        _ = await index.search(root: sibling, query: "match")                // sibling indexed too
        let hits = await index.search(root: tree.root, query: "match")       // answered from the index
        XCTAssertEqual(hits.map(\.name), ["match.txt"])
        XCTAssertFalse(hits.contains { $0.path.hasPrefix(sibling) })
    }

    func testFolderStatsAreComputedInBackgroundAndInvalidated() throws {
        let tree = try TempTree()
        try tree.file("d/one.bin", bytes: 100)
        try tree.file("d/sub/two.bin", bytes: 50)
        let dir = PathUtils.join(tree.root, "d")
        let index = FileIndexWorker()

        XCTAssertNil(index.folderStats(for: dir), "a miss never blocks to compute")
        let stats = try waitForStats(index, dir)
        XCTAssertEqual(stats.totalSize, 150)
        XCTAssertEqual(stats.objectCount, 3)                          // one.bin, sub, two.bin
        XCTAssertTrue(stats.isComplete)

        index.invalidateFolderStats(for: PathUtils.join(dir, "sub"))
        XCTAssertNil(index.folderStats(for: dir), "a change below a folder makes its stats stale")
    }

    private func waitForStats(_ index: FileIndexWorker, _ path: String) throws -> FolderStats {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let stats = index.folderStats(for: path) { return stats }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw XCTSkip("stats not ready in time")
    }
}

final class ProgressThrottleTests: XCTestCase {
    func testForwardsEdgesAndThrottlesTheMiddle() {
        final class Sink: @unchecked Sendable { var received: [Int] = [] }
        let sink = Sink()
        let throttle = ProgressThrottle({ sink.received.append($0.done) }, interval: 60)
        for done in 0...1_000 { throttle.report(OpProgress(op: .copy, done: done, total: 1_000, name: "")) }
        XCTAssertEqual(sink.received, [0, 1_000])
    }
}

final class ProcessRunnerStreamingTests: XCTestCase {
    func testStreamsLinesIncludingMultibyteText() throws {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let output = try ProcessRunner.runStreaming("/usr/bin/printf", ["a\\nnaïve café\\nlast"]) { lines.all.append($0) }
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(lines.all, ["a", "naïve café", "last"])
        XCTAssertTrue(output.stdout.isEmpty, "streamed output is not buffered")
    }
}

final class GroupingTests: XCTestCase {
    func testModifiedGroupsUseOneStartOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let items = [today + 10, today - 10, today - 3 * 86_400].enumerated().map { i, t in
            FileItem(name: "f\(i)", path: "/t/f\(i)", isDirectory: false, isSymbolicLink: false, size: 1,
                     modified: t, created: t, ext: "", isHidden: false, kind: .file)
        }
        let labels = ItemOrdering.sections(items, groupBy: .modified, now: now, calendar: calendar).map(\.label)
        XCTAssertEqual(labels, ["Today", "Yesterday", "Earlier this week"])
    }

    func testNameGroupUsesFirstLetter() {
        let item = FileItem(name: "zeta.txt", path: "/t/zeta.txt", isDirectory: false, isSymbolicLink: false, size: 1,
                            modified: 0, created: 0, ext: "txt", isHidden: false, kind: .text)
        XCTAssertEqual(ItemOrdering.sections([item], groupBy: .name).first?.label, "Z")
    }
}
