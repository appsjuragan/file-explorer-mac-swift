import SwiftUI

/// One Explorer window: tab strip, command bar, address bar, panes, status bar.
struct RootView: View {
    @StateObject private var model = ExplorerModel()
    @ObservedObject private var updates = UpdateController.shared
    @State private var fullScreen = false

    private var prefs: Prefs { model.prefs.value }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model, leadingInset: fullScreen ? 8 : 78)
            CommandBar(model: model)
            AddressBar(model: model)
            Divider()
            HStack(spacing: 0) {
                if model.navigationPaneOpen {
                    NavigationPane(model: model).frame(width: prefs.sidebarWidth)
                    ResizeHandle(value: prefs.sidebarWidth) { model.setSidebarWidth($0) }
                }
                ContentArea(model: model)
                if model.previewOpen {
                    ResizeHandle(value: prefs.previewWidth, invert: true) { model.setPreviewWidth($0) }
                    PreviewPane(model: model).frame(width: prefs.previewWidth)
                }
            }
            Divider()
            StatusBar(model: model)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor { window in configure(window) })
        .overlay(alignment: .bottomTrailing) { overlays.padding(16) }
        .sheet(item: $model.pendingTransfer) { ConflictSheet(model: model, transfer: $0) }
        .sheet(item: $model.propertiesTarget) { PropertiesSheet(model: model, path: $0.id) }
        .focusedSceneObject(model)
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === model.window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === model.window { fullScreen = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === model.window {
                WindowRegistry.shared.markActive(model)
                model.refreshClipboardStatus()
            }
        }
    }

    private var overlays: some View {
        VStack(alignment: .trailing, spacing: 10) {
            UpdateBanner(updates: updates)
            if let progress = model.operation { ProgressCard(progress: progress) }
            if let message = model.statusMessage, model.operation == nil { Toast(message: message) }
        }
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
    }

    private func configure(_ window: NSWindow) {
        guard model.window !== window else { return }
        model.window = window
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        fullScreen = window.styleMask.contains(.fullScreen)
        WindowRegistry.shared.register(model)
    }
}
