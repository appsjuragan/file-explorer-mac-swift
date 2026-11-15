import Foundation

/// All disk access. Synchronous and free of UI types, so callers decide where it runs
/// (the model always hops to a background task). Throws `FileOpError`.
struct FileSystemService: Sendable {
    private static let itemKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .isHiddenKey
    ]

    private var fm: FileManager { .default }

    // MARK: - Reading

    func readDirectory(_ path: String) throws -> [FileItem] {
        do {
            let urls = try fm.contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: Self.itemKeys,
                options: []
            )
            var items: [FileItem] = []
            items.reserveCapacity(urls.count)
            // An entry we can't stat (permission, race with deletion) is skipped, not fatal.
            for url in urls { if let item = try? makeItem(url) { items.append(item) } }
            return items
        } catch {
            throw FileOpError(wrapping: error)
        }
    }

    func fileItem(at path: String) throws -> FileItem {
        do { return try makeItem(URL(fileURLWithPath: path)) } catch { throw FileOpError(wrapping: error) }
    }

    func makeItem(_ url: URL) throws -> FileItem {
        let values = try url.resourceValues(forKeys: Set(Self.itemKeys))
        let isLink = values.isSymbolicLink ?? false
        var isDirectory = values.isDirectory ?? false
        var size = Int64(values.fileSize ?? 0)
        if isLink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) {
            isDirectory = target.isDirectory ?? false
            size = Int64(target.fileSize ?? 0)
        }
        let name = url.lastPathComponent
        let ext = isDirectory ? "" : url.pathExtension.lowercased()
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return FileItem(
            name: name,
            path: url.path,
            isDirectory: isDirectory,
            isSymbolicLink: isLink,
            size: isDirectory ? 0 : size,
            modified: modified,
            created: values.creationDate?.timeIntervalSince1970 ?? modified,
            ext: ext,
            isHidden: name.hasPrefix(".") || (values.isHidden ?? false),
            kind: FileKinds.classify(isDirectory: isDirectory, ext: ext, name: name)
        )
    }

    // MARK: - Locations

    var homeDirectory: String { NSHomeDirectory() }

    func quickLinks() -> [QuickLink] {
        var links = [QuickLink(name: "Home", path: homeDirectory, icon: .home)]
        let candidates: [(String, FileManager.SearchPathDirectory, QuickLinkIcon)] = [
            ("Desktop", .desktopDirectory, .desktop),
            ("Documents", .documentDirectory, .documents),
            ("Downloads", .downloadsDirectory, .downloads),
            ("Pictures", .picturesDirectory, .pictures),
            ("Music", .musicDirectory, .music),
            ("Videos", .moviesDirectory, .videos)
        ]
        for (name, dir, icon) in candidates {
            if let url = fm.urls(for: dir, in: .userDomainMask).first, exists(url.path) {
                links.append(QuickLink(name: name, path: url.path, icon: icon))
            }
        }
        return links
    }

    func drives() -> [DriveItem] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey
        ]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable ?? true else { return nil }
            return DriveItem(
                name: v.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: v.volumeTotalCapacity.map(Int64.init),
                free: v.volumeAvailableCapacityForImportantUsage
            )
        }
    }

    /// `lstat`-based, so a broken symlink still counts as existing.
    func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Creating & renaming

    /// "name", "name (2)", "name (3)", … — the first one that doesn't exist.
    func uniquePath(in parent: String, name: String) -> String {
        let first = PathUtils.join(parent, name)
        if !exists(first) { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        for i in 2..<1000 {
            let candidate = PathUtils.join(parent, ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return PathUtils.join(parent, "\(stem) (\(UUID().uuidString.prefix(8)))" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    func createFolder(in parent: String, name: String) throws -> FileItem {
        do {
            let target = uniquePath(in: parent, name: try Validation.fileName(name.isEmpty ? "New folder" : name))
            try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
            return try fileItem(at: target)
        } catch { throw FileOpError(wrapping: error) }
    }

    func createTextFile(in parent: String, name: String) throws -> FileItem {
        do {
            let target = uniquePath(in: parent, name: try Validation.fileName(name.isEmpty ? "New Text Document.txt" : name))
            guard fm.createFile(atPath: target, contents: Data(), attributes: nil) else {
                throw FileOpError("Couldn't create the file.")
            }
            return try fileItem(at: target)
        } catch { throw FileOpError(wrapping: error) }
    }

    func rename(_ path: String, to newName: String) throws -> FileItem {
        do {
            let clean = try Validation.fileName(newName)
            let dest = PathUtils.join(PathUtils.parent(path), clean)
            if dest == path { return try fileItem(at: path) }
            let caseOnly = dest.lowercased() == path.lowercased()
            if exists(dest) && !caseOnly { throw FileOpError("An item named \"\(clean)\" already exists.") }
            if caseOnly {
                // Case-insensitive volumes treat a→A as "already exists"; go through a temp name.
                let temp = PathUtils.join(PathUtils.parent(path), ".fe-rename-\(UUID().uuidString)")
                try fm.moveItem(atPath: path, toPath: temp)
                do { try fm.moveItem(atPath: temp, toPath: dest) } catch {
                    try? fm.moveItem(atPath: temp, toPath: path)
                    throw error
                }
            } else {
                try fm.moveItem(atPath: path, toPath: dest)
            }
            return try fileItem(at: dest)
        } catch { throw FileOpError(wrapping: error) }
    }

    // MARK: - Trash

    struct TrashResult {
        var moves: [FileMove] = []
        var failed: [String] = []
    }

    /// Moves each item to the Trash independently; one failure doesn't abort the rest.
    /// `moves` records where each item went, so the delete can be undone.
    func trash(_ paths: [String]) -> TrashResult {
        var result = TrashResult()
        for path in paths {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                if let dest = (resulting as URL?)?.path { result.moves.append(FileMove(from: path, to: dest)) }
            } catch {
                result.failed.append(PathUtils.basename(path))
            }
        }
        return result
    }

    /// Puts items back where they came from (Undo of a delete or move). If the original
    /// path is taken again, the item is restored next to it under a unique name.
    func restore(_ moves: [FileMove]) throws {
        for m in moves {
            var target = m.from
            if exists(target) { target = uniquePath(in: PathUtils.parent(m.from), name: PathUtils.basename(m.from)) }
            do { try fm.moveItem(atPath: m.to, toPath: target) } catch { throw FileOpError(wrapping: error) }
        }
    }

    /// Whether two paths live on the same volume (drag-and-drop: same volume moves, else copies).
    func sameVolume(_ a: String, _ b: String) -> Bool {
        func id(_ p: String) -> NSObjectProtocol? {
            (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x.isEqual(y)
    }

    // MARK: - Copy & move

    /// Names in `destination` that already exist among the sources.
    func conflicts(sources: [String], destination: String) -> [String] {
        let dest = PathUtils.standardized(destination)
        return sources.compactMap { src in
            let name = PathUtils.basename(src)
            if PathUtils.standardized(PathUtils.parent(src)) == dest { return nil }
            return exists(PathUtils.join(dest, name)) ? name : nil
        }
    }

    func transfer(_ op: OpKind, sources: [String], to destination: String, policy: ConflictPolicy,
                  progress: (@Sendable (OpProgress) -> Void)? = nil) throws -> TransferResult {
        precondition(op == .copy || op == .move)
        let dest = PathUtils.standardized(destination)
        var moves: [FileMove] = []
        var done = 0
        for source in sources {
            if Task.isCancelled { break }
            let name = PathUtils.basename(source)
            progress?(OpProgress(op: op, done: done, total: sources.count, name: name))
            let src = PathUtils.standardized(source)
            let sameFolder = PathUtils.parent(src) == dest

            if op == .move && sameFolder { done += 1; continue }
            if PathUtils.isInside(dest, root: src) {
                throw FileOpError("Can't \(op == .move ? "move" : "copy") \"\(name)\" into itself.")
            }

            var target = PathUtils.join(dest, name)
            if exists(target) {
                switch policy {
                case .skip: done += 1; continue
                case .keepBoth: target = uniquePath(in: dest, name: name)
                case .replace:
                    if PathUtils.standardized(target) == src { done += 1; continue }
                    // Recoverable: the replaced item goes to the Trash, not into the void.
                    if !trash([target]).failed.isEmpty { throw FileOpError("Couldn't replace \"\(name)\".") }
                }
            }
            do {
                if op == .move { try fm.moveItem(atPath: src, toPath: target) }
                else { try fm.copyItem(atPath: src, toPath: target) }   // clonefile on APFS
            } catch { throw FileOpError(wrapping: error) }
            moves.append(FileMove(from: src, to: target))
            done += 1
            progress?(OpProgress(op: op, done: done, total: sources.count, name: name))
        }
        return TransferResult(moves: moves)
    }

    // MARK: - Search

    /// Recursive name search, bounded by result count, depth and time; cancellable.
    func search(root: String, query: String, maxResults: Int = 500, maxDepth: Int = 8,
                timeLimit: TimeInterval = 8) -> [FileItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(timeLimit)
        var results: [FileItem] = []
        var stack: [(path: String, depth: Int)] = [(root, 0)]

        while let (dir, depth) = stack.popLast() {
            if Task.isCancelled || Date() > deadline || results.count >= maxResults { break }
            guard let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir, isDirectory: true),
                includingPropertiesForKeys: Self.itemKeys, options: []) else { continue }
            for url in urls {
                if results.count >= maxResults { break }
                guard let item = try? makeItem(url) else { continue }
                if item.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    results.append(item)
                }
                if item.isDirectory && !item.isSymbolicLink && depth < maxDepth {
                    stack.append((item.path, depth + 1))
                }
            }
        }
        return results
    }

    // MARK: - Properties

    func properties(_ path: String) throws -> PropertyInfo {
        do {
            let url = URL(fileURLWithPath: path)
            let attrs = try fm.attributesOfItem(atPath: path)
            let isLink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            let target = isLink ? try? fm.destinationOfSymbolicLink(atPath: path) : nil
            let item = try makeItem(url)
            let access = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return PropertyInfo(
                name: item.name, path: path, parent: PathUtils.parent(path),
                isDirectory: item.isDirectory, isSymbolicLink: isLink, symlinkTarget: target,
                size: item.size, created: item.created, modified: item.modified,
                accessed: access?.timeIntervalSince1970 ?? 0,
                mode: Self.modeString(perms, isDirectory: item.isDirectory, isLink: isLink),
                kind: item.kind, typeLabel: FileKinds.label(for: item)
            )
        } catch { throw FileOpError(wrapping: error) }
    }

    static func modeString(_ mode: Int, isDirectory: Bool, isLink: Bool) -> String {
        func rwx(_ bits: Int) -> String {
            (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
        }
        return (isLink ? "l" : isDirectory ? "d" : "-") + rwx((mode >> 6) & 7) + rwx((mode >> 3) & 7) + rwx(mode & 7)
    }

    /// Recursive size; stops at `timeLimit` and reports `complete == false`.
    func folderSize(_ path: String, timeLimit: TimeInterval = 12) -> FolderSize {
        var result = FolderSize(size: 0, files: 0, folders: 0, complete: true)
        let deadline = Date().addingTimeInterval(timeLimit)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                         options: [], errorHandler: { _, _ in true }) else { return result }
        for case let url as URL in walker {
            if Task.isCancelled || Date() > deadline { result.complete = false; break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink ?? false { continue }
            if v.isDirectory ?? false { result.folders += 1 }
            else { result.files += 1; result.size += Int64(v.fileSize ?? 0) }
        }
        return result
    }

    /// First chunk of a text file. Throws for binary content so the pane shows nothing.
    func readTextPreview(_ path: String, maxBytes: Int = 64 * 1024) throws -> String {
        let cap = min(max(1, maxBytes), 1024 * 1024)
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: cap) ?? Data()
            if data.contains(0) { throw FileOpError("Binary file") }
            return String(decoding: data, as: UTF8.self)
        } catch { throw FileOpError(wrapping: error) }
    }

    // MARK: - Archives

    /// Zips the items (which must share a parent folder) into `destination`.
    func compressZip(_ sources: [String], into destination: String) throws -> FileItem {
        guard let first = sources.first else { throw FileOpError("Nothing to compress.") }
        let parent = PathUtils.parent(first)
        guard sources.allSatisfy({ PathUtils.parent($0) == parent }) else {
            throw FileOpError("Select items from a single folder to compress them.")
        }
        let names = sources.map(PathUtils.basename)
        let outName = sources.count == 1 ? ((names[0] as NSString).deletingPathExtension + ".zip") : "Archive.zip"
        let out = uniquePath(in: destination, name: outName)
        // "./" keeps a file called "-T" or "--unzip-command=…" from being read as an option.
        let result = try ProcessRunner.run("/usr/bin/zip", ["-r", "-q", "-X", out] + names.map { "./" + $0 }, currentDirectory: parent)
        guard result.status == 0 else {
            throw FileOpError(result.stderrText.isEmpty ? "Compression failed." : result.stderrText)
        }
        return try fileItem(at: out)
    }

    /// Extracts into a new folder named after the archive. Entries are validated first.
    func extractZip(_ zipPath: String, into destination: String) throws -> FileItem {
        let listing = try ProcessRunner.run("/usr/bin/zipinfo", ["-1", zipPath])
        guard listing.status == 0 else { throw FileOpError("This isn't a valid ZIP archive.") }
        let entries = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        guard entries.allSatisfy(Validation.isSafeArchiveEntry) else {
            throw FileOpError("This archive contains unsafe paths and wasn't extracted.")
        }
        let stem = (PathUtils.basename(zipPath) as NSString).deletingPathExtension
        let outDir = uniquePath(in: destination, name: stem.isEmpty ? "Extracted" : stem)
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: false) } catch { throw FileOpError(wrapping: error) }
        let result = try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zipPath, outDir])
        guard result.status == 0 else {
            try? fm.removeItem(atPath: outDir)
            throw FileOpError(result.stderrText.isEmpty ? "Extraction failed." : result.stderrText)
        }
        return try fileItem(at: outDir)
    }
}
