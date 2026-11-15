import Foundation

/// Extension → coarse kind used for icons, the "Type" column and grouping.
enum FileKinds {
    private static let extensionMap: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func register(_ kind: FileKind, _ exts: [String]) { exts.forEach { map[$0] = kind } }
        register(.image, ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "tiff", "tif", "heic", "heif", "ico", "avif"])
        register(.video, ["mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v", "mpg", "mpeg", "3gp"])
        register(.audio, ["mp3", "wav", "flac", "aac", "ogg", "m4a", "wma", "aiff", "opus"])
        register(.pdf, ["pdf"])
        register(.document, ["doc", "docx", "odt", "rtf", "pages"])
        register(.spreadsheet, ["xls", "xlsx", "ods", "csv", "numbers"])
        register(.presentation, ["ppt", "pptx", "odp", "key"])
        register(.archive, ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "zst"])
        register(.diskImage, ["dmg", "iso", "img"])
        register(.code, [
            "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "html", "htm", "css", "scss", "less",
            "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "cc", "cs", "php", "swift",
            "sh", "bash", "zsh", "yml", "yaml", "toml", "xml", "sql", "lua", "r", "dart", "vue", "svelte"
        ])
        register(.text, ["txt", "md", "markdown", "log", "ini", "cfg", "conf", "env"])
        register(.font, ["ttf", "otf", "woff", "woff2", "eot"])
        register(.executable, ["exe", "msi", "bin", "run", "command"])
        return map
    }()

    static func classify(isDirectory: Bool, ext: String, name: String) -> FileKind {
        if isDirectory {
            return name.lowercased().hasSuffix(".app") ? .app : .folder
        }
        return extensionMap[ext] ?? .file
    }

    /// Explorer-style label for the "Type" column.
    static func label(kind: FileKind, ext: String) -> String {
        let up = ext.uppercased()
        switch kind {
        case .folder: return "File folder"
        case .drive: return "Local Disk"
        case .app: return "Application"
        case .image: return up.isEmpty ? "Image" : "\(up) Image"
        case .video: return up.isEmpty ? "Video" : "\(up) Video"
        case .audio: return up.isEmpty ? "Audio" : "\(up) Audio"
        case .pdf: return "PDF Document"
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .presentation: return "Presentation"
        case .archive: return "Archive"
        case .diskImage: return "Disk Image"
        case .code: return up.isEmpty ? "Code File" : "\(up) File"
        case .text: return up.isEmpty ? "Text Document" : "\(up) File"
        case .font: return "Font File"
        case .executable: return "Executable"
        case .file: return up.isEmpty ? "File" : "\(up) File"
        }
    }

    static func label(for item: FileItem) -> String { label(kind: item.kind, ext: item.ext) }

    /// Kinds worth asking Quick Look for a real thumbnail. Others use the type icon,
    /// which is far cheaper in a folder with thousands of documents.
    static let thumbnailKinds: Set<FileKind> = [.image, .video, .pdf]
}
