import XCTest
@testable import FileExplorer

final class FileSystemServiceTests: XCTestCase {
    private var root = ""
    private let fs = FileSystemService()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "fe-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ name: String, _ text: String = "x") throws -> String {
        let path = PathUtils.join(root, name)
        try FileManager.default.createDirectory(atPath: PathUtils.parent(path), withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func mkdir(_ name: String) throws -> String {
        let path = PathUtils.join(root, name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testUniquePath() throws {
        _ = try write("a.txt")
        XCTAssertEqual(fs.uniquePath(in: root, name: "a.txt"), PathUtils.join(root, "a (2).txt"))
        XCTAssertEqual(fs.uniquePath(in: root, name: "new.txt"), PathUtils.join(root, "new.txt"))
    }

    func testRenameRejectsTraversalAndExistingNames() throws {
        let a = try write("a.txt")
        _ = try write("b.txt")
        XCTAssertThrowsError(try fs.rename(a, to: "../evil"))
        XCTAssertThrowsError(try fs.rename(a, to: "b.txt"))
        XCTAssertEqual(try fs.rename(a, to: "c.txt").name, "c.txt")
    }

    func testReadDirectoryClassifiesItems() throws {
        _ = try write("a.png")
        _ = try mkdir("sub")
        let items = try fs.readDirectory(root)
        XCTAssertEqual(Set(items.map(\.name)), ["a.png", "sub"])
        XCTAssertEqual(items.first { $0.name == "a.png" }?.kind, .image)
        XCTAssertTrue(items.first { $0.name == "sub" }?.isDirectory ?? false)
    }

    func testTransferCopyMoveAndPolicies() throws {
        let src = try write("f.txt", "new")
        let dest = try mkdir("dest")
        _ = try write("dest/f.txt", "old")

        XCTAssertEqual(fs.conflicts(sources: [src], destination: dest), ["f.txt"])

        _ = try fs.transfer(.copy, sources: [src], to: dest, policy: .skip)
        XCTAssertEqual(try String(contentsOfFile: PathUtils.join(dest, "f.txt")), "old")

        let both = try fs.transfer(.copy, sources: [src], to: dest, policy: .keepBoth)
        XCTAssertEqual(both.moves.first?.to, PathUtils.join(dest, "f (2).txt"))

        let moved = try fs.transfer(.move, sources: [src], to: dest, policy: .keepBoth)
        XCTAssertEqual(moved.moves.count, 1)
        XCTAssertFalse(fs.exists(src))
    }

    func testTransferRejectsSelfNesting() throws {
        let dir = try mkdir("outer")
        let inner = try mkdir("outer/inner")
        XCTAssertThrowsError(try fs.transfer(.move, sources: [dir], to: inner, policy: .keepBoth))
        XCTAssertThrowsError(try fs.transfer(.copy, sources: [dir], to: dir, policy: .keepBoth))
    }

    func testSearchFindsByName() throws {
        _ = try write("deep/er/Report-2026.txt")
        _ = try write("other.txt")
        let hits = fs.search(root: root, query: "report")
        XCTAssertEqual(hits.map(\.name), ["Report-2026.txt"])
    }

    func testModeString() {
        XCTAssertEqual(FileSystemService.modeString(0o755, isDirectory: true, isLink: false), "drwxr-xr-x")
        XCTAssertEqual(FileSystemService.modeString(0o600, isDirectory: false, isLink: false), "-rw-------")
    }
}
