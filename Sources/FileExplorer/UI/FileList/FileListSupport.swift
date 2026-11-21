import AppKit

// MARK: - Host view (responder-chain actions)

/// Wraps a list control and owns the standard Edit-menu actions. Because the control sits
/// below this view in the responder chain, ⌘C/⌘X/⌘V/⌫ reach the file model only when the
/// list has focus — a text field being edited keeps its own copy/paste.
@MainActor
final class FileListHostView: NSView, NSMenuItemValidation {
    let model: ExplorerModel

    init(model: ExplorerModel, content: NSView) {
        self.model = model
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func copy(_ sender: Any?) { model.copySelection() }
    @objc func cut(_ sender: Any?) { model.cutSelection() }
    @objc func paste(_ sender: Any?) { model.paste() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }
    /// ⌘Z while the list has focus undoes the last file operation (Ctrl+Z in Windows Explorer).
    @objc func undo(_ sender: Any?) { model.undo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return !model.selection.isEmpty
        case #selector(paste(_:)):
            return model.canPaste
        case #selector(undo(_:)):
            return !model.undoStack.isEmpty
        default:
            return true
        }
    }
}

/// Lets menu commands ask "is a file list focused?" without knowing which control it is.
protocol FileListControl: AnyObject {}

// MARK: - Keyboard (Windows Explorer shortcuts)

@MainActor
enum FileListKeys {
    /// Returns true when the key was handled.
    static func handle(_ event: NSEvent, model: ExplorerModel, nativeTypeSelect: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = flags.contains(.option), command = flags.contains(.command)

        switch event.keyCode {
        case 51:                                   // Backspace → Back (⌘⌫ → delete, like Finder)
            if command { model.deleteSelection() } else { model.goBack() }
            return true
        case 117:                                  // Delete (forward) → delete
            model.deleteSelection()
            return true
        case 36, 76:                               // Enter → open; ⌥Enter → Properties
            if option { model.showProperties() } else { model.openSelection() }
            return true
        case 120:                                  // F2 → rename
            model.beginRename()
            return true
        case 96:                                   // F5 → refresh
            model.refresh()
            return true
        case 115:                                  // Home
            model.selectFirst()
            return true
        case 119:                                  // End
            model.selectLast()
            return true
        case 53:                                   // Esc
            model.selectNone()
            return true
        case 123 where option:                     // ⌥← Back
            model.goBack()
            return true
        case 124 where option:                     // ⌥→ Forward
            model.goForward()
            return true
        case 126 where option:                     // ⌥↑ Up
            model.goUp()
            return true
        default:
            break
        }

        if !nativeTypeSelect, !command, !option, !flags.contains(.control),
           let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first, CharacterSet.alphanumerics.contains(scalar) {
            model.typeAhead(chars)
            return true
        }
        return false
    }
}

// MARK: - Drag & drop

enum DropHelper {
    static func paths(from info: NSDraggingInfo) -> [String] {
        if let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        if let propertyList = info.draggingPasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            return propertyList
        }
        return []
    }

    static func operation(_ kind: OpKind) -> NSDragOperation { kind == .copy ? .copy : .move }

    /// In Windows Explorer, holding Ctrl forces copy (⌥ also supported for Mac users).
    static func isCopyModifier(info: NSDraggingInfo? = nil) -> Bool {
        let flags = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).intersection(.deviceIndependentFlagsMask)
        return flags.contains(.control) || flags.contains(.option)
    }
}

// MARK: - Context menu

/// Menu item that runs a closure; keeps the builder free of target/action boilerplate.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [],
         enabled: Bool = true, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// Flat icon button used in the top row of the Windows 11 style context menu.
private final class MenuIconButton: NSButton {
    private let handler: () -> Void
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(symbol: String, tip: String, enabled: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        isEnabled = enabled
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 36, height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled { isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted && isEnabled {
            let hoverRect = bounds.insetBy(dx: 2, dy: 1)
            let path = NSBezierPath(roundedRect: hoverRect, xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            path.fill()
        } else if isHovered && isEnabled {
            let hoverRect = bounds.insetBy(dx: 2, dy: 1)
            let path = NSBezierPath(roundedRect: hoverRect, xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }

    @objc private func fire() {
        enclosingMenuItem?.menu?.cancelTracking()
        let work = handler
        DispatchQueue.main.async { work() }     // after the menu has dismissed
    }
}

private final class IconRowContainer: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 240, height: 38)
    }
}

/// Builds the right-click menu the way Windows 11 lays it out: a row of icon actions
/// (cut, copy, paste, rename, delete) on top, then the text commands.
@MainActor
struct ContextMenuBuilder {
    let model: ExplorerModel

    func menu(for path: String?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let path { addItemCommands(to: menu, path: path) } else { addBackgroundCommands(to: menu) }
        return menu
    }

    // MARK: Item menu

    private func addItemCommands(to menu: NSMenu, path: String) {
        let selection = model.contextSelection(for: path)
        let single = selection.count == 1
        let item = model.item(at: path)
        let isFolder = item?.opensAsFolder ?? false
        let isZip = item?.ext == "zip"

        menu.addItem(iconRow(single: single))
        menu.addItem(.separator())

        if let item { menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { model.openItem(item) }) }
        if isFolder {
            menu.addItem(ClosureMenuItem("Open in new tab", symbol: "plus.rectangle.on.rectangle") { model.openInNewTab(path) })
        }
        if model.isSearchResults && single {
            menu.addItem(ClosureMenuItem("Go to path", symbol: "folder") { model.openOriginalLocation(for: path) })
        }
        menu.addItem(ClosureMenuItem("Open with…", symbol: "app.badge", enabled: single && !isFolder) { model.openWithSelection() })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Compress…", symbol: "doc.zipper") { model.compressSelection() })
        if isZip { menu.addItem(ClosureMenuItem("Extract All…", symbol: "arrow.up.bin") { model.extractSelection() }) }

        if isFolder {
            let pinned = model.isPinned(path)
            menu.addItem(ClosureMenuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", symbol: "pin") {
                pinned ? model.unpin(path) : model.pin(path, name: item?.name)
            })
        }
        menu.addItem(categoryMenuItem(for: path, name: item?.name))
        menu.addItem(ClosureMenuItem("Copy as path", symbol: "link") { model.copyPaths() })
        menu.addItem(.separator())

        if let share = shareMenuItem(selection) { menu.addItem(share) }
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { model.revealInFinder(path) })
        if isFolder { menu.addItem(ClosureMenuItem("Open in Terminal", symbol: "terminal") { model.openTerminal(at: path) }) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Properties", symbol: "info.circle", key: "i", modifiers: .command) { model.showProperties(path) })
        addCloudCommands(to: menu, path: path, selection: selection)
    }

    private func iconRow(single: Bool) -> NSMenuItem {
        func button(_ symbol: String, _ tip: String, enabled: Bool = true, _ action: @escaping () -> Void) -> MenuIconButton {
            MenuIconButton(symbol: symbol, tip: tip, enabled: enabled, handler: action)
        }
        let buttons: [NSView] = [
            button("scissors", "Cut (⌘X)") { model.cutSelection() },
            button("doc.on.doc", "Copy (⌘C)") { model.copySelection() },
            button("doc.on.clipboard", "Paste (⌘V)", enabled: model.canPaste) { model.paste() },
            button("pencil", "Rename (F2)", enabled: single) { model.beginRename() },
            button("trash", "Delete (Del)") { model.deleteSelection() }
        ]
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = IconRowContainer(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
        container.autoresizingMask = [.width]
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        let row = NSMenuItem()
        row.view = container
        return row
    }

    private func categoryMenuItem(for path: String, name: String?) -> NSMenuItem {
        let parent = NSMenuItem(title: "Pin to Category", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        for category in model.categories {
            let present = category.paths.contains(path)
            sub.addItem(ClosureMenuItem(category.name, enabled: !present, checked: present) {
                model.addToCategory(category.id, paths: [path])
            })
        }
        if !model.categories.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ClosureMenuItem("New category…", symbol: "plus") { model.addCategory(name: name, paths: [path]) })
        parent.submenu = sub
        return parent
    }

    private func shareMenuItem(_ paths: [String]) -> NSMenuItem? {
        let services = SystemActions.sharingServices(for: paths)
        guard !services.isEmpty else { return nil }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let parent = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        let sub = NSMenu()
        for service in services {
            let entry = ClosureMenuItem(service.menuItemTitle) { service.perform(withItems: urls) }
            entry.image = service.image
            sub.addItem(entry)
        }
        parent.submenu = sub
        return parent
    }

    private func addCloudCommands(to menu: NSMenu, path: String, selection: [String]) {
        guard let info = model.cloudInfo(for: path) else { return }
        menu.addItem(.separator())
        if info.provider.supportsWebLink {
            menu.addItem(ClosureMenuItem("Open on \(info.provider.displayName)", symbol: "cloud") { model.openCloudOnWeb(path) })
        }
        menu.addItem(ClosureMenuItem("Make available offline", symbol: "arrow.down.circle") { model.makeAvailableOffline(selection) })
    }

    // MARK: Background menu

    private func addBackgroundCommands(to menu: NSMenu) {
        menu.addItem(submenu("View", symbol: "rectangle.grid.2x2", ViewMode.allCases.map { mode in
            ClosureMenuItem(mode.title, symbol: mode.symbol, checked: model.viewMode == mode) { model.setViewMode(mode) }
        }))
        var sort: [NSMenuItem] = SortKey.allCases.map { key in
            ClosureMenuItem(key.title, checked: model.sortKey == key) {
                if model.sortKey != key { model.setSort(key) }
            }
        }
        sort.append(.separator())
        sort.append(ClosureMenuItem("Ascending", checked: model.sortDirection == .ascending) { model.setSortDirection(.ascending) })
        sort.append(ClosureMenuItem("Descending", checked: model.sortDirection == .descending) { model.setSortDirection(.descending) })
        menu.addItem(submenu("Sort by", symbol: "arrow.up.arrow.down", sort))
        menu.addItem(submenu("Group by", symbol: "rectangle.3.group", GroupKey.allCases.map { key in
            ClosureMenuItem(key.title, checked: model.groupBy == key) { model.setGroupBy(key) }
        }))
        menu.addItem(ClosureMenuItem("Refresh", symbol: "arrow.clockwise", key: "r", modifiers: .command) { model.refresh() })
        menu.addItem(.separator())
        menu.addItem(submenu("New", symbol: "plus", [
            ClosureMenuItem("Folder", symbol: "folder.badge.plus") { model.createFolder() },
            ClosureMenuItem("Text Document", symbol: "doc.badge.plus") { model.createTextFile() }
        ]))
        menu.addItem(ClosureMenuItem("Paste", symbol: "doc.on.clipboard", enabled: model.canPaste) { model.paste() })
        menu.addItem(ClosureMenuItem("Undo", symbol: "arrow.uturn.backward", enabled: !model.undoStack.isEmpty) { model.undo() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open in Terminal", symbol: "terminal") { model.openTerminal() })
        menu.addItem(ClosureMenuItem("Show hidden items", symbol: "eye", checked: model.showHidden) { model.toggleShowHidden() })
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { model.revealInFinder(model.currentPath) })
        menu.addItem(ClosureMenuItem("Select all", key: "a", modifiers: .command) { model.selectAll() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Properties", symbol: "info.circle", key: "i", modifiers: .command) { model.showProperties(model.currentPath) })
        addCloudCommands(to: menu, path: model.currentPath, selection: [model.currentPath])
    }

    private func submenu(_ title: String, symbol: String, _ entries: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        entries.forEach(sub.addItem)
        parent.submenu = sub
        return parent
    }
}
