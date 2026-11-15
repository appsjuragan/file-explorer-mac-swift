import SwiftUI

@main
struct FileExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { ExplorerCommands() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateController.shared.checkOnLaunch()
        IconThemeManager.shared.ensureDefaultCustomTemplates()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        WindowRegistry.shared.saveAllSessions()
        AppPreferences.shared.flush()
    }

    /// Finder "Open With", the Dock, and `open -a`: each folder becomes a tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        WindowRegistry.shared.open(urls.filter(\.isFileURL).map(\.path))
    }
}
