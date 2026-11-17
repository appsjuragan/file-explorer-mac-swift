import Foundation
import UniformTypeIdentifiers

// MARK: - MIME Type Resolver

enum MimeTypeResolver {
    /// Resolves MIME type from file extension with fallback to standard types.
    static func mimeType(for ext: String) -> String {
        let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if !clean.isEmpty, let uttype = UTType(filenameExtension: clean), let mime = uttype.preferredMIMEType {
            return mime
        }
        switch clean {
        case "swift": return "text/x-swift"
        case "ts": return "text/typescript"
        case "tsx": return "text/typescript-jsx"
        case "jsx": return "text/javascript-jsx"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "yaml", "yml": return "text/yaml"
        case "sh", "zsh", "bash": return "application/x-sh"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "7z": return "application/x-7z-compressed"
        case "rar": return "application/x-rar-compressed"
        case "dmg": return "application/x-apple-diskimage"
        case "iso": return "application/x-iso9660-image"
        case "sql": return "application/sql"
        case "csv": return "text/csv"
        case "xml": return "application/xml"
        case "pdf": return "application/pdf"
        case "txt", "log", "ini", "conf", "env": return "text/plain"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs", "cjs": return "application/javascript"
        case "wasm": return "application/wasm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "m4a", "aac": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        default: return clean.isEmpty ? "application/octet-stream" : "application/\(clean)"
        }
    }
}

// MARK: - Folder Stats

struct FolderStats: Sendable {
    var totalSize: Int64
    var objectCount: Int
    var lastModified: TimeInterval
    var isComplete: Bool
}

// MARK: - File Index Entry

struct FileIndexEntry: Sendable, Hashable {
    let path: String
    let name: String
    let ext: String               // extension only (lowercase, no dot)
    let size: Int64               // size in bytes
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let modified: TimeInterval
    let created: TimeInterval
    let kind: FileKind
    let isHidden: Bool

    func toFileItem() -> FileItem {
        FileItem(
            name: name,
            path: path,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: isDirectory ? 0 : size,
            modified: modified,
            created: created,
            ext: ext,
            isHidden: isHidden,
            kind: kind
        )
    }
}

// MARK: - Tooltip Helper

enum FileTooltipHelper {
    static let folderStatsUpdated = Notification.Name("fe.folderStatsUpdated")

    static func tooltip(for item: FileItem) -> String {
        if item.opensAsFolder {
            let stats = FileIndexWorker.shared.folderStats(for: item.path)
            let sizeText = stats.map { Formatting.bytes($0.totalSize) } ?? "Calculating..."
            let countText = stats.map { "\($0.objectCount)" } ?? "Calculating..."
            let dateText = Formatting.dateTime(stats?.lastModified ?? item.modified)

            return """
            Total size: \(sizeText)
            Object count: \(countText)
            Date modified: \(dateText)
            """
        } else {
            let sizeText = Formatting.bytes(item.size)
            let mimeText = MimeTypeResolver.mimeType(for: item.ext)
            let dateText = Formatting.dateTime(item.modified)

            return """
            Size: \(sizeText)
            Type: \(mimeText)
            Date modified: \(dateText)
            """
        }
    }
}

// MARK: - Indexing Worker

final class FileIndexWorker: @unchecked Sendable {
    static let shared = FileIndexWorker()

    private let queue = DispatchQueue(label: "fe.file-index-worker")
    private var entriesByPath: [String: FileIndexEntry] = [:]
    private var pathsByDirectory: [String: Set<String>] = [:]
    private var pathsByExtension: [String: Set<String>] = [:]
    private var folderStatsByPath: [String: FolderStats] = [:]
    private var indexedDirectories: Set<String> = []
    private var activeTasks: [String: Task<Void, Never>] = [:]

    private let fm = FileManager()
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .isHiddenKey
    ]

    private init() {}

    // MARK: - Ingesting loaded items

    /// Ingests directory contents already read into memory and queues background subfolder indexing.
    func indexLoadedItems(_ items: [FileItem], in parent: String) {
        queue.sync {
            var childPaths: Set<String> = []
            for item in items {
                let entry = FileIndexEntry(
                    path: item.path,
                    name: item.name,
                    ext: item.ext,
                    size: item.size,
                    isDirectory: item.isDirectory,
                    isSymbolicLink: item.isSymbolicLink,
                    modified: item.modified,
                    created: item.created,
                    kind: item.kind,
                    isHidden: item.isHidden
                )
                self.entriesByPath[item.path] = entry
                childPaths.insert(item.path)
                if !item.ext.isEmpty {
                    self.pathsByExtension[item.ext, default: []].insert(item.path)
                }
            }
            self.pathsByDirectory[parent] = childPaths
            self.indexedDirectories.insert(parent)
        }

        // Background indexing of subfolders to calculate folder stats and index deeper items
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for item in items where item.opensAsFolder {
                self.indexDirectory(path: item.path, recursive: true, maxDepth: 4)
            }
        }
    }

    // MARK: - Folder Stats

    /// Returns folder statistics if cached; otherwise triggers background computation
    /// and performs a quick shallow scan if possible.
    func folderStats(for path: String) -> FolderStats? {
        let cached = queue.sync { folderStatsByPath[path] }
        if let cached { return cached }

        // Fast attempt: shallow scan with quick deadline (under 40ms)
        let fastStats = computeShallowStats(for: path, deadline: Date().addingTimeInterval(0.04))
        if let fast = fastStats {
            queue.sync {
                self.folderStatsByPath[path] = fast
            }
        }

        // Trigger deep background scan
        queueFolderIndexing(path: path)
        return fastStats
    }

    private func queueFolderIndexing(path: String) {
        let alreadyRunning = queue.sync { activeTasks[path] != nil }
        guard !alreadyRunning else { return }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.indexDirectory(path: path, recursive: true, maxDepth: 6)
            self.queue.sync {
                _ = self.activeTasks.removeValue(forKey: path)
            }
        }

        queue.sync {
            self.activeTasks[path] = task
        }
    }

    private func computeShallowStats(for path: String, deadline: Date) -> FolderStats? {
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Self.resourceKeys,
            options: []
        ) else { return nil }

        var totalSize: Int64 = 0
        var objectCount: Int = 0
        var maxModified: TimeInterval = 0

        for url in urls {
            if Date() > deadline { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { continue }
            objectCount += 1
            let mod = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if mod > maxModified { maxModified = mod }

            if values.isDirectory != true {
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        return FolderStats(totalSize: totalSize, objectCount: objectCount, lastModified: maxModified, isComplete: false)
    }

    // MARK: - Directory Indexing

    func indexDirectory(path: String, recursive: Bool = true, maxDepth: Int = 6) {
        var totalSize: Int64 = 0
        var objectCount: Int = 0
        var maxModified: TimeInterval = 0
        var subfolders: [String] = []

        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Self.resourceKeys,
            options: []
        ) else { return }

        var childPaths: Set<String> = []

        for url in urls {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { continue }
            let isDir = values.isDirectory ?? false
            let isLink = values.isSymbolicLink ?? false
            var size = Int64(values.fileSize ?? 0)
            if isLink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) {
                size = Int64(target.fileSize ?? 0)
            }
            let name = url.lastPathComponent
            let ext = isDir ? "" : url.pathExtension.lowercased()
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let created = values.creationDate?.timeIntervalSince1970 ?? modified
            let isHidden = name.hasPrefix(".") || (values.isHidden ?? false)
            let kind = FileKinds.classify(isDirectory: isDir, ext: ext, name: name)

            let entry = FileIndexEntry(
                path: url.path,
                name: name,
                ext: ext,
                size: isDir ? 0 : size,
                isDirectory: isDir,
                isSymbolicLink: isLink,
                modified: modified,
                created: created,
                kind: kind,
                isHidden: isHidden
            )

            queue.sync {
                self.entriesByPath[url.path] = entry
                childPaths.insert(url.path)
                if !ext.isEmpty {
                    self.pathsByExtension[ext, default: []].insert(url.path)
                }
            }

            objectCount += 1
            if modified > maxModified { maxModified = modified }

            if !isDir {
                totalSize += size
            } else if !isLink && kind != .app {
                subfolders.append(url.path)
            }
        }

        queue.sync {
            self.pathsByDirectory[path] = childPaths
            self.indexedDirectories.insert(path)
        }

        // Recursive crawl for subfolders
        if recursive && maxDepth > 0 {
            for subfolder in subfolders {
                if Task.isCancelled { break }
                indexDirectory(path: subfolder, recursive: true, maxDepth: maxDepth - 1)
                let subStats = queue.sync { self.folderStatsByPath[subfolder] }
                if let subStats {
                    totalSize += subStats.totalSize
                    objectCount += subStats.objectCount
                    if subStats.lastModified > maxModified { maxModified = subStats.lastModified }
                }
            }
        }

        let stats = FolderStats(
            totalSize: totalSize,
            objectCount: objectCount,
            lastModified: maxModified,
            isComplete: true
        )

        queue.sync {
            self.folderStatsByPath[path] = stats
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: FileTooltipHelper.folderStatsUpdated, object: path)
        }
    }

    // MARK: - Search

    /// Fast search using the index (matching filename, extension only, and size criteria),
    /// augmenting with live directory scanning when subtrees have not been fully indexed.
    func search(root: String, query: String, maxResults: Int = 500) async -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parsed = SearchQueryParser.parse(trimmed)
        var matchedPaths: Set<String> = []
        var results: [FileItem] = []

        // 1. Search in-memory index
        let (foundResults, isRootIndexed) = queue.sync { () -> ([FileItem], Bool) in
            var res: [FileItem] = []
            for (path, entry) in self.entriesByPath {
                guard path.hasPrefix(root) && path != root else { continue }
                if parsed.matches(entry: entry) {
                    matchedPaths.insert(path)
                    res.append(entry.toFileItem())
                    if res.count >= maxResults { break }
                }
            }
            return (res, self.indexedDirectories.contains(root))
        }

        results = foundResults

        if results.count >= maxResults || isRootIndexed {
            return results
        }

        // 2. Scan remaining disk hierarchy if root is not fully indexed
        let fallbackResults = await Task.detached(priority: .userInitiated) { () -> [FileItem] in
            var extra: [FileItem] = []
            var stack: [(dir: String, depth: Int)] = [(root, 0)]
            let deadline = Date().addingTimeInterval(6.0)

            while let (currentDir, depth) = stack.popLast() {
                if Task.isCancelled || Date() > deadline || (results.count + extra.count) >= maxResults { break }
                guard let urls = try? self.fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: currentDir, isDirectory: true),
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: []
                ) else { continue }

                for url in urls {
                    if (results.count + extra.count) >= maxResults { break }
                    if matchedPaths.contains(url.path) { continue }
                    guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { continue }

                    let isDir = values.isDirectory ?? false
                    let isLink = values.isSymbolicLink ?? false
                    var size = Int64(values.fileSize ?? 0)
                    if isLink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) {
                        size = Int64(target.fileSize ?? 0)
                    }
                    let name = url.lastPathComponent
                    let ext = isDir ? "" : url.pathExtension.lowercased()
                    let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let created = values.creationDate?.timeIntervalSince1970 ?? modified
                    let isHidden = name.hasPrefix(".") || (values.isHidden ?? false)
                    let kind = FileKinds.classify(isDirectory: isDir, ext: ext, name: name)

                    let entry = FileIndexEntry(
                        path: url.path,
                        name: name,
                        ext: ext,
                        size: isDir ? 0 : size,
                        isDirectory: isDir,
                        isSymbolicLink: isLink,
                        modified: modified,
                        created: created,
                        kind: kind,
                        isHidden: isHidden
                    )

                    // Ingest into index as we encounter it
                    self.queue.sync {
                        self.entriesByPath[url.path] = entry
                        if !ext.isEmpty { self.pathsByExtension[ext, default: []].insert(url.path) }
                    }

                    if parsed.matches(entry: entry) {
                        matchedPaths.insert(url.path)
                        extra.append(entry.toFileItem())
                    }

                    if isDir && !isLink && kind != .app && depth < 6 {
                        stack.append((url.path, depth + 1))
                    }
                }
            }
            return extra
        }.value

        results.append(contentsOf: fallbackResults)
        return results
    }

    // MARK: - Invalidation

    func removeEntry(at path: String) {
        queue.sync {
            if let entry = self.entriesByPath.removeValue(forKey: path) {
                if !entry.ext.isEmpty {
                    self.pathsByExtension[entry.ext]?.remove(path)
                }
            }
            self.folderStatsByPath.removeValue(forKey: path)
            self.indexedDirectories.remove(path)
        }
    }

    func invalidateFolderStats(for path: String) {
        queue.sync {
            self.folderStatsByPath.removeValue(forKey: path)
            self.indexedDirectories.remove(path)
        }
    }
}

// MARK: - Search Query Parser

private struct SearchQueryParser {
    let nameNeedles: [String]
    let requiredExtension: String?
    let minSize: Int64?
    let maxSize: Int64?

    static func parse(_ raw: String) -> SearchQueryParser {
        let tokens = raw.split(separator: " ").map(String.init)
        var needles: [String] = []
        var ext: String?
        var minS: Int64?
        var maxS: Int64?

        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("ext:") {
                ext = String(lower.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else if lower.hasPrefix(".") && lower.count > 1 {
                ext = String(lower.dropFirst(1))
            } else if lower.hasPrefix("*.") && lower.count > 2 {
                ext = String(lower.dropFirst(2))
            } else if lower.hasPrefix("size:>") || lower.hasPrefix(">") {
                let s = lower.replacingOccurrences(of: "size:>", with: "").replacingOccurrences(of: ">", with: "")
                if let b = parseBytes(s) { minS = b }
            } else if lower.hasPrefix("size:<") || lower.hasPrefix("<") {
                let s = lower.replacingOccurrences(of: "size:<", with: "").replacingOccurrences(of: "<", with: "")
                if let b = parseBytes(s) { maxS = b }
            } else {
                needles.append(token)
            }
        }

        return SearchQueryParser(
            nameNeedles: needles,
            requiredExtension: ext,
            minSize: minS,
            maxSize: maxS
        )
    }

    func matches(entry: FileIndexEntry) -> Bool {
        // 1. Extension match
        if let reqExt = requiredExtension {
            if entry.ext != reqExt { return false }
        }

        // 2. Size match
        if let min = minSize, entry.size < min { return false }
        if let max = maxSize, entry.size > max { return false }

        // 3. Filename match
        for needle in nameNeedles {
            if entry.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
               entry.ext.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return true
    }

    private static func parseBytes(_ string: String) -> Int64? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("gb") || trimmed.hasSuffix("g") {
            let num = trimmed.replacingOccurrences(of: "gb", with: "").replacingOccurrences(of: "g", with: "")
            if let d = Double(num) { return Int64(d * 1024 * 1024 * 1024) }
        } else if trimmed.hasSuffix("mb") || trimmed.hasSuffix("m") {
            let num = trimmed.replacingOccurrences(of: "mb", with: "").replacingOccurrences(of: "m", with: "")
            if let d = Double(num) { return Int64(d * 1024 * 1024) }
        } else if trimmed.hasSuffix("kb") || trimmed.hasSuffix("k") {
            let num = trimmed.replacingOccurrences(of: "kb", with: "").replacingOccurrences(of: "k", with: "")
            if let d = Double(num) { return Int64(d * 1024) }
        } else if trimmed.hasSuffix("b") {
            let num = trimmed.replacingOccurrences(of: "b", with: "")
            if let d = Double(num) { return Int64(d) }
        } else if let d = Double(trimmed) {
            return Int64(d)
        }
        return nil
    }
}
