import XCTest
@testable import FileExplorer

private func item(_ name: String, dir: Bool = false, size: Int64 = 0, modified: TimeInterval = 0, hidden: Bool = false) -> FileItem {
    let ext = (name as NSString).pathExtension.lowercased()
    return FileItem(name: name, path: "/t/\(name)", isDirectory: dir, isSymbolicLink: false, size: size,
                    modified: modified, created: modified, ext: dir ? "" : ext, isHidden: hidden,
                    kind: FileKinds.classify(isDirectory: dir, ext: ext, name: name))
}

final class ItemOrderingTests: XCTestCase {
    func testFoldersFirstAndNaturalOrder() {
        let items = [item("file10.txt"), item("file2.txt"), item("Zed", dir: true), item("alpha", dir: true)]
        let out = ItemOrdering.visible(items, showHidden: true, sortKey: .name, direction: .ascending).map(\.name)
        XCTAssertEqual(out, ["alpha", "Zed", "file2.txt", "file10.txt"])
    }

    func testDescendingKeepsFoldersFirst() {
        let items = [item("a.txt"), item("b.txt"), item("dir", dir: true)]
        let out = ItemOrdering.visible(items, showHidden: true, sortKey: .name, direction: .descending).map(\.name)
        XCTAssertEqual(out, ["dir", "b.txt", "a.txt"])
    }

    func testHiddenFilter() {
        let items = [item(".secret", hidden: true), item("shown.txt")]
        XCTAssertEqual(ItemOrdering.visible(items, showHidden: false, sortKey: .name, direction: .ascending).count, 1)
        XCTAssertEqual(ItemOrdering.visible(items, showHidden: true, sortKey: .name, direction: .ascending).count, 2)
    }

    func testSortBySizeTiesFallBackToName() {
        let items = [item("b.bin", size: 5), item("a.bin", size: 5), item("c.bin", size: 1)]
        let out = ItemOrdering.visible(items, showHidden: true, sortKey: .size, direction: .ascending).map(\.name)
        XCTAssertEqual(out, ["c.bin", "a.bin", "b.bin"])
    }

    func testGroupingBySize() {
        let sections = ItemOrdering.sections([item("e", size: 0), item("s", size: 100)], groupBy: .size)
        XCTAssertEqual(sections.map(\.label), ["Empty", "Tiny (0–16 KB)"])
    }

    func testNoGroupingYieldsSingleSection() {
        XCTAssertEqual(ItemOrdering.sections([item("a")], groupBy: .none).count, 1)
    }
}

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Formatting.bytes(0), "0 KB")
        XCTAssertEqual(Formatting.bytes(1), "1 KB")
        XCTAssertEqual(Formatting.bytes(2048), "2 KB")
        XCTAssertTrue(Formatting.bytes(5 * 1024 * 1024).hasSuffix("MB"))
    }

    func testAbbreviatingHome() {
        XCTAssertEqual(Formatting.abbreviatingHome("/Users/a/Documents", home: "/Users/a"), "~/Documents")
        XCTAssertEqual(Formatting.abbreviatingHome("/Users/ab", home: "/Users/a"), "/Users/ab")
    }
}

final class PathUtilsTests: XCTestCase {
    func testBasenameAndParent() {
        XCTAssertEqual(PathUtils.basename("/a/b/c.txt"), "c.txt")
        XCTAssertEqual(PathUtils.parent("/a/b/c.txt"), "/a/b")
        XCTAssertEqual(PathUtils.parent("/a"), "/")
        XCTAssertEqual(PathUtils.parent("/"), "/")
    }

    func testIsInsideIsComponentAware() {
        XCTAssertTrue(PathUtils.isInside("/a/b/c", root: "/a/b"))
        XCTAssertTrue(PathUtils.isInside("/a/b", root: "/a/b"))
        XCTAssertFalse(PathUtils.isInside("/a/bc", root: "/a/b"))
    }

    func testSegmentsCollapseHome() {
        let segs = PathUtils.segments("/Users/me/Documents/x", homeDir: "/Users/me")
        XCTAssertEqual(segs.map(\.name), ["Home", "Documents", "x"])
        XCTAssertEqual(segs.first?.path, "/Users/me")
        XCTAssertEqual(PathUtils.segments("/etc/hosts", homeDir: "/Users/me").first?.name, "Macintosh HD")
    }

    func testResolveTyped() {
        XCTAssertEqual(PathUtils.resolveTyped("~", homeDir: "/Users/me", currentPath: "/x"), "/Users/me")
        XCTAssertEqual(PathUtils.resolveTyped("~/Docs", homeDir: "/Users/me", currentPath: "/x"), "/Users/me/Docs")
        XCTAssertEqual(PathUtils.resolveTyped("sub", homeDir: "/Users/me", currentPath: "/x"), "/x/sub")
        XCTAssertEqual(PathUtils.resolveTyped("/a/../b", homeDir: "/Users/me", currentPath: "/x"), "/b")
    }

    func testAncestors() {
        XCTAssertEqual(PathUtils.ancestors(of: "/"), [])
        XCTAssertEqual(PathUtils.ancestors(of: "home://"), [])
        XCTAssertEqual(PathUtils.ancestors(of: "/Users"), ["/"])
        XCTAssertEqual(PathUtils.ancestors(of: "/Users/me"), ["/", "/Users"])
        XCTAssertEqual(PathUtils.ancestors(of: "/Users/me/source/app"), ["/", "/Users", "/Users/me", "/Users/me/source"])
        XCTAssertEqual(PathUtils.ancestors(of: "/Users/me/source/app/"), ["/", "/Users", "/Users/me", "/Users/me/source"])
    }
}

final class ValidationTests: XCTestCase {
    func testFileName() throws {
        XCTAssertEqual(try Validation.fileName("  ok.txt "), "ok.txt")
        for bad in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try Validation.fileName(bad), "\(bad.prefix(8))")
        }
    }

    func testZipSlip() {
        XCTAssertTrue(Validation.isSafeArchiveEntry("dir/file.txt"))
        XCTAssertFalse(Validation.isSafeArchiveEntry("../evil"))
        XCTAssertFalse(Validation.isSafeArchiveEntry("a/../../evil"))
        XCTAssertFalse(Validation.isSafeArchiveEntry("/etc/passwd"))
        XCTAssertFalse(Validation.isSafeArchiveEntry("~/x"))
        XCTAssertFalse(Validation.isSafeArchiveEntry(""))
    }

    func testTrustedURL() {
        let allowed = ["dropbox.com"]
        XCTAssertTrue(Validation.isTrustedWebURL(URL(string: "https://www.dropbox.com/home")!, allowedHostSuffixes: allowed))
        XCTAssertFalse(Validation.isTrustedWebURL(URL(string: "http://www.dropbox.com")!, allowedHostSuffixes: allowed))
        XCTAssertFalse(Validation.isTrustedWebURL(URL(string: "https://evildropbox.com")!, allowedHostSuffixes: allowed))
    }

    func testVersions() {
        XCTAssertTrue(Validation.isVersion("v1.10.0", newerThan: "1.9.9"))
        XCTAssertFalse(Validation.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(Validation.isVersion("1.1.9", newerThan: "1.2.0"))
    }
}

final class PrefsTests: XCTestCase {
    func testToleratesMissingKeys() throws {
        let prefs = try JSONDecoder().decode(Prefs.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.viewMode, .details)
        XCTAssertTrue(prefs.navigationPaneOpen)
        XCTAssertFalse(prefs.quickAccessCollapsed)
        XCTAssertFalse(prefs.thisPCCollapsed)
        XCTAssertEqual(prefs.iconTheme, .windows)
    }

    func testRoundTrip() throws {
        var prefs = Prefs()
        prefs.viewMode = .tiles
        prefs.showHidden = true
        prefs.quickAccessCollapsed = true
        prefs.thisPCCollapsed = true
        prefs.iconTheme = .ubuntu
        prefs.customIconThemePath = "/custom/icons"
        let decoded = try JSONDecoder().decode(Prefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
    }
}

final class CloudServiceTests: XCTestCase {
    func testEncodeMatchesEncodeURIComponent() {
        XCTAssertEqual(CloudService.encode("a b&c/d"), "a%20b%26c%2Fd")
        XCTAssertEqual(CloudService.encodePath("My Docs/file #1.txt"), "My%20Docs/file%20%231.txt")
    }

    func testClassify() {
        XCTAssertEqual(CloudService.classify(folder: "Dropbox").provider, .dropbox)
        XCTAssertEqual(CloudService.classify(folder: "OneDrive-Contoso").provider, .onedrive)
    }
}
