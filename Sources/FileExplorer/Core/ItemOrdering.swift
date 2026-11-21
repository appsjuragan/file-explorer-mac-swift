import Foundation

/// Sorting, filtering and grouping of directory contents. Pure functions: easy to test
/// and safe to run off the main thread.
enum ItemOrdering {
    struct Settings: Equatable {
        var showHidden: Bool
        var sortKey: SortKey
        var sortDirection: SortDirection
        var groupBy: GroupKey
    }

    /// Hidden filter + sort. Folders always come first, ties fall back to name order
    /// in both directions (stable, predictable output instead of on-disk order).
    static func visible(_ items: [FileItem], showHidden: Bool, sortKey: SortKey,
                        direction: SortDirection) -> [FileItem] {
        let filtered = showHidden ? items : items.filter { !$0.isHidden }
        let sign = direction == .ascending ? 1 : -1
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var cmp = 0
            switch sortKey {
            case .name: cmp = compareNames(a, b)
            case .modified: cmp = threeWay(a.modified, b.modified)
            case .size: cmp = threeWay(a.size, b.size)
            case .type:
                cmp = threeWay(a.kind.rawValue, b.kind.rawValue)       // ASCII identifiers: no Foundation round-trip
                if cmp == 0 { cmp = a.ext.compare(b.ext).rawValue }
                if cmp == 0 { cmp = compareNames(a, b) }
            case .location:
                cmp = a.path.localizedStandardCompare(b.path).rawValue
                if cmp == 0 { cmp = compareNames(a, b) }
            }
            return cmp != 0 ? cmp * sign < 0 : compareNames(a, b) < 0
        }
    }

    /// Finder/Explorer-style natural order: "file2" < "file10", case-insensitive.
    static func compareNames(_ a: FileItem, _ b: FileItem) -> Int {
        a.name.localizedStandardCompare(b.name).rawValue
    }

    private static func threeWay<T: Comparable>(_ a: T, _ b: T) -> Int {
        a < b ? -1 : (a > b ? 1 : 0)
    }

    static func sections(_ visible: [FileItem], groupBy: GroupKey, now: Date = Date(),
                         calendar: Calendar = .current) -> [ItemSection] {
        guard groupBy != .none else { return [ItemSection(label: "", items: visible)] }
        // Calendar math once per layout, not once per item.
        let startOfToday = calendar.startOfDay(for: now).timeIntervalSince1970
        var buckets: [String: [FileItem]] = [:]
        var order: [String] = []
        for item in visible {
            let label = groupLabel(item, key: groupBy, startOfToday: startOfToday)
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(item)
        }
        return order.map { ItemSection(label: $0, items: buckets[$0] ?? []) }
    }

    static func groupLabel(_ item: FileItem, key: GroupKey, now: Date, calendar: Calendar) -> String {
        groupLabel(item, key: key, startOfToday: calendar.startOfDay(for: now).timeIntervalSince1970)
    }

    private static func groupLabel(_ item: FileItem, key: GroupKey, startOfToday: TimeInterval) -> String {
        switch key {
        case .none: return ""
        case .name:
            // Only the first character matters; don't upper-case the whole name.
            guard let c = item.name.first.flatMap({ String($0).uppercased().first }), c.isASCII, c.isLetter else { return "#" }
            return String(c)
        case .type: return item.isDirectory ? "Folders" : FileKinds.label(for: item)
        case .size: return sizeGroup(item.size, isDirectory: item.isDirectory)
        case .modified: return modifiedGroup(item.modified, startOfToday: startOfToday)
        }
    }

    static func sizeGroup(_ size: Int64, isDirectory: Bool) -> String {
        if isDirectory { return "Folders" }
        if size == 0 { return "Empty" }
        if size < 16 * 1024 { return "Tiny (0–16 KB)" }
        if size < 1024 * 1024 { return "Small (16 KB–1 MB)" }
        if size < 128 * 1024 * 1024 { return "Medium (1–128 MB)" }
        if size < 1024 * 1024 * 1024 { return "Large (128 MB–1 GB)" }
        return "Huge (> 1 GB)"
    }

    static func modifiedGroup(_ epoch: TimeInterval, now: Date, calendar: Calendar) -> String {
        modifiedGroup(epoch, startOfToday: calendar.startOfDay(for: now).timeIntervalSince1970)
    }

    private static func modifiedGroup(_ epoch: TimeInterval, startOfToday: TimeInterval) -> String {
        let day: TimeInterval = 86_400
        if epoch >= startOfToday { return "Today" }
        if epoch >= startOfToday - day { return "Yesterday" }
        if epoch >= startOfToday - 7 * day { return "Earlier this week" }
        if epoch >= startOfToday - 30 * day { return "Earlier this month" }
        if epoch >= startOfToday - 365 * day { return "Earlier this year" }
        return "A long time ago"
    }
}
