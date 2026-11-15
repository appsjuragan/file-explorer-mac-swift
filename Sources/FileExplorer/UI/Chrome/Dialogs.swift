import SwiftUI

/// "Replace or Skip Files" — shown when a copy/move would overwrite existing names.
struct ConflictSheet: View {
    @ObservedObject var model: ExplorerModel
    let transfer: PendingTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(transfer.conflicts.count) item\(transfer.conflicts.count == 1 ? "" : "s") already exist\(transfer.conflicts.count == 1 ? "s" : "") in the destination")
                .font(.system(size: 14, weight: .semibold))
            Text(Formatting.abbreviatingHome(transfer.destination, home: model.homeDir))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(transfer.conflicts.prefix(6), id: \.self) { Text($0).font(.system(size: 12)).lineLimit(1) }
                if transfer.conflicts.count > 6 {
                    Text("and \(transfer.conflicts.count - 6) more…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("Replaced items are moved to the Trash, so they can be recovered.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.resolveConflict(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { model.resolveConflict(.skip) }
                Button("Keep both") { model.resolveConflict(.keepBoth) }
                Button("Replace") { model.resolveConflict(.replace) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Properties dialog (⌘I).
struct PropertiesSheet: View {
    @ObservedObject var model: ExplorerModel
    let path: String
    @Environment(\.dismiss) private var dismiss

    @State private var info: PropertyInfo?
    @State private var folderSize: FolderSize?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let info {
                HStack(spacing: 12) {
                    Image(nsImage: IconProvider.shared.icon(for: item(info))).resizable().frame(width: 40, height: 40)
                    Text(info.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                }
                Divider()
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Type", info.typeLabel)
                    row("Location", info.parent)
                    row("Size", sizeText(info))
                    row("Created", Formatting.dateTime(info.created))
                    row("Modified", Formatting.dateTime(info.modified))
                    row("Accessed", Formatting.dateTime(info.accessed))
                    row("Permissions", info.mode)
                    if let target = info.symlinkTarget { row("Links to", target) }
                }
            } else if failed {
                Text("Properties are not available for this item.").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            info = await model.loadProperties(path)
            failed = info == nil
            if let info, info.isDirectory { folderSize = await model.loadFolderSize(path) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.system(size: 12)).textSelection(.enabled).lineLimit(3)
        }
    }

    private func sizeText(_ info: PropertyInfo) -> String {
        if !info.isDirectory { return "\(Formatting.bytes(info.size)) (\(Formatting.grouped(info.size)) bytes)" }
        guard let folderSize else { return "Calculating…" }
        let contents = "\(Formatting.grouped(Int64(folderSize.files))) files, \(Formatting.grouped(Int64(folderSize.folders))) folders"
        return "\(Formatting.bytes(folderSize.size))\(folderSize.complete ? "" : "+") — \(contents)"
    }

    private func item(_ info: PropertyInfo) -> FileItem {
        model.visibleItems.first { $0.path == info.path } ?? FileItem(
            name: info.name, path: info.path, isDirectory: info.isDirectory, isSymbolicLink: info.isSymbolicLink,
            size: info.size, modified: info.modified, created: info.created,
            ext: (info.name as NSString).pathExtension.lowercased(), isHidden: false, kind: info.kind)
    }
}
