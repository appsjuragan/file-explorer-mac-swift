import SwiftUI

/// Windows 11 Explorer command bar: New · Cut Copy Paste Rename Share Delete · Sort · View · Details · More.
struct CommandBar: View {
    @ObservedObject var model: ExplorerModel

    private var hasSelection: Bool { !model.selection.isEmpty }
    private var hasSingle: Bool { model.selection.count == 1 }
    private var inFolder: Bool { !model.isHome }

    var body: some View {
        HStack(spacing: 2) {
            newMenu
            BarSeparator()
            IconButton(symbol: "scissors", help: "Cut (⌘X)") { model.cutSelection() }.disabled(!hasSelection)
            IconButton(symbol: "doc.on.doc", help: "Copy (⌘C)") { model.copySelection() }.disabled(!hasSelection)
            IconButton(symbol: "doc.on.clipboard", help: "Paste (⌘V)") { model.paste() }.disabled(!model.canPaste)
            IconButton(symbol: "pencil", help: "Rename (F2)") { model.beginRename() }.disabled(!hasSingle)
            IconButton(symbol: "square.and.arrow.up", help: "Share") {
                if let view = model.window?.contentView { model.share(from: view) }
            }.disabled(!hasSelection)
            IconButton(symbol: "trash", help: "Delete (Del)") { model.deleteSelection() }.disabled(!hasSelection)
            BarSeparator()
            sortMenu
            viewMenu
            Spacer(minLength: 0)
            IconButton(symbol: "sidebar.right", help: "Details pane (⌥⇧P)") { model.togglePreview() }
                .background(model.previewOpen ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
            moreMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private var newMenu: some View {
        Menu {
            Button { model.createFolder() } label: { Label("Folder", systemImage: "folder.badge.plus") }
            Button { model.createTextFile() } label: { Label("Text Document", systemImage: "doc.badge.plus") }
        } label: {
            Label("New", systemImage: "plus.circle").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!inFolder || model.isSearchResults)
        .help("New")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortKey.allCases) { key in
                Button { if model.sortKey != key { model.setSort(key) } } label: {
                    if model.sortKey == key { Label(key.title, systemImage: "checkmark") } else { Text(key.title) }
                }
            }
            Divider()
            Button { model.setSortDirection(.ascending) } label: {
                if model.sortDirection == .ascending { Label("Ascending", systemImage: "checkmark") } else { Text("Ascending") }
            }
            Button { model.setSortDirection(.descending) } label: {
                if model.sortDirection == .descending { Label("Descending", systemImage: "checkmark") } else { Text("Descending") }
            }
            Divider()
            Menu("Group by") {
                ForEach(GroupKey.allCases) { key in
                    Button { model.setGroupBy(key) } label: {
                        if model.groupBy == key { Label(key.title, systemImage: "checkmark") } else { Text(key.title) }
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!inFolder)
        .help("Sort and group")
    }

    private var viewMenu: some View {
        Menu {
            ForEach(ViewMode.allCases) { mode in
                Button { model.setViewMode(mode) } label: {
                    if model.viewMode == mode { Label(mode.title, systemImage: "checkmark") } else { Label(mode.title, systemImage: mode.symbol) }
                }
            }
            Divider()
            Button { model.toggleNavigationPane() } label: {
                Label("Navigation pane", systemImage: model.navigationPaneOpen ? "checkmark" : "sidebar.left")
            }
            Button { model.togglePreview() } label: {
                Label("Details pane", systemImage: model.previewOpen ? "checkmark" : "sidebar.right")
            }
            Button { model.toggleShowHidden() } label: {
                Label("Hidden items", systemImage: model.showHidden ? "checkmark" : "eye")
            }
            Divider()
            Menu("Themes") {
                ForEach(IconThemeID.builtInCases) { theme in
                    Button {
                        model.setIconTheme(theme)
                    } label: {
                        if model.iconTheme == theme {
                            Label(theme.title, systemImage: "checkmark")
                        } else {
                            Text(theme.title)
                        }
                    }
                }
                if model.iconTheme == .custom {
                    Button {
                        model.setIconTheme(.custom)
                    } label: {
                        Label("Custom (\(model.customThemeName))", systemImage: "checkmark")
                    }
                }
                Divider()
                Button {
                    model.chooseCustomIconTheme()
                } label: {
                    Label("Choose Custom Icons Folder…", systemImage: "folder.badge.gearshape")
                }
                Button {
                    model.openCustomIconsFolder()
                } label: {
                    Label("Open Custom Icons Folder", systemImage: "arrow.up.forward.square")
                }
            }
            Divider()
            Button {
                model.toggleRestoreSession()
            } label: {
                if model.restoreSession {
                    Label("Restore previous session", systemImage: "checkmark")
                } else {
                    Text("Restore previous session")
                }
            }
        } label: {
            Label("View", systemImage: model.viewMode.symbol).font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!inFolder)
        .help("View")
    }

    private var moreMenu: some View {
        Menu {
            Button("Select all") { model.selectAll() }
            Button("Select none") { model.selectNone() }
            Button("Invert selection") { model.invertSelection() }
            Divider()
            Button("Compress to ZIP") { model.compressSelection() }.disabled(!hasSelection)
            Button("Extract all") { model.extractSelection() }.disabled(model.selectedItems.allSatisfy { $0.ext != "zip" })
            Divider()
            Button("Open in Terminal") { model.openTerminal() }.disabled(!inFolder)
            Button("Properties") { model.showProperties() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("See more")
    }
}
