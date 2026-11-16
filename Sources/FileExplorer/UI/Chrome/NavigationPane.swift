import SwiftUI

/// Left pane: Quick access, user categories, This PC (drives + cloud), lazy folder tree synced with opened folder.
struct NavigationPane: View {
    @ObservedObject var model: ExplorerModel

    private var systemLinks: [QuickLink] { model.quickLinks }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    CollapsibleSectionHeader(
                        title: "Quick access",
                        collapsed: model.quickAccessCollapsed,
                        onToggle: { withAnimation(.easeInOut(duration: 0.15)) { model.toggleQuickAccess() } }
                    )
                    if !model.quickAccessCollapsed {
                        ForEach(systemLinks, id: \.path) { link in
                            QuickLinkNode(model: model, link: link, unpinnable: false)
                        }
                        ForEach(model.pinnedLinks, id: \.path) { link in
                            QuickLinkNode(model: model, link: link, unpinnable: true)
                        }
                    }

                    ForEach(model.categories) { category in
                        CategorySection(model: model, category: category)
                    }
                    Button { _ = model.addCategory() } label: {
                        Label("New category", systemImage: "plus").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.leading, 10).padding(.top, 4)

                    CollapsibleSectionHeader(
                        title: "This PC",
                        collapsed: model.thisPCCollapsed,
                        onToggle: { withAnimation(.easeInOut(duration: 0.15)) { model.toggleThisPC() } }
                    )
                    if !model.thisPCCollapsed {
                        ForEach(model.drives, id: \.path) { drive in
                            DriveTreeNode(model: model, drive: drive, detail: capacity(drive))
                        }
                        ForEach(model.cloudRoots, id: \.root) { root in
                            CloudRootNode(model: model, root: root)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .background(Color.primary.opacity(0.03))
            .onAppear {
                scrollToOpenedFolder(model.currentPath, proxy: proxy)
            }
            .onChange(of: model.currentPath) { newPath in
                scrollToOpenedFolder(newPath, proxy: proxy)
            }
        }
    }

    private func scrollToOpenedFolder(_ path: String, proxy: ScrollViewProxy) {
        guard path != PathUtils.home else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(path, anchor: .center)
            }
        }
    }

    private func capacity(_ drive: DriveItem) -> String? {
        guard let total = drive.total, let free = drive.free else { return nil }
        return "\(Formatting.capacity(free)) free of \(Formatting.capacity(total))"
    }
}

private struct CollapsibleSectionHeader: View {
    let title: String
    let collapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Row

private struct NavRow: View {
    @ObservedObject var model: ExplorerModel
    let name: String
    let path: String
    var image: NSImage?
    var symbol: String?
    let depth: Int
    var detail: String?
    var expandable = false
    var expanded = false
    var onToggle: () -> Void = {}

    @State private var hovering = false
    @State private var dropTargeted = false

    private var selected: Bool { model.currentPath == path }

    var body: some View {
        HStack(spacing: 4) {
            if expandable {
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }

            HStack(spacing: 6) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: symbol ?? "folder")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16, height: 16)
                }

                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let detail, depth == 0 {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.navigate(to: path) }
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(dropTargeted ? Color.accentColor.opacity(0.3)
                      : selected ? Color.accentColor.opacity(0.18)
                      : Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(detail.map { "\(name) — \($0)" } ?? path)
        .dropDestination(for: URL.self, action: { urls, _ in drop(urls) }, isTargeted: { dropTargeted = $0 })
    }

    private func drop(_ urls: [URL]) -> Bool {
        let sources = urls.filter(\.isFileURL).map(\.path)
        guard !sources.isEmpty else { return false }
        let isCopy = DropHelper.isCopyModifier()
        let op = model.dropOperation(sources: sources, destination: path, copyModifier: isCopy)
        guard model.canAccept(sources: sources, destination: path, op: op) else { return false }
        model.performTransfer(sources, to: path, op: op)
        return true
    }
}

// MARK: - Drive Tree Node (This PC)

private struct DriveTreeNode: View {
    @ObservedObject var model: ExplorerModel
    let drive: DriveItem
    let detail: String?

    private var path: String { drive.path }
    private var isExpanded: Bool { model.isTreeExpanded(path) }
    private var children: [FileItem]? { model.treeChildren[path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavRow(
                model: model,
                name: drive.name,
                path: path,
                image: IconProvider.shared.icon(forVolume: path),
                symbol: nil,
                depth: 0,
                detail: detail,
                expandable: children?.isEmpty != true,
                expanded: isExpanded,
                onToggle: { model.toggleTreeExpanded(path) }
            )
            .id(path)
            .contextMenu {
                Button("Open in new tab") { model.openInNewTab(path) }
                Button("Open in new window") { WindowRegistry.shared.open([path]) }
                Divider()
                Button("Copy path") { SystemActions.copyText(path) }
                Button("Open in Terminal") { SystemActions.openInTerminal(path) }
            }

            if isExpanded, let children {
                ForEach(children) { child in
                    FolderTreeNode(model: model, item: child, depth: 1)
                }
            }
        }
        .onAppear {
            if isExpanded && children == nil {
                model.loadTreeChildren(for: path)
            }
        }
    }
}

// MARK: - Folder Tree Node (Recursive)

private struct FolderTreeNode: View {
    @ObservedObject var model: ExplorerModel
    let item: FileItem
    let depth: Int

    private var path: String { item.path }
    private var isExpanded: Bool { model.isTreeExpanded(path) }
    private var children: [FileItem]? { model.treeChildren[path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavRow(
                model: model,
                name: item.name,
                path: path,
                image: isExpanded ? IconProvider.shared.folderOpenIcon : IconProvider.shared.folderIcon,
                symbol: nil,
                depth: depth,
                expandable: children?.isEmpty != true,
                expanded: isExpanded,
                onToggle: { model.toggleTreeExpanded(path) }
            )
            .id(path)
            .contextMenu {
                Button("Open in new tab") { model.openInNewTab(path) }
                Button("Open in new window") { WindowRegistry.shared.open([path]) }
                Divider()
                if !model.isPinned(path) && path != PathUtils.home {
                    Button("Pin to Quick access") { model.pin(path) }
                }
                Divider()
                Button("Copy path") { SystemActions.copyText(path) }
                Button("Open in Terminal") { SystemActions.openInTerminal(path) }
            }

            if isExpanded, let children {
                ForEach(children) { child in
                    FolderTreeNode(model: model, item: child, depth: depth + 1)
                }
            }
        }
        .onAppear {
            if isExpanded && children == nil {
                model.loadTreeChildren(for: path)
            }
        }
    }
}

// MARK: - Quick Link Node

private struct QuickLinkNode: View {
    @ObservedObject var model: ExplorerModel
    let link: QuickLink
    let unpinnable: Bool

    private var path: String { link.path }
    private var isFolder: Bool { path != PathUtils.home }
    private var isExpanded: Bool { isFolder && model.isTreeExpanded(path) }
    private var children: [FileItem]? { isFolder ? model.treeChildren[path] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavRow(
                model: model,
                name: link.name,
                path: path,
                image: IconProvider.shared.quickLinkIcon(link),
                symbol: nil,
                depth: 0,
                expandable: isFolder && children?.isEmpty != true,
                expanded: isExpanded,
                onToggle: { model.toggleTreeExpanded(path) }
            )
            .id("qa:" + path)
            .contextMenu {
                Button("Open in new tab") { model.openInNewTab(path) }
                Button("Open in new window") { WindowRegistry.shared.open([path]) }
                Divider()
                if unpinnable {
                    Button("Unpin from Quick access") { model.unpin(path) }
                } else if !model.isPinned(path) && path != PathUtils.home {
                    Button("Pin to Quick access") { model.pin(path) }
                }
                if isFolder {
                    Divider()
                    Button("Copy path") { SystemActions.copyText(path) }
                    Button("Open in Terminal") { SystemActions.openInTerminal(path) }
                }
            }

            if isExpanded, let children {
                ForEach(children) { child in
                    FolderTreeNode(model: model, item: child, depth: 1)
                }
            }
        }
        .onAppear {
            if isExpanded && children == nil {
                model.loadTreeChildren(for: path)
            }
        }
    }
}

// MARK: - Cloud Root Node

private struct CloudRootNode: View {
    @ObservedObject var model: ExplorerModel
    let root: CloudRoot

    private var path: String { root.root }
    private var isExpanded: Bool { model.isTreeExpanded(path) }
    private var children: [FileItem]? { model.treeChildren[path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavRow(
                model: model,
                name: root.label,
                path: path,
                image: nil,
                symbol: "cloud",
                depth: 0,
                expandable: children?.isEmpty != true,
                expanded: isExpanded,
                onToggle: { model.toggleTreeExpanded(path) }
            )
            .id("cloud:" + path)
            .contextMenu {
                Button("Open in new tab") { model.openInNewTab(path) }
                Button("Open in new window") { WindowRegistry.shared.open([path]) }
                Divider()
                if !model.isPinned(path) {
                    Button("Pin to Quick access") { model.pin(path) }
                }
                Divider()
                Button("Copy path") { SystemActions.copyText(path) }
                Button("Open in Terminal") { SystemActions.openInTerminal(path) }
            }

            if isExpanded, let children {
                ForEach(children) { child in
                    FolderTreeNode(model: model, item: child, depth: 1)
                }
            }
        }
        .onAppear {
            if isExpanded && children == nil {
                model.loadTreeChildren(for: path)
            }
        }
    }
}

// MARK: - Category

private struct CategorySection: View {
    @ObservedObject var model: ExplorerModel
    let category: SidebarCategory

    @State private var name = ""
    @State private var dropTargeted = false
    @FocusState private var nameFocused: Bool

    private var renaming: Bool { model.renamingCategoryID == category.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { model.toggleCategory(category.id) } label: {
                    Image(systemName: category.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain).frame(width: 14)

                if renaming {
                    TextField("Category", text: $name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onExitCommand { model.renamingCategoryID = nil }
                        .onAppear { name = category.name; nameFocused = true }
                } else {
                    Text(category.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6).padding(.top, 10).padding(.bottom, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(dropTargeted ? Color.accentColor.opacity(0.25) : .clear))
            .contextMenu {
                Button("Rename") { model.renamingCategoryID = category.id }
                Button("Delete category", role: .destructive) { model.deleteCategory(category.id) }
            }
            .dropDestination(for: URL.self, action: { urls, _ in
                let paths = urls.filter(\.isFileURL).map(\.path)
                guard !paths.isEmpty else { return false }
                model.addToCategory(category.id, paths: paths)
                return true
            }, isTargeted: { dropTargeted = $0 })

            if !category.collapsed {
                ForEach(category.paths, id: \.self) { path in
                    NavRow(model: model, name: PathUtils.basename(path), path: path, image: IconProvider.shared.folderIcon, symbol: nil, depth: 0)
                        .contextMenu {
                            Button("Remove from category") { model.removeFromCategory(category.id, path: path) }
                        }
                }
            }
        }
    }

    private func commit() {
        model.renameCategory(category.id, to: name)
        model.renamingCategoryID = nil
    }
}
