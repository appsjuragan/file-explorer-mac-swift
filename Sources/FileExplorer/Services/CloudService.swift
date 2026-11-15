import Foundation

/// Dropbox / OneDrive / iCloud / Google Drive / Box detection by folder location.
///
/// Finder Sync extensions can't be hosted by another app, so their Finder menus aren't
/// reproduced; instead the folders are recognised and we offer our own equivalents
/// ("Open on Dropbox", "Make available offline"). Everything degrades to "not a cloud path".
struct CloudService: Sendable {
    var home: String = NSHomeDirectory()

    private var cloudStorageDir: String { home + "/Library/CloudStorage" }

    private static let prefixes: [(pattern: String, provider: CloudProvider, name: String)] = [
        ("^Dropbox\\d*(-|$)", .dropbox, "Dropbox"),
        ("^OneDrive\\d*(-|$)", .onedrive, "OneDrive"),
        ("^GoogleDrive\\d*(-|$)", .googledrive, "Google Drive"),
        ("^Box\\d*(-|$)", .box, "Box"),
        ("^iCloudDrive\\d*(-|$)", .icloud, "iCloud Drive")
    ]

    // MARK: Roots

    /// Blocking scan (a few directory reads) — call from a background task.
    func scanRoots() -> [CloudRoot] {
        var found = dropboxInfoRoots() + cloudStorageRoots() + iCloudRoot()
        var seen = Set<String>()
        found = found.filter { seen.insert($0.root).inserted }
        return found.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }

    static func classify(folder: String) -> (provider: CloudProvider, label: String) {
        let match = prefixes.first { folder.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        let account = folder.firstIndex(of: "-").map { String(folder[folder.index(after: $0)...]) } ?? ""
        let name = match?.name ?? String(folder.split(separator: "-").first ?? Substring(folder))
        return (match?.provider ?? .other, account.isEmpty ? name : "\(name) (\(account))")
    }

    private func cloudStorageRoots() -> [CloudRoot] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cloudStorageDir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            let path = cloudStorageDir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let c = Self.classify(folder: name)
            return CloudRoot(provider: c.provider, root: path, label: c.label)
        }
    }

    private func iCloudRoot() -> [CloudRoot] {
        let root = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return [] }
        return [CloudRoot(provider: .icloud, root: root, label: "iCloud Drive")]
    }

    private func dropboxInfoRoots() -> [CloudRoot] {
        guard let data = FileManager.default.contents(atPath: home + "/.dropbox/info.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.values.compactMap { account in
            guard let path = (account["root_path"] ?? account["path"]) as? String, !path.isEmpty else { return nil }
            return CloudRoot(provider: .dropbox, root: path, label: Self.classify(folder: PathUtils.basename(path)).label)
        }
    }

    // MARK: Lookup (cheap, synchronous — the context menu needs it immediately)

    /// The most specific root containing `path` (team roots nest inside each other).
    static func root(for path: String, in roots: [CloudRoot]) -> CloudRoot? {
        roots.filter { PathUtils.isInside(path, root: $0.root) }.max { $0.root.count < $1.root.count }
    }

    static func relativePath(_ path: String, in root: CloudRoot) -> String {
        path == root.root ? "" : String(path.dropFirst(root.root.count + 1))
    }

    func info(for path: String, roots: [CloudRoot]) -> CloudInfo? {
        guard let root = Self.root(for: path, in: roots) else { return nil }
        return CloudInfo(provider: root.provider, label: root.label, root: root.root,
                         relativePath: Self.relativePath(path, in: root), dataless: Self.isDataless(path))
    }

    /// A File Provider placeholder reports its real size but has no blocks allocated.
    static func isDataless(_ path: String) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys), !(v.isDirectory ?? false) else { return false }
        return (v.fileSize ?? 0) > 0 && (v.fileAllocatedSize ?? 0) == 0
    }

    // MARK: Web links

    private static let component: CharacterSet = {
        // Same unreserved set as JavaScript's encodeURIComponent.
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    }()

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: component) ?? text
    }

    static func encodePath(_ relative: String) -> String {
        relative.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
    }

    /// Web URL for a synced item, or nil when the provider has no derivable link.
    func webURL(for path: String, roots: [CloudRoot], isDirectory: Bool) -> URL? {
        guard let root = Self.root(for: path, in: roots), root.provider.supportsWebLink else { return nil }
        let relative = Self.relativePath(path, in: root)
        let text: String
        if root.provider == .dropbox {
            let parts = relative.split(separator: "/").map(String.init)
            if !isDirectory, let name = parts.last {
                text = "https://www.dropbox.com/home/\(Self.encodePath(parts.dropLast().joined(separator: "/")))?preview=\(Self.encode(name))"
            } else {
                text = "https://www.dropbox.com/home/\(Self.encodePath(relative))"
            }
        } else if let site = oneDriveSite(), let sitePath = URL(string: site)?.path {
            let id = "\(sitePath)/Documents" + (relative.isEmpty ? "" : "/\(relative)")
            text = "\(site)/_layouts/15/onedrive.aspx?id=\(Self.encode(id))"
        } else {
            text = "https://onedrive.live.com/"
        }
        guard let url = URL(string: text),
              Validation.isTrustedWebURL(url, allowedHostSuffixes: ["dropbox.com", "sharepoint.com", "live.com"]) else { return nil }
        return url
    }

    /// OneDrive publishes no local path→URL mapping; its site host is found in its settings
    /// databases. Best effort and bounded (depth 3, first 4 MB of each file).
    func oneDriveSite() -> String? {
        let settings = home + "/Library/Application Support/OneDrive/settings"
        guard let regex = try? NSRegularExpression(pattern: "https://[a-z0-9-]+-my\\.sharepoint\\.com/personal/[a-z0-9_]+",
                                                   options: [.caseInsensitive]) else { return nil }
        var counts: [String: Int] = [:]
        for file in collectFiles(settings, depth: 3) where file.hasSuffix(".db") || file.hasSuffix(".ini") {
            guard let handle = FileHandle(forReadingAtPath: file) else { continue }
            let data = (try? handle.read(upToCount: 4 * 1024 * 1024)) ?? Data()
            try? handle.close()
            let string = String(decoding: data, as: UTF8.self)
            let text = string as NSString
            for m in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) {
                counts[text.substring(with: m.range), default: 0] += 1
            }
        }
        // Binary scanning also finds truncated neighbours; trust the most frequent hit.
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key.count > b.key.count }?.key
    }

    private func collectFiles(_ dir: String, depth: Int) -> [String] {
        guard depth >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [String] = []
        for name in names {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                out += collectFiles(path, depth: depth - 1)
            } else { out.append(path) }
        }
        return out
    }

    // MARK: Offline

    /// Downloads placeholders by reading them through. It cannot set Dropbox's/OneDrive's
    /// "always keep on this device" pin (only their own apps can), so macOS may evict later.
    func makeAvailableOffline(_ paths: [String], progress: (@Sendable (OpProgress) -> Void)? = nil) throws -> Int {
        var files: [String] = []
        for path in paths { files += filesUnder(path) }
        var done = 0
        for file in files {
            if Task.isCancelled { break }
            progress?(OpProgress(op: .download, done: done, total: files.count, name: PathUtils.basename(file)))
            if Self.isDataless(file) { try readThrough(file) }
            done += 1
        }
        progress?(OpProgress(op: .download, done: done, total: files.count, name: ""))
        return files.count
    }

    private func filesUnder(_ path: String) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [path] }
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink ?? false { walker.skipDescendants(); continue }   // never follow links
            if !(v?.isDirectory ?? false) { out.append(url.path) }
        }
        return out
    }

    private func readThrough(_ path: String) throws {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            while true {
                let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
                if chunk == nil || chunk!.isEmpty { break }
            }
        } catch { throw FileOpError(wrapping: error) }
    }
}
