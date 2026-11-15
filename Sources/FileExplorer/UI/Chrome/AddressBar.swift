import SwiftUI

/// Back / Forward / Up / Refresh, breadcrumb-or-text address, and search-as-you-type.
struct AddressBar: View {
    @ObservedObject var model: ExplorerModel

    @State private var editing = false
    @State private var text = ""
    @State private var query = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Back (⌘[)") { model.goBack() }.disabled(!model.canGoBack)
            IconButton(symbol: "chevron.right", help: "Forward (⌘])") { model.goForward() }.disabled(!model.canGoForward)
            IconButton(symbol: "chevron.up", help: "Up (⌘↑)") { model.goUp() }.disabled(!model.canGoUp)
            IconButton(symbol: "arrow.clockwise", help: "Refresh (F5)") { model.refresh() }
            addressField
            searchField
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onChange(of: model.focusRequest) { request in
            guard let request else { return }
            switch request.target {
            case .address: beginEditing()
            case .search: searchFocused = true
            }
        }
        .onChange(of: model.searchQuery) { value in if value != query { query = value } }
        .onChange(of: query) { value in model.setSearchQuery(value) }
        .onChange(of: model.currentPath) { _ in editing = false }
        .onChange(of: addressFocused) { focused in
            if !focused { editing = false }
            model.isAddressEditing = focused
        }
    }

    // MARK: Address

    @ViewBuilder
    private var addressField: some View {
        Group {
            if editing {
                TextField("Path", text: $text)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit {
                        model.navigateTyped(text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .autocorrectionDisabled()
            } else {
                breadcrumbs
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(editing ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: editing ? 1.5 : 1))
    }

    private var breadcrumbs: some View {
        let segments = PathUtils.segments(model.currentPath, homeDir: model.homeDir)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Image(systemName: model.isHome ? "house" : "folder").foregroundStyle(.secondary).padding(.trailing, 6)
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        Button(segment.name) { model.navigate(to: segment.path) }
                            .buttonStyle(FlatButtonStyle())
                            .font(.system(size: 12))
                            .id(segment.id)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { beginEditing() }
            .onAppear { if let last = segments.last { proxy.scrollTo(last.id, anchor: .trailing) } }
            .onChange(of: model.currentPath) { _ in
                if let last = PathUtils.segments(model.currentPath, homeDir: model.homeDir).last { proxy.scrollTo(last.id, anchor: .trailing) }
            }
        }
    }

    private func beginEditing() {
        text = model.isHome ? "~" : model.currentPath
        editing = true
        DispatchQueue.main.async { addressFocused = true }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(PathUtils.displayName(model.currentPath, homeDir: model.homeDir))", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = "" }
                .disabled(model.isHome)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 230, height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }
}
