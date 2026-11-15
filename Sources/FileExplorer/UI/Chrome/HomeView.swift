import SwiftUI

/// The "Home" page, like Windows 11 Explorer's start view: Quick access tiles, then Recent / categories.
struct HomeView: View {
    @ObservedObject var model: ExplorerModel
    @State private var tab = "recent"
    @State private var recentItems: [FileItem] = []

    private var links: [QuickLink] { model.quickLinks + model.pinnedLinks }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Quick access").font(.system(size: 14, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(links, id: \.path) { link in
                        Button { model.navigate(to: link.path) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: link.icon.symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor).frame(width: 28)
                                Text(link.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Picker("", selection: $tab) {
                    Text("Recent").tag("recent")
                    ForEach(model.categories) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)

                if tab == "recent" {
                    list(of: recentItems, removable: true)
                    if !recentItems.isEmpty {
                        Button("Clear recent") { model.clearRecents() }.controlSize(.small)
                    }
                } else if let category = model.categories.first(where: { $0.id == tab }) {
                    CategoryItems(model: model, paths: category.paths)
                }
            }
            .padding(20)
        }
        .task(id: model.recents) { recentItems = await model.resolve(model.recents) }
    }

    @ViewBuilder
    private func list(of items: [FileItem], removable: Bool) -> some View {
        if items.isEmpty {
            Text("No recent items").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    HomeRow(model: model, item: item, removable: removable)
                }
            }
        }
    }
}

private struct CategoryItems: View {
    @ObservedObject var model: ExplorerModel
    let paths: [String]
    @State private var items: [FileItem] = []

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("Drag folders onto this category in the navigation pane.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(items) { HomeRow(model: model, item: $0, removable: false) }
        }
        .task(id: paths) { items = await model.resolve(paths) }
    }
}

private struct HomeRow: View {
    @ObservedObject var model: ExplorerModel
    let item: FileItem
    let removable: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconProvider.shared.icon(for: item)).resizable().frame(width: 18, height: 18)
            Text(item.name).font(.system(size: 12)).lineLimit(1)
            Text(Formatting.abbreviatingHome(PathUtils.parent(item.path), home: model.homeDir))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            Text(Formatting.dateTime(item.modified)).font(.system(size: 11)).foregroundStyle(.secondary)
            if removable {
                Button { model.removeRecent(item.path) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).opacity(hovering ? 0.8 : 0).help("Remove from Recent")
            }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.openItem(item) }
        .contextMenu {
            Button("Open") { model.openItem(item) }
            Button("Show in Finder") { model.revealInFinder(item.path) }
        }
    }
}
