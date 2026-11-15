import Foundation

// MARK: - Files

enum FileKind: String, Codable {
    case folder, drive, image, video, audio, document, pdf, spreadsheet, presentation
    case archive, code, text, executable, app, font, diskImage, file
}

/// A single file or directory entry. Value type, cheap to copy, no AppKit.
struct FileItem: Identifiable, Hashable {
    let name: String
    /// Absolute path.
    let path: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    /// Size in bytes (0 for directories).
    let size: Int64
    /// Seconds since 1970.
    let modified: TimeInterval
    let created: TimeInterval
    /// Lower-cased extension without the dot ("" for none / directories).
    let ext: String
    let isHidden: Bool
    let kind: FileKind

    var id: String { path }

    /// `.app` bundles are directories on disk but behave like files (they launch).
    var opensAsFolder: Bool { isDirectory && kind != .app }
}

// MARK: - Sidebar

enum QuickLinkIcon: String, Codable {
    case home, desktop, documents, downloads, pictures, music, videos, applications

    var symbol: String {
        switch self {
        case .home: return "house"
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc.text"
        case .downloads: return "arrow.down.circle"
        case .pictures: return "photo"
        case .music: return "music.note"
        case .videos: return "film"
        case .applications: return "square.grid.2x2"
        }
    }
}

struct QuickLink: Codable, Hashable {
    var name: String
    var path: String
    var icon: QuickLinkIcon
}

struct DriveItem: Hashable {
    let name: String
    let path: String
    let total: Int64?
    let free: Int64?
}

/// A user-made sidebar group holding folders or files of the user's choosing.
struct SidebarCategory: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var paths: [String]
    var collapsed: Bool
}

// MARK: - View settings

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case extraLarge = "extra-large", large, medium, small, list, details, tiles
    var id: String { rawValue }

    var title: String {
        switch self {
        case .extraLarge: return "Extra large icons"
        case .large: return "Large icons"
        case .medium: return "Medium icons"
        case .small: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        }
    }

    var symbol: String {
        switch self {
        case .extraLarge: return "square.grid.2x2.fill"
        case .large: return "square.grid.2x2"
        case .medium: return "square.grid.3x3"
        case .small: return "square.grid.3x3.fill"
        case .list: return "list.bullet"
        case .details: return "list.bullet.rectangle"
        case .tiles: return "rectangle.grid.1x2"
        }
    }
}

enum SortKey: String, Codable, CaseIterable, Identifiable {
    case name, modified, type, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

enum SortDirection: String, Codable {
    case ascending, descending
    var toggled: SortDirection { self == .ascending ? .descending : .ascending }
}

enum GroupKey: String, Codable, CaseIterable, Identifiable {
    case none, name, modified, type, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "(None)"
        case .name: return "Name"
        case .modified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

struct ItemSection: Identifiable {
    let label: String
    let items: [FileItem]
    var id: String { label }
}

// MARK: - Operations

enum ConflictPolicy: String {
    case replace, skip, keepBoth
}

enum OpKind: String {
    case copy, move, download, compress, extract

    var verb: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .download: return "Downloading"
        case .compress: return "Compressing"
        case .extract: return "Extracting"
        }
    }
}

struct OpProgress: Equatable {
    var op: OpKind
    var done: Int
    var total: Int
    var name: String
}

struct FileMove: Equatable {
    let from: String
    let to: String
}

struct TransferResult: Equatable {
    var moves: [FileMove]
}

/// A transfer waiting on the user to choose a conflict policy.
struct PendingTransfer: Identifiable {
    let id = UUID()
    let sources: [String]
    let destination: String
    let op: OpKind
    let conflicts: [String]
    let clearCut: Bool
}

/// A reversible operation for Undo (⌘Z, like Ctrl+Z in Windows Explorer).
enum UndoEntry {
    case rename(from: String, to: String)
    case move([FileMove])
    case copy(created: [String])
    case trash([FileMove])
}

// MARK: - Properties

struct PropertyInfo {
    let name: String
    let path: String
    let parent: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let symlinkTarget: String?
    let size: Int64
    let created: TimeInterval
    let modified: TimeInterval
    let accessed: TimeInterval
    /// "drwxr-xr-x"
    let mode: String
    let kind: FileKind
    let typeLabel: String
}

struct FolderSize: Equatable {
    var size: Int64
    var files: Int
    var folders: Int
    var complete: Bool
}

// MARK: - Cloud

enum CloudProvider: String, Codable {
    case dropbox, onedrive, googledrive, icloud, box, other

    var supportsWebLink: Bool { self == .dropbox || self == .onedrive }

    var displayName: String {
        switch self {
        case .dropbox: return "Dropbox"
        case .onedrive: return "OneDrive"
        case .googledrive: return "Google Drive"
        case .icloud: return "iCloud Drive"
        case .box: return "Box"
        case .other: return "the web"
        }
    }
}

struct CloudRoot: Hashable {
    let provider: CloudProvider
    let root: String
    let label: String
}

struct CloudInfo: Hashable {
    let provider: CloudProvider
    let label: String
    let root: String
    /// POSIX path inside the root; "" for the root itself.
    let relativePath: String
    /// True when the contents are a placeholder that is not downloaded yet.
    let dataless: Bool
}

// MARK: - Tabs & updates

struct Tab: Identifiable, Equatable, Codable {
    let id: UUID
    var history: [String]
    var index: Int

    init(path: String) {
        id = UUID()
        history = [path]
        index = 0
    }

    init(id: UUID = UUID(), history: [String], index: Int) {
        self.id = id
        self.history = history
        self.index = index
    }

    var path: String {
        guard index >= 0 && index < history.count else { return history.last ?? PathUtils.home }
        return history[index]
    }
}

enum UpdateState: Equatable {
    case checking(manual: Bool)
    case available(version: String, url: URL)
    case upToDate(manual: Bool)
    case failed(message: String, manual: Bool)
}

// MARK: - Errors

/// One error type for every file operation. Carries enough to let the UI offer
/// the Full Disk Access shortcut without parsing messages.
struct FileOpError: LocalizedError, Equatable {
    let message: String
    let isPermissionDenied: Bool

    var errorDescription: String? { message }

    init(_ message: String, permissionDenied: Bool = false) {
        self.message = message
        self.isPermissionDenied = permissionDenied
    }

    init(wrapping error: Error) {
        if let known = error as? FileOpError {
            self = known
            return
        }
        let ns = error as NSError
        self.init(ns.localizedDescription, permissionDenied: FileOpError.isPermission(ns))
    }

    private static func isPermission(_ error: NSError) -> Bool {
        let cocoa: Set<Int> = [
            CocoaError.fileReadNoPermission.rawValue,
            CocoaError.fileWriteNoPermission.rawValue
        ]
        if error.domain == NSCocoaErrorDomain && cocoa.contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermission(underlying)
        }
        return false
    }
}
