import Foundation

/// POSIX path helpers used for display and navigation (the real I/O is in the services).
enum PathUtils {
    /// Sentinel "path" for the virtual Home page. Never read from disk.
    static let home = "home://"

    static func basename(_ path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let idx = trimmed.lastIndex(of: "/") { return String(trimmed[trimmed.index(after: idx)...]) }
        return trimmed
    }

    static func parent(_ path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<idx])
        return parent.isEmpty ? "/" : parent
    }

    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    /// True when `path` is `root` or inside it. Component-aware ("/a/bc" is not under "/a/b").
    static func isInside(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// Ancestor paths ordered from the volume root down to the immediate parent.
    /// E.g. "/Users/hy3-mac-013/sourcecode" -> ["/", "/Users", "/Users/hy3-mac-013"]
    static func ancestors(of path: String) -> [String] {
        guard path.hasPrefix("/"), path != "/" else { return [] }
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        var parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }
        parts.removeLast()
        var result: [String] = ["/"]
        var acc = ""
        for part in parts {
            acc += "/" + part
            if acc != "/" && !result.contains(acc) {
                result.append(acc)
            }
        }
        return result
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Friendly label used in tabs.
    static func displayName(_ path: String, homeDir: String) -> String {
        if path == home { return "Home" }
        if path == "/" { return "Macintosh HD" }
        if !homeDir.isEmpty && path == homeDir { return "Home" }
        if path.hasPrefix("/Volumes/") {
            let rest = path.dropFirst("/Volumes/".count)
            if !rest.contains("/") { return String(rest) }
        }
        return basename(path)
    }

    struct Segment: Equatable, Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }

    /// Breadcrumb segments; the home directory collapses into one "Home" crumb.
    static func segments(_ path: String, homeDir: String) -> [Segment] {
        if path == home { return [Segment(name: "Home", path: home)] }
        var segs = [Segment(name: "Macintosh HD", path: "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/" + part
            segs.append(Segment(name: String(part), path: acc))
        }
        if !homeDir.isEmpty && isInside(path, root: homeDir) {
            let homeParts = homeDir.split(separator: "/").count
            var collapsed = [Segment(name: "Home", path: homeDir)]
            if segs.count > homeParts + 1 { collapsed += segs[(homeParts + 1)...] }
            return collapsed
        }
        return segs
    }

    /// Expands "~" and resolves relative input typed into the address bar.
    static func resolveTyped(_ input: String, homeDir: String, currentPath: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return currentPath }
        if text == "~" { return homeDir }
        if text.hasPrefix("~/") { return standardized(join(homeDir, String(text.dropFirst(2)))) }
        if text.hasPrefix("/") { return standardized(text) }
        let base = currentPath == home ? homeDir : currentPath
        return standardized(join(base, text))
    }
}
