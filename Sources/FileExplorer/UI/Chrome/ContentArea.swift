import SwiftUI

/// Picks the Home page, the Details table, or the icon grid, and overlays load / error / empty states.
struct ContentArea: View {
    @ObservedObject var model: ExplorerModel

    var body: some View {
        ZStack {
            if model.isHome {
                HomeView(model: model)
            } else if let error = model.loadError {
                ErrorState(model: model, error: error)
            } else {
                list
                if model.items.isEmpty && !model.isLoading { EmptyState(searching: model.isSearchResults) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if model.isLoading { ProgressView().progressViewStyle(.linear).controlSize(.small) }
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.viewMode == .details { DetailsTableView(model: model) } else { IconGridView(model: model) }
    }
}

private struct EmptyState: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: searching ? "magnifyingglass" : "folder").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(searching ? "No items match your search." : "This folder is empty.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }
}

private struct ErrorState: View {
    @ObservedObject var model: ExplorerModel
    let error: FileOpError

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: error.isPermissionDenied ? "lock.fill" : "exclamationmark.triangle")
                .font(.system(size: 32)).foregroundStyle(.secondary)
            Text(error.message).font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 420)
            if error.isPermissionDenied {
                Text("Grant File Explorer access in System Settings › Privacy & Security › Full Disk Access.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Open Full Disk Access settings") { SystemActions.openFullDiskAccessSettings() }
            }
            Button("Try again") { model.refresh() }
        }
        .padding()
    }
}
