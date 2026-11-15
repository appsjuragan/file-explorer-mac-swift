import SwiftUI

/// Windows 11 style tab row that doubles as the window's title bar.
struct TabStrip: View {
    @ObservedObject var model: ExplorerModel
    let leadingInset: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.tabs) { tab in
                TabButton(model: model, tab: tab, isActive: tab.id == model.activeTabID, canClose: model.tabs.count > 1)
            }
            IconButton(symbol: "plus", help: "New tab (⌘T)") { model.newTab() }
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(WindowDragArea())
        .background(Color.primary.opacity(0.04))
    }
}

private struct TabButton: View {
    @ObservedObject var model: ExplorerModel
    let tab: Tab
    let isActive: Bool
    let canClose: Bool

    @State private var hovering = false

    private var title: String { PathUtils.displayName(tab.path, homeDir: model.homeDir) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.path == PathUtils.home ? "house" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 12)).lineLimit(1)
            if canClose {
                Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .opacity(hovering || isActive ? 0.8 : 0)
                    .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, maxWidth: 220, minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(isActive ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.setActiveTab(tab.id) }
        .contextMenu {
            Button("Duplicate tab") { model.setActiveTab(tab.id); model.duplicateActiveTab() }
            Button("Close tab") { model.closeTab(tab.id) }.disabled(!canClose)
            Button("Close other tabs") { model.closeOtherTabs(keeping: tab.id) }.disabled(!canClose)
        }
    }
}
