import AppKit
import UniformTypeIdentifiers

/// Manages icon themes (Windows, Mac, Ubuntu, Custom) rendered via vector SVG.
@MainActor
final class IconThemeManager: ObservableObject {
    static let shared = IconThemeManager()

    @Published private(set) var currentTheme: IconThemeID = .windows
    @Published private(set) var customThemePath: String?

    private let imageCache = NSCache<NSString, NSImage>()

    private init() {
        imageCache.countLimit = 300
        let prefs = AppPreferences.shared.value
        self.currentTheme = prefs.iconTheme
        self.customThemePath = prefs.customIconThemePath
    }

    func setTheme(_ theme: IconThemeID, customPath: String? = nil) {
        currentTheme = theme
        if let customPath { self.customThemePath = customPath }
        clearCache()
    }

    func clearCache() {
        imageCache.removeAllObjects()
    }

    // MARK: - Themed Icons

    func folderIcon(isOpen: Bool = false) -> NSImage {
        let key = "folder_\(isOpen ? "open" : "closed")"
        if let custom = customIcon(named: key) ?? customIcon(named: "folder") {
            return custom
        }
        return svgImage(named: key) {
            isOpen ? themeSVGs.folderOpen : themeSVGs.folder
        }
    }

    func driveIcon() -> NSImage {
        if let custom = customIcon(named: "drive") { return custom }
        return svgImage(named: "drive") { themeSVGs.drive }
    }

    func quickLinkIcon(name: String, icon: QuickLinkIcon) -> NSImage {
        let key = name.lowercased()
        if let custom = customIcon(named: key) { return custom }
        switch key {
        case "desktop": return svgImage(named: "desktop") { themeSVGs.desktop }
        case "documents", "document": return svgImage(named: "documents") { themeSVGs.documents }
        case "downloads", "download": return svgImage(named: "downloads") { themeSVGs.downloads }
        case "pictures", "picture", "photos", "photo": return svgImage(named: "pictures") { themeSVGs.pictures }
        case "music", "audio": return svgImage(named: "music") { themeSVGs.music }
        case "movies", "videos", "video": return svgImage(named: "videos") { themeSVGs.videos }
        case "home": return svgImage(named: "home") { themeSVGs.home }
        default:
            return folderIcon()
        }
    }

    func fileIcon(forExtension rawExt: String, kind: FileKind) -> NSImage {
        let ext = rawExt.lowercased()
        if !ext.isEmpty, let custom = customIcon(named: ext) { return custom }
        if let custom = customIcon(named: kindName(for: ext, kind: kind)) { return custom }

        let iconKey = kindName(for: ext, kind: kind)
        return svgImage(named: iconKey) {
            svgForKind(iconKey)
        }
    }

    private func kindName(for ext: String, kind: FileKind) -> String {
        switch ext {
        case "pdf": return "pdf"
        case "doc", "docx", "dot", "dotx", "rtf", "odt": return "doc"
        case "xls", "xlsx", "xlsm", "csv", "tsv", "ods": return "spreadsheet"
        case "ppt", "pptx", "pps", "odp", "key": return "presentation"
        case "zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz": return "archive"
        case "swift": return "swift"
        case "py", "pyw", "ipynb": return "python"
        case "json": return "json"
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "html", "css", "c", "cpp", "h", "rs", "go", "java", "sh", "sql", "xml", "yaml", "yml":
            return "code"
        case "txt", "md", "markdown", "log", "rst", "tex": return "text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "heic", "tiff": return "image"
        case "mp3", "wav", "m4a", "flac", "aac", "ogg", "wma", "aiff": return "audio"
        case "mp4", "mov", "mkv", "avi", "webm", "wmv", "flv", "m4v": return "video"
        case "dmg", "pkg", "iso", "exe", "msi", "bin": return "package"
        default:
            switch kind {
            case .document: return "text"
            case .image: return "image"
            case .audio: return "audio"
            case .video: return "video"
            case .archive: return "archive"
            case .code: return "code"
            default: return "file"
            }
        }
    }

    private func svgForKind(_ name: String) -> String {
        switch name {
        case "pdf": return themeSVGs.pdf
        case "doc": return themeSVGs.doc
        case "spreadsheet": return themeSVGs.spreadsheet
        case "presentation": return themeSVGs.presentation
        case "archive": return themeSVGs.archive
        case "swift": return themeSVGs.swift
        case "python": return themeSVGs.python
        case "json": return themeSVGs.json
        case "code": return themeSVGs.code
        case "text": return themeSVGs.text
        case "image": return themeSVGs.image
        case "audio": return themeSVGs.audio
        case "video": return themeSVGs.video
        case "package": return themeSVGs.package
        default: return themeSVGs.file
        }
    }

    // MARK: - Cache & SVG Render

    private func svgImage(named key: String, size: CGSize = CGSize(width: 48, height: 48), svgGenerator: () -> String) -> NSImage {
        let cacheKey = "\(currentTheme.rawValue):\(key)" as NSString
        if let hit = imageCache.object(forKey: cacheKey) { return hit }
        let svg = svgGenerator()
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else {
            return NSWorkspace.shared.icon(for: .folder)
        }
        image.size = size
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func customIcon(named name: String) -> NSImage? {
        guard currentTheme == .custom, let path = customThemePath, !path.isEmpty else { return nil }
        let fileURL = URL(fileURLWithPath: path).appendingPathComponent("\(name).svg")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let cacheKey = "custom:\(fileURL.path)" as NSString
        if let hit = imageCache.object(forKey: cacheKey) { return hit }
        guard let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) else { return nil }
        image.size = CGSize(width: 48, height: 48)
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private var themeSVGs: ThemeSVGSet {
        switch currentTheme {
        case .windows, .custom: return WindowsSVGs.set
        case .mac: return MacSVGs.set
        case .ubuntu: return UbuntuSVGs.set
        }
    }

    // MARK: - Custom Icons Folder Support

    func defaultCustomFolderURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FileExplorer/CustomIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func ensureDefaultCustomTemplates() {
        let folder = defaultCustomFolderURL()
        let fm = FileManager.default
        let readmeURL = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readmeURL.path) {
            let readme = """
            File Explorer Custom Icon Theme
            ===============================
            Place your custom SVG icon files in this directory.

            Supported file names:
              folder.svg          - Standard folder
              folder_open.svg     - Expanded folder
              drive.svg           - Hard drive / volumes
              desktop.svg         - Desktop folder
              documents.svg       - Documents folder
              downloads.svg       - Downloads folder
              pictures.svg        - Pictures folder
              music.svg           - Music folder
              videos.svg          - Videos folder
              home.svg            - Home page
              pdf.svg             - PDF files (.pdf)
              doc.svg             - Word / documents (.doc, .docx)
              spreadsheet.svg     - Excel / sheets (.xls, .xlsx, .csv)
              presentation.svg    - Presentations (.ppt, .pptx)
              archive.svg         - Archives (.zip, .tar, .gz, .7z)
              code.svg            - Code files (.js, .ts, .html, .py, etc.)
              swift.svg           - Swift files (.swift)
              python.svg          - Python files (.py)
              json.svg            - JSON files (.json)
              text.svg            - Plain text (.txt, .md)
              image.svg           - Image files (.png, .jpg)
              audio.svg           - Audio files (.mp3, .wav)
              video.svg           - Video files (.mp4, .mov)
              package.svg         - Installers / Apps (.dmg, .pkg, .exe)
              file.svg            - Generic files

            You can also add any custom extension directly:
              e.g. rust.svg, go.svg, java.svg, docker.svg, etc.
            """
            try? readme.write(to: readmeURL, atomically: true, encoding: .utf8)
        }

        let folderSVGURL = folder.appendingPathComponent("folder.svg")
        if !fm.fileExists(atPath: folderSVGURL.path) {
            try? WindowsSVGs.set.folder.write(to: folderSVGURL, atomically: true, encoding: .utf8)
        }
    }

    func chooseCustomFolder(window: NSWindow?, completion: @escaping (String?) -> Void) {
        ensureDefaultCustomTemplates()
        let panel = NSOpenPanel()
        panel.title = "Select Custom Icons Folder"
        panel.message = "Choose a directory containing custom .svg icons"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultCustomFolderURL()
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url.path) }
                else { completion(nil) }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
            else { completion(nil) }
        }
    }

    func openCustomFolder() {
        ensureDefaultCustomTemplates()
        let folder = customThemePath.map { URL(fileURLWithPath: $0) } ?? defaultCustomFolderURL()
        NSWorkspace.shared.open(folder)
    }
}

// MARK: - Theme SVG Definitions

struct ThemeSVGSet {
    let folder: String
    let folderOpen: String
    let drive: String
    let desktop: String
    let documents: String
    let downloads: String
    let pictures: String
    let music: String
    let videos: String
    let home: String
    let pdf: String
    let doc: String
    let spreadsheet: String
    let presentation: String
    let archive: String
    let code: String
    let swift: String
    let python: String
    let json: String
    let text: String
    let image: String
    let audio: String
    let video: String
    let package: String
    let file: String
}

// MARK: - Windows 11 Fluent SVGs

enum WindowsSVGs {
    static let set = ThemeSVGSet(
        folder: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="w_b" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#FFA826"/><stop offset="100%" stop-color="#E67E00"/></linearGradient>
            <linearGradient id="w_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#FFD147"/><stop offset="100%" stop-color="#FFA000"/></linearGradient>
            <linearGradient id="w_s" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#40B0FF"/><stop offset="100%" stop-color="#0078D4"/></linearGradient>
          </defs>
          <path d="M4 10a4 4 0 0 1 4-4h11l4 4h17a4 4 0 0 1 4 4v22a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V10z" fill="url(#w_b)"/>
          <rect x="8" y="11" width="32" height="18" rx="2" fill="url(#w_s)" opacity="0.9"/>
          <path d="M4 16a3 3 0 0 1 3-3h34a3 3 0 0 1 3 3v20a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V16z" fill="url(#w_f)"/>
        </svg>
        """,
        folderOpen: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="wo_b" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#FFA826"/><stop offset="100%" stop-color="#E67E00"/></linearGradient>
            <linearGradient id="wo_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#FFD54F"/><stop offset="100%" stop-color="#FFB300"/></linearGradient>
          </defs>
          <path d="M4 10a4 4 0 0 1 4-4h11l4 4h17a4 4 0 0 1 4 4v22a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V10z" fill="url(#wo_b)"/>
          <rect x="10" y="11" width="28" height="16" rx="2" fill="#ffffff" opacity="0.95"/>
          <rect x="14" y="14" width="20" height="2" rx="1" fill="#90CAF9"/>
          <rect x="14" y="18" width="14" height="2" rx="1" fill="#90CAF9"/>
          <path d="M3 22a2 2 0 0 1 2-1.7h38a2 2 0 0 1 2 2.3l-3 15a4 4 0 0 1-4 3.4H7a4 4 0 0 1-4-3.4L3 22z" fill="url(#wo_f)"/>
        </svg>
        """,
        drive: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="12" width="36" height="24" rx="4" fill="#CFD8DC"/>
          <rect x="8" y="14" width="32" height="20" rx="3" fill="#ECEFF1"/>
          <circle cx="34" cy="24" r="2.5" fill="#0078D4"/>
          <rect x="12" y="22" width="14" height="4" rx="1" fill="#90A4AE"/>
        </svg>
        """,
        desktop: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="4" y="8" width="40" height="26" rx="3" fill="#263238"/>
          <rect x="6" y="10" width="36" height="22" rx="2" fill="#0078D4"/>
          <path d="M18 34h12l2 6H16l2-6z" fill="#78909C"/>
          <rect x="14" y="40" width="20" height="2" rx="1" fill="#546E7A"/>
        </svg>
        """,
        documents: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 6a4 4 0 0 1 4-4h14l12 12v28a4 4 0 0 1-4 4H14a4 4 0 0 1-4-4V6z" fill="#0078D4"/>
          <path d="M28 2v12h12" fill="#005A9E"/>
          <rect x="16" y="20" width="18" height="3" rx="1.5" fill="#ffffff" opacity="0.9"/>
          <rect x="16" y="26" width="16" height="3" rx="1.5" fill="#ffffff" opacity="0.9"/>
          <rect x="16" y="32" width="12" height="3" rx="1.5" fill="#ffffff" opacity="0.9"/>
        </svg>
        """,
        downloads: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M4 10a4 4 0 0 1 4-4h11l4 4h17a4 4 0 0 1 4 4v22a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V10z" fill="#00897B"/>
          <path d="M4 16a3 3 0 0 1 3-3h34a3 3 0 0 1 3 3v20a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V16z" fill="#26A69A"/>
          <circle cx="24" cy="27" r="7" fill="#ffffff"/>
          <path d="M24 23v8m-3-3l3 3 3-3" stroke="#00897B" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
        </svg>
        """,
        pictures: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="4" fill="#673AB7"/>
          <circle cx="16" cy="18" r="4" fill="#FFEB3B"/>
          <path d="M6 34l10-10 6 6 8-10 12 14v2a4 4 0 0 1-4 4H10a4 4 0 0 1-4-4v-2z" fill="#512DA8"/>
        </svg>
        """,
        music: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="4" fill="#E91E63"/>
          <circle cx="18" cy="30" r="4" fill="#ffffff"/>
          <circle cx="30" cy="26" r="4" fill="#ffffff"/>
          <path d="M22 30V16l12-3v13" stroke="#ffffff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
        </svg>
        """,
        videos: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="4" fill="#3F51B5"/>
          <polygon points="20,18 32,24 20,30" fill="#ffffff"/>
        </svg>
        """,
        home: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M24 6l-18 16h6v18h10v-10h4v10h10V22h6L24 6z" fill="#0078D4"/>
        </svg>
        """,
        pdf: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#E53935"/>
          <path d="M28 4v12h14" fill="#B71C1C" opacity="0.6"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#E53935" text-anchor="middle">PDF</text>
        </svg>
        """,
        doc: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#185ABD"/>
          <path d="M28 4v12h14" fill="#0E3A7E"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#185ABD" text-anchor="middle">DOC</text>
        </svg>
        """,
        spreadsheet: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#107C41"/>
          <path d="M28 4v12h14" fill="#0B522B"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#107C41" text-anchor="middle">XLS</text>
        </svg>
        """,
        presentation: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#D83B01"/>
          <path d="M28 4v12h14" fill="#9E2A00"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#D83B01" text-anchor="middle">PPT</text>
        </svg>
        """,
        archive: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#F57C00"/>
          <path d="M28 4v12h14" fill="#E65100"/>
          <rect x="22" y="14" width="4" height="24" fill="#37474F"/>
          <rect x="20" y="16" width="3" height="3" fill="#ECEFF1"/>
          <rect x="25" y="20" width="3" height="3" fill="#ECEFF1"/>
          <rect x="20" y="24" width="3" height="3" fill="#ECEFF1"/>
          <rect x="25" y="28" width="3" height="3" fill="#ECEFF1"/>
          <rect x="21" y="32" width="6" height="6" rx="1" fill="#ECEFF1"/>
        </svg>
        """,
        code: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#0066B8"/>
          <path d="M28 4v12h14" fill="#004D8C"/>
          <text x="24" y="32" font-family="monospace" font-size="14" font-weight="bold" fill="#ffffff" text-anchor="middle">&lt;/&gt;</text>
        </svg>
        """,
        swift: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#F05138"/>
          <path d="M28 4v12h14" fill="#C23824"/>
          <text x="24" y="32" font-family="system-ui, sans-serif" font-size="11" font-weight="bold" fill="#ffffff" text-anchor="middle">SWIFT</text>
        </svg>
        """,
        python: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#306998"/>
          <path d="M28 4v12h14" fill="#1E415E"/>
          <text x="24" y="32" font-family="system-ui, sans-serif" font-size="12" font-weight="bold" fill="#FFD43B" text-anchor="middle">PY</text>
        </svg>
        """,
        json: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#0288D1"/>
          <path d="M28 4v12h14" fill="#01579B"/>
          <text x="24" y="32" font-family="monospace" font-size="14" font-weight="bold" fill="#E1F5FE" text-anchor="middle">{ }</text>
        </svg>
        """,
        text: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 5.5a4 4 0 0 0-4 4v31a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V17.5L28 5.5H10z" fill="#000000" opacity="0.12"/>
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#ffffff" stroke="#90A4AE" stroke-width="1.2"/>
          <path d="M28 4v12h14" fill="#CFD8DC" stroke="#90A4AE" stroke-width="1.2" stroke-linejoin="round"/>
          <rect x="13" y="21" width="22" height="2.5" rx="1.25" fill="#0078D4"/>
          <rect x="13" y="26" width="22" height="2.5" rx="1.25" fill="#455A64"/>
          <rect x="13" y="31" width="16" height="2.5" rx="1.25" fill="#455A64"/>
          <rect x="13" y="36" width="10" height="2.5" rx="1.25" fill="#78909C"/>
        </svg>
        """,
        image: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#7B1FA2"/>
          <path d="M28 4v12h14" fill="#4A148C"/>
          <circle cx="18" cy="24" r="3" fill="#E1BEE7"/>
          <path d="M12 36l8-8 5 5 5-6 6 9H12z" fill="#E1BEE7"/>
        </svg>
        """,
        audio: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#E91E63"/>
          <path d="M28 4v12h14" fill="#AD1457"/>
          <circle cx="20" cy="32" r="3.5" fill="#ffffff"/>
          <path d="M23.5 32V20l8-2v11" stroke="#ffffff" stroke-width="2.5" stroke-linecap="round" fill="none"/>
        </svg>
        """,
        video: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#5E35B1"/>
          <path d="M28 4v12h14" fill="#311B92"/>
          <polygon points="21,22 30,27 21,32" fill="#EDE7F6"/>
        </svg>
        """,
        package: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#455A64"/>
          <path d="M28 4v12h14" fill="#263238"/>
          <rect x="16" y="22" width="16" height="14" rx="2" fill="#ECEFF1"/>
          <path d="M24 22v14" stroke="#78909C" stroke-width="2"/>
        </svg>
        """,
        file: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 5.5a4 4 0 0 0-4 4v31a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V17.5L28 5.5H10z" fill="#000000" opacity="0.12"/>
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#ffffff" stroke="#90A4AE" stroke-width="1.2"/>
          <path d="M28 4v12h14" fill="#CFD8DC" stroke="#90A4AE" stroke-width="1.2" stroke-linejoin="round"/>
        </svg>
        """
    )
}

// MARK: - Mac (macOS) SVGs

enum MacSVGs {
    static let set = ThemeSVGSet(
        folder: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="m_b" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#1976D2"/><stop offset="100%" stop-color="#0D47A1"/></linearGradient>
            <linearGradient id="m_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#42A5F5"/><stop offset="100%" stop-color="#1E88E5"/></linearGradient>
          </defs>
          <path d="M4 12a4 4 0 0 1 4-4h10l4 4h18a4 4 0 0 1 4 4v20a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V12z" fill="url(#m_b)"/>
          <rect x="4" y="16" width="40" height="24" rx="4" fill="url(#m_f)"/>
          <rect x="4" y="37" width="40" height="3" rx="1.5" fill="#1565C0" opacity="0.4"/>
        </svg>
        """,
        folderOpen: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="mo_b" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#1976D2"/><stop offset="100%" stop-color="#0D47A1"/></linearGradient>
            <linearGradient id="mo_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#64B5F6"/><stop offset="100%" stop-color="#2196F3"/></linearGradient>
          </defs>
          <path d="M4 12a4 4 0 0 1 4-4h10l4 4h18a4 4 0 0 1 4 4v20a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V12z" fill="url(#mo_b)"/>
          <rect x="8" y="10" width="32" height="18" rx="2" fill="#ffffff" opacity="0.95"/>
          <path d="M3 21a2 2 0 0 1 2-1.6h38a2 2 0 0 1 2 2.2l-3 15a4 4 0 0 1-4 3.4H7a4 4 0 0 1-4-3.4L3 21z" fill="url(#mo_f)"/>
        </svg>
        """,
        drive: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="8" y="12" width="32" height="24" rx="3" fill="#B0BEC5"/>
          <rect x="10" y="14" width="28" height="20" rx="2" fill="#ECEFF1"/>
          <circle cx="34" cy="24" r="2" fill="#00E676"/>
          <rect x="14" y="23" width="12" height="2" rx="1" fill="#78909C"/>
        </svg>
        """,
        desktop: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="5" y="8" width="38" height="26" rx="4" fill="#37474F"/>
          <rect x="7" y="10" width="34" height="20" rx="2" fill="#0288D1"/>
          <rect x="5" y="30" width="38" height="4" rx="1" fill="#CFD8DC"/>
          <path d="M19 34h10l1 7H18l1-7z" fill="#B0BEC5"/>
          <rect x="14" y="41" width="20" height="2" rx="1" fill="#90A4AE"/>
        </svg>
        """,
        documents: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#CFD8DC"/>
          <rect x="14" y="22" width="20" height="2.5" rx="1" fill="#0288D1"/>
          <rect x="14" y="28" width="16" height="2.5" rx="1" fill="#B0BEC5"/>
          <rect x="14" y="34" width="12" height="2.5" rx="1" fill="#B0BEC5"/>
        </svg>
        """,
        downloads: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="md_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#42A5F5"/><stop offset="100%" stop-color="#1E88E5"/></linearGradient>
          </defs>
          <path d="M4 12a4 4 0 0 1 4-4h10l4 4h18a4 4 0 0 1 4 4v20a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V12z" fill="#1565C0"/>
          <rect x="4" y="16" width="40" height="24" rx="4" fill="url(#md_f)"/>
          <circle cx="24" cy="27" r="7" fill="#ffffff"/>
          <path d="M24 23v8m-3-3l3 3 3-3" stroke="#1565C0" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
        </svg>
        """,
        pictures: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="5" fill="#E0F7FA"/>
          <circle cx="24" cy="24" r="10" fill="#00BCD4"/>
          <circle cx="24" cy="24" r="6" fill="#FFEB3B"/>
        </svg>
        """,
        music: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="5" fill="#FA2D48"/>
          <circle cx="18" cy="30" r="4" fill="#ffffff"/>
          <circle cx="30" cy="26" r="4" fill="#ffffff"/>
          <path d="M22 30V16l12-3v13" stroke="#ffffff" stroke-width="3" stroke-linecap="round" fill="none"/>
        </svg>
        """,
        videos: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="5" fill="#1C1C1E"/>
          <polygon points="20,18 32,24 20,30" fill="#0A84FF"/>
        </svg>
        """,
        home: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M24 6l-18 16h6v18h10v-10h4v10h10V22h6L24 6z" fill="#007AFF"/>
        </svg>
        """,
        pdf: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#E53935"/>
          <rect x="7" y="24" width="34" height="12" fill="#E53935"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#ffffff" text-anchor="middle">PDF</text>
        </svg>
        """,
        doc: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#007AFF"/>
          <rect x="7" y="24" width="34" height="12" fill="#007AFF"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#ffffff" text-anchor="middle">DOC</text>
        </svg>
        """,
        spreadsheet: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#34C759"/>
          <rect x="7" y="24" width="34" height="12" fill="#34C759"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#ffffff" text-anchor="middle">XLS</text>
        </svg>
        """,
        presentation: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#FF9500"/>
          <rect x="7" y="24" width="34" height="12" fill="#FF9500"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#ffffff" text-anchor="middle">KEY</text>
        </svg>
        """,
        archive: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#B0BEC5"/>
          <rect x="22" y="14" width="4" height="24" fill="#37474F"/>
          <rect x="20" y="17" width="3" height="3" fill="#ECEFF1"/>
          <rect x="25" y="22" width="3" height="3" fill="#ECEFF1"/>
          <rect x="21" y="28" width="6" height="7" rx="1" fill="#78909C"/>
        </svg>
        """,
        code: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#1C1C1E"/>
          <path d="M29 4v12h12" fill="#3A3A3C"/>
          <text x="24" y="32" font-family="monospace" font-size="14" font-weight="bold" fill="#0A84FF" text-anchor="middle">&lt;/&gt;</text>
        </svg>
        """,
        swift: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#F05138"/>
          <path d="M29 4v12h12" fill="#D33A23"/>
          <text x="24" y="32" font-family="system-ui, sans-serif" font-size="11" font-weight="bold" fill="#ffffff" text-anchor="middle">SWIFT</text>
        </svg>
        """,
        python: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#306998"/>
          <text x="24" y="32" font-family="system-ui, sans-serif" font-size="12" font-weight="bold" fill="#306998" text-anchor="middle">PY</text>
        </svg>
        """,
        json: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#007AFF"/>
          <text x="24" y="32" font-family="monospace" font-size="14" font-weight="bold" fill="#007AFF" text-anchor="middle">{ }</text>
        </svg>
        """,
        text: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 5.5a3 3 0 0 0-3 3v33a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V17.5L29 5.5H10z" fill="#000000" opacity="0.12"/>
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff" stroke="#C7C7CC" stroke-width="1.2"/>
          <path d="M29 4v12h12" fill="#E5E5EA" stroke="#C7C7CC" stroke-width="1.2" stroke-linejoin="round"/>
          <rect x="13" y="22" width="22" height="2.5" rx="1.25" fill="#007AFF"/>
          <rect x="13" y="27" width="22" height="2.5" rx="1.25" fill="#48484A"/>
          <rect x="13" y="32" width="16" height="2.5" rx="1.25" fill="#48484A"/>
          <rect x="13" y="37" width="10" height="2.5" rx="1.25" fill="#8E8E93"/>
        </svg>
        """,
        image: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#AF52DE"/>
          <circle cx="18" cy="24" r="3" fill="#AF52DE"/>
          <path d="M12 36l8-8 5 5 5-6 6 9H12z" fill="#AF52DE"/>
        </svg>
        """,
        audio: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#FA2D48"/>
          <circle cx="20" cy="32" r="3.5" fill="#FA2D48"/>
          <path d="M23.5 32V20l8-2v11" stroke="#FA2D48" stroke-width="2.5" stroke-linecap="round" fill="none"/>
        </svg>
        """,
        video: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff"/>
          <path d="M29 4v12h12" fill="#5856D6"/>
          <polygon points="21,22 30,27 21,32" fill="#5856D6"/>
        </svg>
        """,
        package: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="8" y="10" width="32" height="30" rx="3" fill="#F4B400"/>
          <path d="M8 20h32M24 10v30" stroke="#E37400" stroke-width="3"/>
          <rect x="18" y="16" width="12" height="8" rx="1" fill="#ffffff" opacity="0.8"/>
        </svg>
        """,
        file: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 5.5a3 3 0 0 0-3 3v33a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V17.5L29 5.5H10z" fill="#000000" opacity="0.12"/>
          <path d="M10 4a3 3 0 0 0-3 3v34a3 3 0 0 0 3 3h28a3 3 0 0 0 3-3V16L29 4H10z" fill="#ffffff" stroke="#C7C7CC" stroke-width="1.2"/>
          <path d="M29 4v12h12" fill="#E5E5EA" stroke="#C7C7CC" stroke-width="1.2" stroke-linejoin="round"/>
        </svg>
        """
    )
}

// MARK: - Ubuntu (Yaru) SVGs

enum UbuntuSVGs {
    static let set = ThemeSVGSet(
        folder: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="u_b" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#77216F"/><stop offset="100%" stop-color="#5E2750"/></linearGradient>
            <linearGradient id="u_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#FF6332"/><stop offset="100%" stop-color="#E95420"/></linearGradient>
          </defs>
          <path d="M4 11a4 4 0 0 1 4-4h11l4 4h17a4 4 0 0 1 4 4v21a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V11z" fill="url(#u_b)"/>
          <path d="M4 17a3 3 0 0 1 3-3h34a3 3 0 0 1 3 3v19a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V17z" fill="url(#u_f)"/>
        </svg>
        """,
        folderOpen: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <defs>
            <linearGradient id="uo_b" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#77216F"/><stop offset="100%" stop-color="#5E2750"/></linearGradient>
            <linearGradient id="uo_f" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#FF7547"/><stop offset="100%" stop-color="#E95420"/></linearGradient>
          </defs>
          <path d="M4 11a4 4 0 0 1 4-4h11l4 4h17a4 4 0 0 1 4 4v21a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V11z" fill="url(#uo_b)"/>
          <rect x="8" y="10" width="32" height="18" rx="2" fill="#ffffff" opacity="0.95"/>
          <path d="M3 21a2 2 0 0 1 2-1.6h38a2 2 0 0 1 2 2.2l-3 15a4 4 0 0 1-4 3.4H7a4 4 0 0 1-4-3.4L3 21z" fill="url(#uo_f)"/>
        </svg>
        """,
        drive: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="12" width="36" height="24" rx="4" fill="#333333"/>
          <rect x="8" y="14" width="32" height="20" rx="3" fill="#444444"/>
          <circle cx="34" cy="24" r="2.5" fill="#E95420"/>
          <rect x="12" y="22" width="14" height="4" rx="1" fill="#77216F"/>
        </svg>
        """,
        desktop: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="4" y="8" width="40" height="26" rx="3" fill="#2C001E"/>
          <rect x="6" y="10" width="36" height="22" rx="2" fill="#77216F"/>
          <path d="M18 34h12l2 6H16l2-6z" fill="#444444"/>
          <rect x="14" y="40" width="20" height="2" rx="1" fill="#333333"/>
        </svg>
        """,
        documents: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#E95420"/>
          <path d="M28 4v12h14" fill="#C34113"/>
          <rect x="14" y="22" width="20" height="3" rx="1.5" fill="#ffffff"/>
          <rect x="14" y="28" width="16" height="3" rx="1.5" fill="#ffffff"/>
          <rect x="14" y="34" width="12" height="3" rx="1.5" fill="#ffffff"/>
        </svg>
        """,
        downloads: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M4 11a4 4 0 0 1 4-4h11l4 4h17a4 4 0 0 1 4 4v21a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V11z" fill="#77216F"/>
          <path d="M4 17a3 3 0 0 1 3-3h34a3 3 0 0 1 3 3v19a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V17z" fill="#E95420"/>
          <circle cx="24" cy="27" r="7" fill="#ffffff"/>
          <path d="M24 23v8m-3-3l3 3 3-3" stroke="#E95420" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
        </svg>
        """,
        pictures: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="4" fill="#E95420"/>
          <circle cx="16" cy="18" r="4" fill="#FFD54F"/>
          <path d="M6 34l10-10 6 6 8-10 12 14v2a4 4 0 0 1-4 4H10a4 4 0 0 1-4-4v-2z" fill="#77216F"/>
        </svg>
        """,
        music: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="4" fill="#77216F"/>
          <circle cx="18" cy="30" r="4" fill="#ffffff"/>
          <circle cx="30" cy="26" r="4" fill="#ffffff"/>
          <path d="M22 30V16l12-3v13" stroke="#ffffff" stroke-width="3" stroke-linecap="round" fill="none"/>
        </svg>
        """,
        videos: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="6" y="8" width="36" height="32" rx="4" fill="#2C001E"/>
          <polygon points="20,18 32,24 20,30" fill="#E95420"/>
        </svg>
        """,
        home: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M24 6l-18 16h6v18h10v-10h4v10h10V22h6L24 6z" fill="#E95420"/>
        </svg>
        """,
        pdf: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#DF382C"/>
          <path d="M28 4v12h14" fill="#A82319"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#DF382C" text-anchor="middle">PDF</text>
        </svg>
        """,
        doc: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#1976D2"/>
          <path d="M28 4v12h14" fill="#0D47A1"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#1976D2" text-anchor="middle">ODT</text>
        </svg>
        """,
        spreadsheet: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#388E3C"/>
          <path d="M28 4v12h14" fill="#1B5E20"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#388E3C" text-anchor="middle">ODS</text>
        </svg>
        """,
        presentation: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#E95420"/>
          <path d="M28 4v12h14" fill="#BF360C"/>
          <rect x="10" y="24" width="28" height="12" rx="2" fill="#ffffff"/>
          <text x="24" y="33" font-family="system-ui, sans-serif" font-size="9" font-weight="bold" fill="#E95420" text-anchor="middle">ODP</text>
        </svg>
        """,
        archive: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#77216F"/>
          <path d="M28 4v12h14" fill="#5E2750"/>
          <rect x="22" y="14" width="4" height="24" fill="#E95420"/>
          <rect x="20" y="17" width="3" height="3" fill="#ffffff"/>
          <rect x="25" y="22" width="3" height="3" fill="#ffffff"/>
          <rect x="21" y="28" width="6" height="7" rx="1" fill="#FFD54F"/>
        </svg>
        """,
        code: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#300A24"/>
          <path d="M28 4v12h14" fill="#4E1A3D"/>
          <text x="24" y="32" font-family="monospace" font-size="14" font-weight="bold" fill="#4E9A06" text-anchor="middle">&gt;_</text>
        </svg>
        """,
        swift: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#E95420"/>
          <path d="M28 4v12h14" fill="#BF360C"/>
          <text x="24" y="32" font-family="system-ui, sans-serif" font-size="11" font-weight="bold" fill="#ffffff" text-anchor="middle">SWIFT</text>
        </svg>
        """,
        python: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#306998"/>
          <path d="M28 4v12h14" fill="#1E415E"/>
          <text x="24" y="32" font-family="system-ui, sans-serif" font-size="12" font-weight="bold" fill="#FFD43B" text-anchor="middle">PY</text>
        </svg>
        """,
        json: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#77216F"/>
          <path d="M28 4v12h14" fill="#5E2750"/>
          <text x="24" y="32" font-family="monospace" font-size="14" font-weight="bold" fill="#FFD54F" text-anchor="middle">{ }</text>
        </svg>
        """,
        text: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 5.5a4 4 0 0 0-4 4v31a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V17.5L28 5.5H10z" fill="#000000" opacity="0.12"/>
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#ffffff" stroke="#BDBDBD" stroke-width="1.2"/>
          <path d="M28 4v12h14" fill="#E0E0E0" stroke="#BDBDBD" stroke-width="1.2" stroke-linejoin="round"/>
          <rect x="13" y="21" width="22" height="2.5" rx="1.25" fill="#E95420"/>
          <rect x="13" y="26" width="22" height="2.5" rx="1.25" fill="#424242"/>
          <rect x="13" y="31" width="16" height="2.5" rx="1.25" fill="#424242"/>
          <rect x="13" y="36" width="10" height="2.5" rx="1.25" fill="#757575"/>
        </svg>
        """,
        image: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#77216F"/>
          <path d="M28 4v12h14" fill="#5E2750"/>
          <circle cx="18" cy="24" r="3" fill="#FFD54F"/>
          <path d="M12 36l8-8 5 5 5-6 6 9H12z" fill="#FFD54F"/>
        </svg>
        """,
        audio: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#E95420"/>
          <path d="M28 4v12h14" fill="#BF360C"/>
          <circle cx="20" cy="32" r="3.5" fill="#ffffff"/>
          <path d="M23.5 32V20l8-2v11" stroke="#ffffff" stroke-width="2.5" stroke-linecap="round" fill="none"/>
        </svg>
        """,
        video: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#2C001E"/>
          <path d="M28 4v12h14" fill="#4E1A3D"/>
          <polygon points="21,22 30,27 21,32" fill="#E95420"/>
        </svg>
        """,
        package: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <rect x="8" y="10" width="32" height="30" rx="3" fill="#E95420"/>
          <path d="M8 20h32M24 10v30" stroke="#77216F" stroke-width="3"/>
          <circle cx="24" cy="25" r="4" fill="#ffffff"/>
        </svg>
        """,
        file: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
          <path d="M10 5.5a4 4 0 0 0-4 4v31a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V17.5L28 5.5H10z" fill="#000000" opacity="0.12"/>
          <path d="M10 4a4 4 0 0 0-4 4v32a4 4 0 0 0 4 4h28a4 4 0 0 0 4-4V16L28 4H10z" fill="#ffffff" stroke="#BDBDBD" stroke-width="1.2"/>
          <path d="M28 4v12h14" fill="#E0E0E0" stroke="#BDBDBD" stroke-width="1.2" stroke-linejoin="round"/>
        </svg>
        """
    )
}
