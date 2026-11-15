import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Native icons and Quick Look thumbnails behind small bounded caches.
///
/// Memory strategy: type icons are cached per extension (not per file), thumbnails live in an
/// `NSCache` with a byte budget, and only images/videos/PDFs ask Quick Look for a thumbnail.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private let typeIcons = NSCache<NSString, NSImage>()
    private let pathIcons = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()

    private init() {
        typeIcons.countLimit = 256
        pathIcons.countLimit = 256
        thumbnails.totalCostLimit = 48 * 1024 * 1024
    }

    /// Icon for a type or app. Shared instances: never mutate their `size`.
    func icon(for item: FileItem) -> NSImage {
        // Apps carry their own artwork; everything else shares a per-extension icon.
        if item.kind == .app || item.isSymbolicLink {
            return cached(pathIcons, key: item.path) { NSWorkspace.shared.icon(forFile: item.path) }
        }
        if item.isDirectory { return folderIcon }
        let key = "ext:" + item.ext + ":" + item.kind.rawValue
        return cached(typeIcons, key: key) {
            IconThemeManager.shared.fileIcon(forExtension: item.ext, kind: item.kind)
        }
    }

    var folderIcon: NSImage {
        cached(typeIcons, key: "dir_closed") { IconThemeManager.shared.folderIcon(isOpen: false) }
    }

    var folderOpenIcon: NSImage {
        cached(typeIcons, key: "dir_open") { IconThemeManager.shared.folderIcon(isOpen: true) }
    }

    func icon(forVolume path: String) -> NSImage {
        cached(pathIcons, key: "vol:" + path) { IconThemeManager.shared.driveIcon() }
    }

    func quickLinkIcon(_ link: QuickLink) -> NSImage {
        cached(pathIcons, key: "ql:" + link.name) {
            IconThemeManager.shared.quickLinkIcon(name: link.name, icon: link.icon)
        }
    }

    func reloadTheme() {
        typeIcons.removeAllObjects()
        pathIcons.removeAllObjects()
        IconThemeManager.shared.clearCache()
    }

    private func cached(_ cache: NSCache<NSString, NSImage>, key: String, make: () -> NSImage) -> NSImage {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let image = make()
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: Thumbnails

    /// Callback flavour for recycled collection cells; returns a request to cancel on reuse.
    /// Returns nil (and calls nothing) when the kind doesn't warrant a thumbnail.
    @discardableResult
    func thumbnail(for item: FileItem, points: CGFloat, scale: CGFloat,
                   completion: @escaping @MainActor (NSImage) -> Void) -> QLThumbnailGenerator.Request? {
        guard FileKinds.thumbnailKinds.contains(item.kind), !item.isDirectory else { return nil }
        let key = Self.key(item, points) as NSString
        if let hit = thumbnails.object(forKey: key) {
            completion(hit)
            return nil
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path), size: CGSize(width: points, height: points),
            scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            Task { @MainActor in
                self?.thumbnails.setObject(image, forKey: key, cost: Int(points * points * scale * scale * 4))
                completion(image)
            }
        }
        return request
    }

    func cancel(_ request: QLThumbnailGenerator.Request?) {
        if let request { QLThumbnailGenerator.shared.cancel(request) }
    }

    /// Async flavour for SwiftUI (`.task`), which cancels with the view.
    func thumbnail(for item: FileItem, points: CGFloat, scale: CGFloat) async -> NSImage? {
        guard FileKinds.thumbnailKinds.contains(item.kind), !item.isDirectory else { return nil }
        let key = Self.key(item, points) as NSString
        if let hit = thumbnails.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path), size: CGSize(width: points, height: points),
            scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        thumbnails.setObject(image, forKey: key, cost: Int(points * points * scale * scale * 4))
        return image
    }

    private static func key(_ item: FileItem, _ points: CGFloat) -> String {
        "\(item.path)|\(Int(points))|\(Int(item.modified))"
    }
}
