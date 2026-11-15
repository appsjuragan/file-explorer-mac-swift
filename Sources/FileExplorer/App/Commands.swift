import SwiftUI

/// Menu bar, laid out to match Windows Explorer's commands with their macOS key equivalents.
/// ⌥-arrows and Backspace are handled in the list's `keyDown` so text editing keeps them.
struct ExplorerCommands: Commands {
    @FocusedObject private var model: ExplorerModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n")
            Button("New Tab") { model?.newTab() }.keyboardShortcut("t").disabled(model == nil)
            Divider()
            Button("New Folder") { model?.createFolder() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!inFolder)
            Button("New Text Document") { model?.createTextFile() }.disabled(!inFolder)
            Divider()
            Button("Open") { model?.openSelection() }.keyboardShortcut("o").disabled(!hasSelection)
            Button("Open With…") { model?.openWithSelection() }.disabled(!hasSelection)
            Button("Show in Finder") { model?.revealInFinder() }.disabled(!hasSelection)
            Button("Open in Terminal") { model?.openTerminal() }.keyboardShortcut("t", modifiers: [.command, .option]).disabled(!inFolder)
            Divider()
            Button("Properties") { model?.showProperties() }.keyboardShortcut("i").disabled(model == nil)
            Divider()
            Button("Close Tab") { closeTab() }.keyboardShortcut("w").disabled(model == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename") { model?.beginRename() }.disabled(model?.selection.count != 1)
            Button("Copy as Path") { model?.copyPaths() }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(!hasSelection)
            Divider()
            Button("Select None") { model?.selectNone() }.disabled(!hasSelection)
            Button("Invert Selection") { model?.invertSelection() }.disabled(model == nil)
        }

        CommandMenu("Go") {
            Button("Back") { model?.goBack() }.keyboardShortcut("[").disabled(!(model?.canGoBack ?? false))
            Button("Forward") { model?.goForward() }.keyboardShortcut("]").disabled(!(model?.canGoForward ?? false))
            Button("Up") { model?.goUp() }.keyboardShortcut(.upArrow).disabled(!(model?.canGoUp ?? false))
            Button("Home") { model?.goHome() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model == nil)
            Divider()
            Button("Address Bar") { model?.requestFocus(.address) }.keyboardShortcut("l").disabled(model == nil)
            Button("Search") { model?.requestFocus(.search) }.keyboardShortcut("f").disabled(model == nil)
            Divider()
            Button("Refresh") { model?.refresh() }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: []).disabled(model == nil)
        }

        CommandGroup(replacing: .sidebar) {
            ForEach(ViewMode.allCases) { mode in
                Button(mode.title) { model?.setViewMode(mode) }.disabled(model == nil)
            }
            Divider()
            Button("Navigation Pane") { model?.toggleNavigationPane() }.keyboardShortcut("b", modifiers: [.command, .option]).disabled(model == nil)
            Button("Details Pane") { model?.togglePreview() }.keyboardShortcut("p", modifiers: [.option, .shift]).disabled(model == nil)
            Button("Hidden Items") { model?.toggleShowHidden() }.keyboardShortcut(".", modifiers: [.command, .shift]).disabled(model == nil)
            Divider()
            Menu("Themes") {
                ForEach(IconThemeID.builtInCases) { theme in
                    Button {
                        model?.setIconTheme(theme)
                    } label: {
                        if model?.iconTheme == theme {
                            Text("✓ " + theme.title)
                        } else {
                            Text("    " + theme.title)
                        }
                    }
                }
                if model?.iconTheme == .custom {
                    Button {
                        model?.setIconTheme(.custom)
                    } label: {
                        Text("✓ Custom (\(model?.customThemeName ?? "Custom"))")
                    }
                }
                Divider()
                Button("Choose Custom Icons Folder…") {
                    model?.chooseCustomIconTheme()
                }
                Button("Open Custom Icons Folder") {
                    model?.openCustomIconsFolder()
                }
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateController.shared.check(manual: true) }
        }
    }

    private var hasSelection: Bool { !(model?.selection.isEmpty ?? true) }
    private var inFolder: Bool { model.map { !$0.isHome } ?? false }

    private func closeTab() {
        guard let model else { return }
        if model.tabs.count > 1 { model.closeTab(model.activeTabID) } else { model.window?.performClose(nil) }
    }
}
