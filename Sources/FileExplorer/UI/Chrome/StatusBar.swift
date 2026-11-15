import SwiftUI

/// Item count, selection summary, transient message, and the Details / Large-icons toggles.
struct StatusBar: View {
    @ObservedObject var model: ExplorerModel

    private var summary: String {
        if model.isHome { return "" }
        let total = "\(model.items.count) item\(model.items.count == 1 ? "" : "s")"
        let selected = model.selectedItems
        guard !selected.isEmpty else { return total }
        let files = selected.filter { !$0.isDirectory }
        let size = files.isEmpty ? "" : "  \(Formatting.bytes(files.reduce(0) { $0 + $1.size }))"
        return "\(total)   |   \(selected.count) selected\(size)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(model.statusMessage ?? summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            modeButton(.details)
            modeButton(.large)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private func modeButton(_ mode: ViewMode) -> some View {
        Button { model.setViewMode(mode) } label: { Image(systemName: mode.symbol).font(.system(size: 12)) }
            .buttonStyle(.plain)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 4).fill(model.viewMode == mode ? Color.accentColor.opacity(0.25) : .clear))
            .help(mode.title)
            .disabled(model.isHome)
    }
}
