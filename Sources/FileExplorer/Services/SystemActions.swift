import AppKit
import UniformTypeIdentifiers

/// Thin wrappers over AppKit services (Workspace, Pasteboard, Sharing). Kept in one place
/// so the model stays testable and every OS call site is easy to audit.
@MainActor
enum SystemActions {
    // MARK: Opening

    /// Returns an error message when the file couldn't be opened.
    static func open(_ path: String) -> String? {
        NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? nil : "Couldn't open \"\(PathUtils.basename(path))\"."
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openInTerminal(_ directory: String) {
        let ws = NSWorkspace.shared
        guard let terminal = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        ws.open([URL(fileURLWithPath: directory, isDirectory: true)], withApplicationAt: terminal,
                configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Open with…": the user picks an application in a standard panel.
    static func openWith(_ path: String) async -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an application to open the file"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return nil }
        do {
            try await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                              configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openWeb(_ url: URL) { NSWorkspace.shared.open(url) }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Pasteboard (files)

    /// File URLs on the general pasteboard: Finder and other apps can paste them.
    static func writeFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }

    static func readFiles() -> [String] {
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.map(\.path) ?? []
    }

    static func clearPasteboard() { NSPasteboard.general.clearContents() }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Sharing

    static func sharingServices(for paths: [String]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: paths.map { URL(fileURLWithPath: $0) })
    }

    static func share(_ paths: [String], relativeTo view: NSView) {
        guard !paths.isEmpty else { return }
        NSSharingServicePicker(items: paths.map { URL(fileURLWithPath: $0) })
            .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
