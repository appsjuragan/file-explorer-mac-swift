import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - SwiftUI bridge

/// Every non-Details view mode: Extra large / Large / Medium / Small icons, List, Tiles.
/// One recycled `NSCollectionView` whose cell layout is driven by `GridStyle`.
struct IconGridView: NSViewRepresentable {
    @ObservedObject var model: ExplorerModel

    func makeCoordinator() -> IconGridController { IconGridController(model: model) }

    func makeNSView(context: Context) -> FileListHostView { context.coordinator.host }

    func updateNSView(_ nsView: FileListHostView, context: Context) { context.coordinator.sync() }
}

// MARK: - Geometry (mirrors the sizes of the Electron layout)

struct GridStyle: Equatable {
    enum Layout { case vertical, horizontal, tile }

    let layout: Layout
    let cell: NSSize
    let icon: CGFloat
    let columnGap: CGFloat
    let rowGap: CGFloat
    let inset: CGFloat

    static func make(for mode: ViewMode) -> GridStyle {
        switch mode {
        case .list: return GridStyle(layout: .horizontal, cell: NSSize(width: 232, height: 26), icon: 16, columnGap: 6, rowGap: 1, inset: 8)
        case .small: return GridStyle(layout: .horizontal, cell: NSSize(width: 200, height: 24), icon: 16, columnGap: 6, rowGap: 1, inset: 8)
        case .tiles: return GridStyle(layout: .tile, cell: NSSize(width: 264, height: 56), icon: 40, columnGap: 6, rowGap: 6, inset: 10)
        case .medium: return GridStyle(layout: .vertical, cell: NSSize(width: 100, height: 116), icon: 48, columnGap: 4, rowGap: 4, inset: 12)
        case .large: return GridStyle(layout: .vertical, cell: NSSize(width: 124, height: 142), icon: 72, columnGap: 4, rowGap: 4, inset: 12)
        case .extraLarge, .details: return GridStyle(layout: .vertical, cell: NSSize(width: 152, height: 172), icon: 104, columnGap: 4, rowGap: 4, inset: 12)
        }
    }
}

// MARK: - Collection view subclass

@MainActor
final class FileCollectionView: NSCollectionView, FileListControl {
    weak var model: ExplorerModel?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    var onDraggingExited: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) }

    override func keyDown(with event: NSEvent) {
        if let model, FileListKeys.handle(event, model: model, nativeTypeSelect: false) { return }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDraggingExited?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDraggingExited?()
    }
}

// MARK: - Cell

private final class GridCellContainer: NSView {
    var onDoubleClick: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var tooltipProvider: (() -> String?)?
    private lazy var lazyToolTip = LazyToolTip(for: self) { [weak self] in self?.tooltipProvider?() }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)                       // selection is handled by the collection view
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func layout() {
        super.layout()
        lazyToolTip.refresh()
    }
}

final class GridCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("fe.grid.cell")

    private(set) var path = ""
    private(set) var currentItem: FileItem?
    var onOpen: (() -> Void)?

    private var style = GridStyle.make(for: .large)
    private let iconView = NSImageView()
    private let nameField = NSTextField(wrappingLabelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    var nameTextField: NSTextField { nameField }

    override func loadView() {
        let container = GridCellContainer()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.onDoubleClick = { [weak self] in self?.onOpen?() }
        container.onAppearanceChange = { [weak self] in self?.updateAppearance() }

        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameField.isSelectable = false
        nameField.maximumNumberOfLines = 3
        nameField.lineBreakMode = .byTruncatingTail
        nameField.cell?.wraps = true
        nameField.cell?.isScrollable = false
        nameField.font = .systemFont(ofSize: 12)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.maximumNumberOfLines = 2
        detailField.lineBreakMode = .byTruncatingTail
        [iconView, nameField, detailField].forEach(container.addSubview)
        view = container
    }

    override var isSelected: Bool { didSet { updateAppearance() } }
    var isDropTarget: Bool = false { didSet { if oldValue != isDropTarget { updateAppearance() } } }

    override func prepareForReuse() {
        super.prepareForReuse()
        MainActor.assumeIsolated { IconProvider.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
        iconView.image = nil
        onOpen = nil
        isDropTarget = false
        currentItem = nil
    }

    func configure(item: FileItem, style: GridStyle, scale: CGFloat) {
        _ = view                                            // make sure loadView ran
        self.style = style
        path = item.path
        currentItem = item
        let alpha: CGFloat = item.isHidden ? 0.55 : 1
        nameField.stringValue = item.name
        nameField.alphaValue = alpha
        nameField.alignment = style.layout == .vertical ? .center : .left
        nameField.maximumNumberOfLines = style.layout == .vertical ? 3 : 1
        nameField.lineBreakMode = style.layout == .vertical ? .byTruncatingTail : .byTruncatingMiddle
        nameField.cell?.wraps = style.layout == .vertical
        nameField.cell?.isScrollable = style.layout != .vertical
        nameField.isEditable = false
        iconView.alphaValue = alpha
        (view as? GridCellContainer)?.tooltipProvider = { [weak self] in
            self?.currentItem.map(FileTooltipHelper.tooltip(for:))
        }
        FileTooltipHelper.prefetch(for: item)

        switch style.layout {
        case .tile:
            let size = item.isDirectory ? "" : "\n" + Formatting.bytes(item.size)
            detailField.stringValue = FileKinds.label(for: item) + size
            detailField.isHidden = false
        default:
            detailField.stringValue = ""
            detailField.isHidden = true
        }

        MainActor.assumeIsolated {
            iconView.image = IconProvider.shared.icon(for: item)
            thumbnailRequest = IconProvider.shared.thumbnail(for: item, points: style.icon, scale: scale) { [weak self] image in
                guard let self, self.path == item.path else { return }
                self.iconView.image = image
            }
        }
        view.needsLayout = true
        updateAppearance()
    }

    private func updateAppearance() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if isDropTarget {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
                view.layer?.borderColor = NSColor.controlAccentColor.cgColor
                view.layer?.borderWidth = 2
            } else if isSelected {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                view.layer?.borderColor = NSColor.clear.cgColor
                view.layer?.borderWidth = 0
            } else {
                view.layer?.backgroundColor = NSColor.clear.cgColor
                view.layer?.borderColor = NSColor.clear.cgColor
                view.layer?.borderWidth = 0
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        guard b.width > 0, b.height > 0 else { return }
        switch style.layout {
        case .vertical:
            let width = max(10, b.width - 8)
            let textHeight = min(nameField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 200)).height ?? 46, 50)
            let maxIcon = max(16, b.height - textHeight - 12)
            let icon = min(style.icon, maxIcon)
            iconView.frame = NSRect(x: (b.width - icon) / 2, y: b.height - icon - 8, width: icon, height: icon)
            nameField.frame = NSRect(x: 4, y: max(2, iconView.frame.minY - 4 - textHeight), width: width, height: textHeight)
        case .horizontal:
            let icon = min(style.icon, max(12, b.height - 4))
            iconView.frame = NSRect(x: 6, y: (b.height - icon) / 2, width: icon, height: icon)
            let lineHeight: CGFloat = 16
            nameField.frame = NSRect(x: icon + 12, y: (b.height - lineHeight) / 2, width: max(10, b.width - icon - 18), height: lineHeight)
        case .tile:
            let icon = min(style.icon, max(16, b.height - 8))
            iconView.frame = NSRect(x: 8, y: (b.height - icon) / 2, width: icon, height: icon)
            let x = icon + 16, width = max(10, b.width - x - 6)
            nameField.frame = NSRect(x: x, y: b.height - 22, width: width, height: 16)
            detailField.frame = NSRect(x: x, y: 4, width: width, height: max(10, b.height - 28))
        }
    }
}

private final class GridHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("fe.grid.header")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: bounds.width - 24, height: 18)
    }
}

// MARK: - Controller

@MainActor
final class IconGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    let model: ExplorerModel
    let host: FileListHostView
    private let collection: FileCollectionView
    private let layout = NSCollectionViewFlowLayout()
    private var sections: [ItemSection] = []
    private var indexForPath: [String: IndexPath] = [:]
    private var lastVersion = -1
    private var style: GridStyle?
    private var grouped: Bool?
    private var suppress = false
    private var editingPath: String?
    private var editCancelled = false
    private var dropTargetIndexPath: IndexPath?

    private var currentStyle: GridStyle {
        style ?? GridStyle.make(for: model.viewMode)
    }

    init(model: ExplorerModel) {
        self.model = model
        let view = FileCollectionView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = view
        collection = view
        host = FileListHostView(model: model, content: scroll)
        super.init()
        configure()
        applyLayout(GridStyle.make(for: model.viewMode), grouped: model.groupBy != .none)
    }

    private func configure() {
        collection.model = model
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(GridCell.self, forItemWithIdentifier: GridCell.id)
        collection.register(GridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: GridHeader.id)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask(.every, forLocal: true)
        collection.setDraggingSourceOperationMask(.every, forLocal: false)
        collection.contextMenuProvider = { [weak self] event in self?.contextMenu(for: event) }
        collection.onDraggingExited = { [weak self] in self?.clearDropHighlight() }
    }

    private func setDropTarget(at indexPath: IndexPath?) {
        guard dropTargetIndexPath != indexPath else { return }
        if let old = dropTargetIndexPath, let oldCell = collection.item(at: old) as? GridCell {
            oldCell.isDropTarget = false
        }
        dropTargetIndexPath = indexPath
        if let new = indexPath, let newCell = collection.item(at: new) as? GridCell {
            newCell.isDropTarget = true
        }
    }

    private func clearDropHighlight() {
        setDropTarget(at: nil)
    }

    // MARK: Sync

    func sync() {
        clearDropHighlight()
        let newStyle = GridStyle.make(for: model.viewMode)
        let newGrouped = model.groupBy != .none
        let layoutChanged = style == nil || newStyle != style || newGrouped != grouped
        if layoutChanged { applyLayout(newStyle, grouped: newGrouped) }

        if model.listVersion != lastVersion || layoutChanged {
            lastVersion = model.listVersion
            sections = model.sections
            indexForPath.removeAll(keepingCapacity: true)
            for (s, section) in sections.enumerated() {
                for (i, item) in section.items.enumerated() { indexForPath[item.path] = IndexPath(item: i, section: s) }
            }
            suppress = true
            collection.reloadData()
            suppress = false
        }
        syncSelection()
        syncRename()
    }

    private func applyLayout(_ newStyle: GridStyle, grouped newGrouped: Bool) {
        style = newStyle
        grouped = newGrouped
        layout.itemSize = newStyle.cell
        layout.minimumInteritemSpacing = newStyle.columnGap
        layout.minimumLineSpacing = newStyle.rowGap
        layout.sectionInset = NSEdgeInsets(top: newStyle.inset, left: newStyle.inset, bottom: newStyle.inset, right: newStyle.inset)
        layout.headerReferenceSize = newGrouped ? NSSize(width: 0, height: 32) : .zero
        layout.invalidateLayout()
    }

    private func syncSelection() {
        let target = Set(model.selection.compactMap { indexForPath[$0] })
        guard collection.selectionIndexPaths != target else { return }
        suppress = true
        collection.selectionIndexPaths = target
        suppress = false
        if target.count == 1 { collection.scrollToItems(at: target, scrollPosition: .nearestVerticalEdge) }
    }

    private func pushSelection() {
        guard !suppress else { return }
        let paths = collection.selectionIndexPaths.map { sections[$0.section].items[$0.item].path }
        model.setSelection(Set(paths))
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = sections[indexPath.section].items[indexPath.item]
        guard let cell = collectionView.makeItem(withIdentifier: GridCell.id, for: indexPath) as? GridCell else {
            return NSCollectionViewItem()
        }
        let scale = collectionView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        cell.configure(item: item, style: currentStyle, scale: scale)
        cell.onOpen = { [weak self] in self?.model.openItem(item) }
        cell.isSelected = model.selection.contains(item.path)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        guard let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeader.id, for: indexPath) as? GridHeader else {
            return NSView()
        }
        let section = sections[indexPath.section]
        header.label.stringValue = "\(section.label) (\(section.items.count))"
        return header
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }

    // MARK: Context menu

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = collection.convert(event.locationInWindow, from: nil)
        let builder = ContextMenuBuilder(model: model)
        if let ip = collection.indexPathForItem(at: point) {
            return builder.menu(for: sections[ip.section].items[ip.item].path)
        }
        model.selectNone()
        return builder.menu(for: nil)
    }

    // MARK: Inline rename

    private func syncRename() {
        guard let path = model.renamingPath, editingPath != path, let ip = indexForPath[path] else { return }
        editingPath = path
        editCancelled = false
        collection.scrollToItems(at: [ip], scrollPosition: .nearestVerticalEdge)
        DispatchQueue.main.async { [weak self] in
            guard let self, let cell = self.collection.item(at: ip) as? GridCell else { return }
            let field = cell.nameTextField
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            self.collection.window?.makeFirstResponder(field)
            let name = field.stringValue as NSString
            let stem = name.deletingPathExtension as NSString
            let length = (name.pathExtension.isEmpty || stem.length == 0) ? name.length : stem.length
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: length))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        editCancelled = true
        collection.window?.makeFirstResponder(collection)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let path = editingPath else { return }
        editingPath = nil
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        if editCancelled {
            field.stringValue = PathUtils.basename(path)
            model.cancelRename()
        } else {
            model.commitRename(field.stringValue)
        }
        collection.window?.makeFirstResponder(collection)
    }

    // MARK: Drag & drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        URL(fileURLWithPath: sections[indexPath.section].items[indexPath.item].path) as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let sources = DropHelper.paths(from: draggingInfo)
        guard !sources.isEmpty else {
            clearDropHighlight()
            return []
        }
        let isCopy = DropHelper.isCopyModifier(info: draggingInfo)

        let point = collection.convert(draggingInfo.draggingLocation, from: nil)
        let hitIndexPath = collection.indexPathForItem(at: point)

        // Check if mouse is directly over a folder cell
        if let hit = hitIndexPath, hit.section < sections.count, hit.item < sections[hit.section].items.count {
            let item = sections[hit.section].items[hit.item]
            if item.opensAsFolder {
                let kind = model.dropOperation(sources: sources, destination: item.path, copyModifier: isCopy)
                if model.canAccept(sources: sources, destination: item.path, op: kind) {
                    proposedDropIndexPath.pointee = hit as NSIndexPath
                    proposedDropOperation.pointee = .on
                    setDropTarget(at: hit)
                    return DropHelper.operation(kind)
                }
            }
        }

        // Not hovering over a valid folder item: clear highlight
        clearDropHighlight()

        // Fallback: dropping into current directory (e.g. hold Ctrl to copy in same folder, or dragging from external/other folder)
        let kind = model.dropOperation(sources: sources, destination: model.currentPath, copyModifier: isCopy)
        if model.canAccept(sources: sources, destination: model.currentPath, op: kind) {
            proposedDropOperation.pointee = .before
            return DropHelper.operation(kind)
        }

        return []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        clearDropHighlight()
        let sources = DropHelper.paths(from: draggingInfo)
        guard !sources.isEmpty else { return false }
        let isCopy = DropHelper.isCopyModifier(info: draggingInfo)

        let point = collection.convert(draggingInfo.draggingLocation, from: nil)
        let hitIndexPath = collection.indexPathForItem(at: point) ?? indexPath

        // Dropped on a folder cell
        if (dropOperation == .on || hitIndexPath == indexPath),
           hitIndexPath.section < sections.count, hitIndexPath.item < sections[hitIndexPath.section].items.count {
            let item = sections[hitIndexPath.section].items[hitIndexPath.item]
            if item.opensAsFolder {
                let kind = model.dropOperation(sources: sources, destination: item.path, copyModifier: isCopy)
                if model.canAccept(sources: sources, destination: item.path, op: kind) {
                    model.performTransfer(sources, to: item.path, op: kind)
                    return true
                }
            }
        }

        // Dropped into current directory
        let target = model.currentPath
        let kind = model.dropOperation(sources: sources, destination: target, copyModifier: isCopy)
        guard model.canAccept(sources: sources, destination: target, op: kind) else { return false }
        model.performTransfer(sources, to: target, op: kind)
        return true
    }
}
