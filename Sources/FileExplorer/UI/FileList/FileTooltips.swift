import AppKit
import UniformTypeIdentifiers

// MARK: - Tooltip text

enum FileTooltipHelper {
    static func tooltip(for item: FileItem) -> String {
        if item.opensAsFolder {
            let stats = FileIndexWorker.shared.folderStats(for: item.path)
            let more = stats?.isComplete == false ? "+" : ""
            let sizeText = stats.map { Formatting.bytes($0.totalSize) + more } ?? "Calculating..."
            let countText = stats.map { Formatting.grouped(Int64($0.objectCount)) + more } ?? "Calculating..."
            let dateText = Formatting.dateTime(max(stats?.lastModified ?? 0, item.modified))
            return """
            Total size: \(sizeText)
            Object count: \(countText)
            Date modified: \(dateText)
            """
        }
        return """
        Size: \(Formatting.bytes(item.size))
        Type: \(MimeTypeResolver.mimeType(for: item.ext))
        Date modified: \(Formatting.dateTime(item.modified))
        """
    }

    /// Lets list cells warm the folder-stats cache for rows that are actually on screen,
    /// so the tooltip usually has numbers by the time it appears.
    static func prefetch(for item: FileItem) {
        if item.opensAsFolder { FileIndexWorker.shared.prefetchStats(for: item.path) }
    }
}

// MARK: - Lazy tooltip registration

/// Supplies a view's tooltip only when AppKit is about to display it.
///
/// Assigning `NSView.toolTip` forces the string to be built up front, which for list cells
/// meant building every visible cell's tooltip (folder stats included) on every reload and
/// scroll. With an owner, AppKit asks for the text on hover, once.
/// The owning view keeps this object alive and calls `refresh()` from `layout()`.
@MainActor
final class LazyToolTip: NSObject, NSViewToolTipOwner {
    private weak var view: NSView?
    private var tag: NSView.ToolTipTag?
    private let text: () -> String?

    init(for view: NSView, text: @escaping () -> String?) {
        self.view = view
        self.text = text
        super.init()
    }

    /// Re-registers the tooltip rectangle for the view's current bounds.
    func refresh() {
        guard let view else { return }
        if let tag { view.removeToolTip(tag) }
        tag = view.bounds.isEmpty ? nil : view.addToolTip(view.bounds, owner: self, userData: nil)
    }

    /// AppKit asks on the main thread; `nonisolated` keeps the conformance valid whether or
    /// not the SDK marks this protocol as main-actor.
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                          userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { text() ?? "" }
    }
}

// MARK: - MIME types

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
