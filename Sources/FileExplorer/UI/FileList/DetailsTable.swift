import AppKit
import SwiftUI

// MARK: - SwiftUI bridge

/// The "Details" view: Name / Date modified / Type / Size columns backed by NSTableView,
/// which recycles row views, so memory follows the visible rows, not the folder size.
struct DetailsTableView: NSViewRepresentable {
    @ObservedObject var model: ExplorerModel

    func makeCoordinator() -> DetailsTableController { DetailsTableController(model: model) }

    func makeNSView(context: Context) -> FileListHostView { context.coordinator.host }

    func updateNSView(_ nsView: FileListHostView, context: Context) { context.coordinator.sync() }
}

// MARK: - Table subclass

@MainActor
final class FileTableView: NSTableView, FileListControl {
    weak var model: ExplorerModel?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) }

    override func keyDown(with event: NSEvent) {
        if let model, FileListKeys.handle(event, model: model, nativeTypeSelect: true) { return }
        super.keyDown(with: event)
    }
}

// MARK: - Cells

private final class NameCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("fe.cell.name")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        [icon, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class TextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class GroupCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("fe.cell.group")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Controller

@MainActor
final class DetailsTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row {
        case header(label: String, count: Int)
        case item(FileItem)
    }

    private static let defaultWidths: [String: CGFloat] = ["name": 320, "modified": 180, "type": 150, "size": 100]

    let model: ExplorerModel
    let host: FileListHostView
    private let table: FileTableView
    private var rows: [Row] = []
    private var rowForPath: [String: Int] = [:]
    private var lastVersion = -1
    private var suppress = false
    private var editingPath: String?
    private var editCancelled = false

    init(model: ExplorerModel) {
        self.model = model
        let tableView = FileTableView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = tableView
        table = tableView
        host = FileListHostView(model: model, content: scroll)
        super.init()
        configureTable()
    }

    private func configureTable() {
        table.model = model
        table.style = .fullWidth
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.every, forLocal: true)
        table.setDraggingSourceOperationMask(.every, forLocal: false)
        table.contextMenuProvider = { [weak self] event in self?.contextMenu(for: event) }
        NotificationCenter.default.addObserver(self, selector: #selector(folderStatsUpdated(_:)),
                                               name: FileTooltipHelper.folderStatsUpdated, object: nil)

        let saved = model.prefs.value.columnWidths
        func column(_ id: String, _ title: String, min: CGFloat, last: Bool = false) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.minWidth = min
            c.width = saved[id].map { CGFloat($0) } ?? Self.defaultWidths[id] ?? 120
            c.resizingMask = last ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            return c
        }
        let size = column("size", "Size", min: 70, last: true)
        size.headerCell.alignment = .right
        [column("name", "Name", min: 140), column("modified", "Date modified", min: 110),
         column("type", "Type", min: 80), size].forEach(table.addTableColumn)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func folderStatsUpdated(_ notification: Notification) {
        guard let path = notification.object as? String, let row = rowForPath[path] else { return }
        guard row < rows.count, case .item(let item) = rows[row] else { return }
        let tip = FileTooltipHelper.tooltip(for: item)
        for col in 0..<table.numberOfColumns {
            if let cell = table.view(atColumn: col, row: row, makeIfNecessary: false) as? NSTableCellView {
                cell.toolTip = tip
            }
        }
    }

    // MARK: Sync with the model

    func sync() {
        if model.listVersion != lastVersion {
            lastVersion = model.listVersion
            rebuildRows()
            suppress = true
            table.reloadData()
            suppress = false
        }
        syncSort()
        syncSelection()
        syncRename()
    }

    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        rowForPath.removeAll(keepingCapacity: true)
        let grouped = model.groupBy != .none
        for section in model.sections {
            if grouped { rows.append(.header(label: section.label, count: section.items.count)) }
            for item in section.items {
                rowForPath[item.path] = rows.count
                rows.append(.item(item))
            }
        }
    }

    private func syncSort() {
        let wanted = NSSortDescriptor(key: model.sortKey.rawValue, ascending: model.sortDirection == .ascending)
        guard table.sortDescriptors.first?.key != wanted.key || table.sortDescriptors.first?.ascending != wanted.ascending else { return }
        suppress = true
        table.sortDescriptors = [wanted]
        suppress = false
    }

    private func syncSelection() {
        let target = IndexSet(model.selection.compactMap { rowForPath[$0] })
        guard table.selectedRowIndexes != target else { return }
        suppress = true
        table.selectRowIndexes(target, byExtendingSelection: false)
        suppress = false
        if target.count == 1, let row = target.first { table.scrollRowToVisible(row) }
    }

    // MARK: Inline rename

    private func syncRename() {
        guard let path = model.renamingPath else { return }
        guard editingPath != path, let row = rowForPath[path] else { return }
        editingPath = path
        editCancelled = false
        table.scrollRowToVisible(row)
        // Defer: this runs inside a SwiftUI update; moving first responder there is unsafe.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCell,
                  let field = cell.textField else { return }
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            self.table.window?.makeFirstResponder(field)
            let name = field.stringValue as NSString
            let stem = name.deletingPathExtension as NSString
            let length = (name.pathExtension.isEmpty || stem.length == 0) ? name.length : stem.length
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: length))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        editCancelled = true
        table.window?.makeFirstResponder(table)
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
        table.window?.makeFirstResponder(table)
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 26
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        if case .item(let item) = rows[row] { return item.name }
        return nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let label, let count):
            let cell = tableView.makeView(withIdentifier: GroupCell.id, owner: nil) as? GroupCell ?? GroupCell()
            cell.identifier = GroupCell.id
            cell.textField?.stringValue = "\(label) (\(count))"
            return cell
        case .item(let item):
            guard let id = tableColumn?.identifier else { return nil }
            switch id.rawValue {
            case "name":
                let cell = tableView.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
                cell.identifier = NameCell.id
                cell.imageView?.image = IconProvider.shared.icon(for: item)
                cell.textField?.stringValue = item.name
                cell.toolTip = FileTooltipHelper.tooltip(for: item)
                let alpha: CGFloat = item.isHidden ? 0.55 : 1
                cell.textField?.alphaValue = alpha
                cell.imageView?.alphaValue = alpha
                return cell
            default:
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell
                    ?? TextCell(identifier: id, alignment: id.rawValue == "size" ? .right : .left)
                cell.textField?.stringValue = text(for: id.rawValue, item)
                cell.toolTip = FileTooltipHelper.tooltip(for: item)
                return cell
            }
        }
    }

    private func text(for column: String, _ item: FileItem) -> String {
        switch column {
        case "modified": return Formatting.dateTime(item.modified)
        case "type": return FileKinds.label(for: item)
        case "size": return item.isDirectory ? "" : Formatting.bytes(item.size)
        default: return ""
        }
    }

    // MARK: Delegate: selection, sort, columns

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress else { return }
        let paths = table.selectedRowIndexes.compactMap { row -> String? in
            if case .item(let item) = rows[row] { return item.path }
            return nil
        }
        model.setSelection(Set(paths))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppress, let key = table.sortDescriptors.first?.key, let sortKey = SortKey(rawValue: key) else { return }
        model.setSort(sortKey)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !suppress, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              column.identifier.rawValue != "size" else { return }
        model.setColumnWidth(column.identifier.rawValue, Double(column.width))
    }

    @objc private func openClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
        model.openItem(item)
    }

    // MARK: Context menu

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        let builder = ContextMenuBuilder(model: model)
        if row >= 0, row < rows.count, case .item(let item) = rows[row] { return builder.menu(for: item.path) }
        model.selectNone()
        return builder.menu(for: nil)
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .item(let item) = rows[row] else { return nil }
        return URL(fileURLWithPath: item.path) as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let sources = DropHelper.paths(from: info)
        guard !sources.isEmpty else { return [] }
        let isCopy = DropHelper.isCopyModifier(info: info)

        let point = tableView.convert(info.draggingLocation, from: nil)
        let hitRow = tableView.row(at: point)

        // If hovering over a folder row, check if we can drop into it
        if hitRow >= 0, hitRow < rows.count, case .item(let item) = rows[hitRow], item.opensAsFolder {
            let kind = model.dropOperation(sources: sources, destination: item.path, copyModifier: isCopy)
            if model.canAccept(sources: sources, destination: item.path, op: kind) {
                tableView.setDropRow(hitRow, dropOperation: .on)
                return DropHelper.operation(kind)
            }
        }

        // Otherwise target the current directory
        let kind = model.dropOperation(sources: sources, destination: model.currentPath, copyModifier: isCopy)
        if model.canAccept(sources: sources, destination: model.currentPath, op: kind) {
            tableView.setDropRow(-1, dropOperation: .on)
            return DropHelper.operation(kind)
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        let sources = DropHelper.paths(from: info)
        guard !sources.isEmpty else { return false }
        let isCopy = DropHelper.isCopyModifier(info: info)

        let point = tableView.convert(info.draggingLocation, from: nil)
        let hitRow = (row >= 0) ? row : tableView.row(at: point)

        if hitRow >= 0, hitRow < rows.count, case .item(let item) = rows[hitRow], item.opensAsFolder {
            let kind = model.dropOperation(sources: sources, destination: item.path, copyModifier: isCopy)
            if model.canAccept(sources: sources, destination: item.path, op: kind) {
                model.performTransfer(sources, to: item.path, op: kind)
                return true
            }
        }

        let target = model.currentPath
        let kind = model.dropOperation(sources: sources, destination: target, copyModifier: isCopy)
        guard model.canAccept(sources: sources, destination: target, op: kind) else { return false }
        model.performTransfer(sources, to: target, op: kind)
        return true
    }
}
