import AppKit
import SwiftUI

// MARK: - Window plumbing

/// Hands the hosting `NSWindow` to SwiftUI once the view is attached.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}

/// Empty strip area that moves the window when dragged (the title bar is hidden).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// MARK: - Styling

/// Flat, hover-highlighted button used across the command and address bars.
struct FlatButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering && isEnabled ? 0.08 : 0)))
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(FlatButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

struct BarSeparator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }
}

// MARK: - Pane resize handle

/// Thin draggable divider. `invert` is true for a pane that grows when dragged leftwards.
struct ResizeHandle: View {
    let value: Double
    var invert = false
    let onChange: (Double) -> Void

    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let origin = start ?? value
                                start = origin
                                onChange(origin + Double(invert ? -drag.translation.width : drag.translation.width))
                            }
                            .onEnded { _ in start = nil }
                    )
            )
    }
}

// MARK: - Overlays

struct Toast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            .shadow(radius: 6, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct ProgressCard: View {
    let progress: OpProgress
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                Text("\(progress.op.verb) \(progress.total) item\(progress.total == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
            }

            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))

            HStack(spacing: 6) {
                Text("\(progress.done) of \(progress.total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !progress.name.isEmpty {
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(progress.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .shadow(radius: 8, y: 2)
    }
}

struct UpdateBanner: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        if let state = updates.state, let text = Self.text(for: state) {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(for: state))
                Text(text).font(.system(size: 12))
                if case .available(_, let url) = state {
                    Button("Download") { SystemActions.openWeb(url) }.controlSize(.small)
                }
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            .shadow(radius: 6, y: 2)
        }
    }

    private static func text(for state: UpdateState) -> String? {
        switch state {
        case .checking(let manual): return manual ? "Checking for updates…" : nil
        case .available(let version, _): return "Version \(version) is available."
        case .upToDate(let manual): return manual ? "You're up to date." : nil
        case .failed(let message, let manual): return manual ? "Update check failed: \(message)" : nil
        }
    }

    private static func symbol(for state: UpdateState) -> String {
        if case .available = state { return "arrow.down.circle" }
        if case .failed = state { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }
}
