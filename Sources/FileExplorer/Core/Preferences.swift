import Foundation

enum IconThemeID: String, Codable, CaseIterable, Identifiable {
    case windows = "windows"
    case mac = "mac"
    case ubuntu = "ubuntu"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Windows"
        case .mac: return "Mac"
        case .ubuntu: return "Ubuntu"
        case .custom: return "Custom"
        }
    }

    static var builtInCases: [IconThemeID] {
        [.windows, .mac, .ubuntu]
    }
}

/// Remembers the user's active session across launches.
struct SavedSession: Codable, Equatable {
    var tabs: [Tab] = []
    var activeTabIndex: Int = 0
    var currentPath: String = PathUtils.home
    var viewMode: ViewMode = .details
    var previewOpen: Bool = false
    var navigationPaneOpen: Bool = true
    var sortKey: SortKey = .name
    var sortDirection: SortDirection = .ascending
    var groupBy: GroupKey = .none
    var treeExpandedPaths: [String] = []

    init(
        tabs: [Tab] = [],
        activeTabIndex: Int = 0,
        currentPath: String = PathUtils.home,
        viewMode: ViewMode = .details,
        previewOpen: Bool = false,
        navigationPaneOpen: Bool = true,
        sortKey: SortKey = .name,
        sortDirection: SortDirection = .ascending,
        groupBy: GroupKey = .none,
        treeExpandedPaths: [String] = []
    ) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.currentPath = currentPath
        self.viewMode = viewMode
        self.previewOpen = previewOpen
        self.navigationPaneOpen = navigationPaneOpen
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.groupBy = groupBy
        self.treeExpandedPaths = treeExpandedPaths
    }
}

/// Everything remembered between launches. Decoding tolerates missing keys so older
/// preference blobs keep working when fields are added.
struct Prefs: Codable, Equatable {
    var pinnedLinks: [QuickLink] = []
    var categories: [SidebarCategory] = []
    var previewOpen = false
    var navigationPaneOpen = true
    var quickAccessCollapsed = false
    var thisPCCollapsed = false
    var iconTheme: IconThemeID = .windows
    var customIconThemePath: String? = nil
    var previewWidth: Double = 300
    var sidebarWidth: Double = 240
    var groupBy: GroupKey = .none
    var columnWidths: [String: Double] = [:]
    var viewMode: ViewMode = .details
    var sortKey: SortKey = .name
    var sortDirection: SortDirection = .ascending
    var showHidden = false
    /// Most-recent first.
    var recents: [String] = []
    var restoreSession: Bool = true
    var lastSession: SavedSession? = nil

    static let previewRange: ClosedRange<Double> = 220...720
    static let sidebarRange: ClosedRange<Double> = 160...520
    static let maxRecents = 30

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        pinnedLinks = try c.decodeIfPresent([QuickLink].self, forKey: .pinnedLinks) ?? d.pinnedLinks
        categories = try c.decodeIfPresent([SidebarCategory].self, forKey: .categories) ?? d.categories
        previewOpen = try c.decodeIfPresent(Bool.self, forKey: .previewOpen) ?? d.previewOpen
        navigationPaneOpen = try c.decodeIfPresent(Bool.self, forKey: .navigationPaneOpen) ?? d.navigationPaneOpen
        quickAccessCollapsed = try c.decodeIfPresent(Bool.self, forKey: .quickAccessCollapsed) ?? d.quickAccessCollapsed
        thisPCCollapsed = try c.decodeIfPresent(Bool.self, forKey: .thisPCCollapsed) ?? d.thisPCCollapsed
        iconTheme = try c.decodeIfPresent(IconThemeID.self, forKey: .iconTheme) ?? d.iconTheme
        customIconThemePath = try c.decodeIfPresent(String.self, forKey: .customIconThemePath) ?? d.customIconThemePath
        previewWidth = try c.decodeIfPresent(Double.self, forKey: .previewWidth) ?? d.previewWidth
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        groupBy = try c.decodeIfPresent(GroupKey.self, forKey: .groupBy) ?? d.groupBy
        columnWidths = try c.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? d.columnWidths
        viewMode = try c.decodeIfPresent(ViewMode.self, forKey: .viewMode) ?? d.viewMode
        sortKey = try c.decodeIfPresent(SortKey.self, forKey: .sortKey) ?? d.sortKey
        sortDirection = try c.decodeIfPresent(SortDirection.self, forKey: .sortDirection) ?? d.sortDirection
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? d.showHidden
        recents = try c.decodeIfPresent([String].self, forKey: .recents) ?? d.recents
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? d.restoreSession
        lastSession = try c.decodeIfPresent(SavedSession.self, forKey: .lastSession) ?? d.lastSession
    }
}

protocol PreferencesStoring {
    func load() -> Prefs
    func save(_ prefs: Prefs)
}

struct UserDefaultsPreferencesStore: PreferencesStoring {
    var defaults: UserDefaults = .standard
    var key = "fe.prefs.v1"

    func load() -> Prefs {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Prefs.self, from: data) else { return Prefs() }
        return prefs
    }

    func save(_ prefs: Prefs) {
        if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: key) }
    }
}

/// One shared instance for all windows, so a pinned folder or a new category shows up
/// everywhere and windows never overwrite each other's settings. Saves are debounced.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var value: Prefs {
        didSet { if value != oldValue { scheduleSave() } }
    }

    private let store: PreferencesStoring
    private var saveTask: Task<Void, Never>?

    init(store: PreferencesStoring = UserDefaultsPreferencesStore()) {
        self.store = store
        self.value = store.load()
    }

    func flush() {
        saveTask?.cancel()
        store.save(value)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.save(self.value)
        }
    }
}
