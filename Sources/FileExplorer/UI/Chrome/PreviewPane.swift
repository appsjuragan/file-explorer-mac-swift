import SwiftUI

/// Details pane: thumbnail, key facts, and a short text preview of the single selected file.
struct PreviewPane: View {
    @ObservedObject var model: ExplorerModel

    @State private var thumbnail: NSImage?
    @State private var info: PropertyInfo?
    @State private var folderSize: FolderSize?
    @State private var text: String?

    private var subject: String? {
        if model.selection.count == 1 { return model.selection.first }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let path = subject, let item = model.item(at: path) {
                    header(item)
                    facts
                    if let text {
                        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                    Color.clear.frame(height: 0).task(id: path) { await load(item) }
                } else if model.selection.count > 1 {
                    Text("\(model.selection.count) items selected").font(.system(size: 13, weight: .semibold))
                } else {
                    Text("Select a file to see its details.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func header(_ item: FileItem) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: thumbnail ?? IconProvider.shared.icon(for: item))
                .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 160)
            Text(item.name).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).textSelection(.enabled)
            Text(FileKinds.label(for: item)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var facts: some View {
        if let info {
            VStack(alignment: .leading, spacing: 6) {
                fact("Size", info.isDirectory ? folderText : Formatting.bytes(info.size))
                fact("Date modified", Formatting.dateTime(info.modified))
                fact("Date created", Formatting.dateTime(info.created))
                fact("Location", Formatting.abbreviatingHome(info.parent, home: model.homeDir))
            }
        }
    }

    private var folderText: String {
        guard let folderSize else { return "Calculating…" }
        return Formatting.bytes(folderSize.size) + (folderSize.complete ? "" : "+")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled).lineLimit(3)
        }
    }

    private func load(_ item: FileItem) async {
        thumbnail = nil; info = nil; folderSize = nil; text = nil
        info = await model.loadProperties(item.path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnail = await IconProvider.shared.thumbnail(for: item, points: 160, scale: scale)
        if item.isDirectory {
            folderSize = await model.loadFolderSize(item.path)
        } else if [.text, .code].contains(item.kind) {
            text = await model.loadTextPreview(item.path)
        }
    }
}
