import AppKit
import Combine

enum FocusTarget { case address, search }

struct FocusRequest: Equatable {
    let target: FocusTarget
    let serial: Int
}

struct PropertiesTarget: Identifiable {
    let id: String   // path
}

struct FileClipboard {
    enum Mode { case copy, cut }
    var paths: [String]
    var mode: Mode
}

/// State and behaviour of one Explorer window. Plays the role the Zustand store played in
/// the Electron build: views observe it, AppKit lists call into it, disk work runs off the
/// main thread through `background(_:)`.
@MainActor
final class ExplorerModel: ObservableObject, Identifiable {
    let id = UUID()
    let homeDir: String
    let prefs: AppPreferences
    weak var window: NSWindow?

    private let fs: FileSystemService
    private let cloud: CloudService
    private let watcher = DirectoryWatcher()
    private var bag = Set<AnyCancellable>()
    private var started = false

    // MARK: Navigation
    @Published private(set) var tabs: [Tab]
    @Published private(set) var activeTabID: UUID
    @Published private(set) var currentPath = PathUtils.home

    // MARK: Contents
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var sections: [ItemSection] = []
    /// Bumped whenever `sections` changes; AppKit lists reload only when it moves.
    @Published private(set) var listVersion = 0
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: FileOpError?
    private(set) var visibleItems: [FileItem] = []
    /// Path → index in `visibleItems`; turns selection lookups into O(selection) instead of O(folder).
    private var indexByPath: [String: Int] = [:]
    private var loadTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?

    // MARK: Sidebar data
    @Published private(set) var quickLinks: [QuickLink] = []
    @Published private(set) var drives: [DriveItem] = []
    @Published private(set) var cloudRoots: [CloudRoot] = []
    @Published var renamingCategoryID: String?

    // MARK: Folder tree (Navigation pane)
    @Published var treeExpandedPaths: Set<String> = []
    @Published var treeChildren: [String: [FileItem]] = [:]
    @Published var treeLoadingPaths: Set<String> = []

    // MARK: Selection / clipboard / rename
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var clipboard: FileClipboard?
    @Published private(set) var osClipboardHasFiles = false
    @Published private(set) var renamingPath: String?
    private var pendingRenamePath: String?
    private var pendingSelectPath: String?

    // MARK: Search
    @Published private(set) var searchQuery = ""
    @Published private(set) var isSearchResults = false
    private var searchTask: Task<Void, Never>?

    // MARK: Transient UI
    @Published var pendingCompression: PendingCompression?
    @Published var pendingTransfer: PendingTransfer?
    @Published var propertiesTarget: PropertiesTarget?
    @Published private(set) var operation: OpProgress?
    private var activeOperationHandle: ProcessHandle?
    @Published private(set) var undoStack: [UndoEntry] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var focusRequest: FocusRequest?
    @Published var isAddressEditing = false
    private var statusTask: Task<Void, Never>?
    private var focusSerial = 0

    @MainActor
    init(prefs: AppPreferences? = nil, fs: FileSystemService = FileSystemService(), cloud: CloudService = CloudService()) {
        let prefs = prefs ?? AppPreferences.shared
        self.prefs = prefs
        self.fs = fs
        self.cloud = cloud
        self.homeDir = fs.homeDirectory

        var initialTabs: [Tab] = [Tab(path: PathUtils.home)]
        var initialActiveID: UUID = initialTabs[0].id
        var initialPath = PathUtils.home
        var initialTree: Set<String> = []

        if prefs.value.restoreSession, let session = prefs.value.lastSession, !session.tabs.isEmpty {
            let validTabs = session.tabs.filter { $0.path == PathUtils.home || fs.isDirectory($0.path) }
            if !validTabs.isEmpty {
                initialTabs = validTabs
                let targetIdx = min(max(0, session.activeTabIndex), validTabs.count - 1)
                initialActiveID = validTabs[targetIdx].id
                initialPath = validTabs[targetIdx].path
                initialTree = Set(session.treeExpandedPaths.filter { fs.isDirectory($0) })
            }
        }

        tabs = initialTabs
        activeTabID = initialActiveID
        currentPath = initialPath
        treeExpandedPaths = initialTree

        // Windows share preferences: forward changes, and re-sort when a list setting moves.
        prefs.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        prefs.$value
            .map { ItemOrdering.Settings(showHidden: $0.showHidden, sortKey: $0.sortKey,
                                         sortDirection: $0.sortDirection, groupBy: $0.groupBy) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] settings in self?.recompute(settings) }
            .store(in: &bag)

        watcher.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadCurrentDirectorySilently()
            }
        }
    }

    deinit {
        watcher.stop()
    }

    // MARK: - Settings (backed by shared preferences)

    var viewMode: ViewMode { prefs.value.viewMode }
    var sortKey: SortKey { prefs.value.sortKey }
    var sortDirection: SortDirection { prefs.value.sortDirection }
    var groupBy: GroupKey { prefs.value.groupBy }
    var showHidden: Bool { prefs.value.showHidden }
    var previewOpen: Bool { prefs.value.previewOpen }
    var navigationPaneOpen: Bool { prefs.value.navigationPaneOpen }
    var quickAccessCollapsed: Bool { prefs.value.quickAccessCollapsed }
    var thisPCCollapsed: Bool { prefs.value.thisPCCollapsed }
    var categories: [SidebarCategory] { prefs.value.categories }
    var pinnedLinks: [QuickLink] { prefs.value.pinnedLinks }
    var recents: [String] { prefs.value.recents }
    var iconTheme: IconThemeID { prefs.value.iconTheme }
    var customThemePath: String? { prefs.value.customIconThemePath }
    var customThemeName: String {
        guard let path = prefs.value.customIconThemePath, !path.isEmpty else { return "Custom" }
        return PathUtils.basename(path)
    }

    func toggleQuickAccess() { prefs.value.quickAccessCollapsed.toggle() }
    func toggleThisPC() { prefs.value.thisPCCollapsed.toggle() }

    func setIconTheme(_ theme: IconThemeID) {
        prefs.value.iconTheme = theme
        IconThemeManager.shared.setTheme(theme, customPath: prefs.value.customIconThemePath)
        IconProvider.shared.reloadTheme()
        listVersion += 1
        objectWillChange.send()
    }

    func chooseCustomIconTheme() {
        IconThemeManager.shared.chooseCustomFolder(window: window) { [weak self] path in
            guard let self, let path else { return }
            self.prefs.value.customIconThemePath = path
            self.setIconTheme(.custom)
        }
    }

    func openCustomIconsFolder() {
        IconThemeManager.shared.openCustomFolder()
    }

    // MARK: - Session Persistence

    var restoreSession: Bool {
        get { prefs.value.restoreSession }
        set {
            prefs.value.restoreSession = newValue
            if !newValue { prefs.value.lastSession = nil }
            objectWillChange.send()
        }
    }

    func toggleRestoreSession() {
        restoreSession.toggle()
        if restoreSession {
            saveSession()
        } else {
            prefs.value.lastSession = nil
            prefs.flush()
        }
    }

    func saveSession() {
        guard restoreSession else {
            prefs.value.lastSession = nil
            return
        }
        let activeIdx = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        let session = SavedSession(
            tabs: tabs,
            activeTabIndex: activeIdx,
            currentPath: currentPath,
            viewMode: viewMode,
            previewOpen: previewOpen,
            navigationPaneOpen: navigationPaneOpen,
            sortKey: sortKey,
            sortDirection: sortDirection,
            groupBy: groupBy,
            treeExpandedPaths: Array(treeExpandedPaths)
        )
        prefs.value.lastSession = session
        prefs.flush()
    }

    private var sessionSaveTask: Task<Void, Never>?
    func scheduleSessionSave() {
        guard restoreSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveSession()
        }
    }

    private var settings: ItemOrdering.Settings {
        ItemOrdering.Settings(showHidden: showHidden, sortKey: sortKey, sortDirection: sortDirection, groupBy: groupBy)
    }

    var isHome: Bool { currentPath == PathUtils.home }
    var activeTab: Tab { tabs.first { $0.id == activeTabID } ?? tabs[0] }
    /// Selected items in display order. Called from view bodies, so it must not scan the folder.
    var selectedItems: [FileItem] { selection.compactMap { indexByPath[$0] }.sorted().map { visibleItems[$0] } }
    /// The visible item at `path`, if any.
    func item(at path: String) -> FileItem? { indexByPath[path].map { visibleItems[$0] } }
    var canPaste: Bool { !isHome && (clipboard != nil || osClipboardHasFiles) }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        WindowRegistry.shared.register(self)
        refreshClipboardStatus()
        loadLocations()

        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshClipboardStatus()
                self?.reloadCurrentDirectorySilently()
            }.store(in: &bag)
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.didMountNotification).merge(with: ws.publisher(for: NSWorkspace.didUnmountNotification))
            .sink { [weak self] _ in self?.loadLocations() }.store(in: &bag)

        var startPath = currentPath
        if let env = ProcessInfo.processInfo.environment["FE_START_DIR"], fs.isDirectory(env) { startPath = env }
        let pending = WindowRegistry.shared.takePending()
        if let first = pending.first { startPath = first }
        navigate(to: startPath, replace: true)
        pending.dropFirst().forEach { newTab(path: $0) }

        for path in treeExpandedPaths {
            loadTreeChildren(for: path)
        }

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.saveSession() }.store(in: &bag)
    }

    private func loadLocations() {
        let fs = fs, cloud = cloud
        Task { [weak self] in
            let (links, drives, roots) = await Task.detached(priority: .utility) {
                (fs.quickLinks(), fs.drives(), cloud.scanRoots())
            }.value
            guard let self else { return }
            self.quickLinks = links.map { $0.icon == .home ? QuickLink(name: $0.name, path: PathUtils.home, icon: .home) : $0 }
            self.drives = drives
            self.cloudRoots = roots
        }
    }

    // MARK: - Background helper

    private func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, FileOpError> {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try work()) } catch { return .failure(FileOpError(wrapping: error)) }
        }.value
    }

    // MARK: - Loading

    func refresh() {
        if isSearchResults { runSearch() } else { load(currentPath) }
        reloadTreeBranch(for: currentPath)
        reloadTreeBranch(for: PathUtils.parent(currentPath))
    }

    /// Silently reloads the current directory when the filesystem watcher detects external changes.
    /// Does not show a progress spinner and preserves user selection if items still exist.
    func reloadCurrentDirectorySilently() {
        guard !isHome, !isSearchResults, fs.isDirectory(currentPath) else { return }
        let path = currentPath
        let fs = fs, settings = settings
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, FileOpError> in
                do {
                    let items = try fs.readDirectory(path)
                    return .success(Loaded.make(items, settings))
                } catch { return .failure(FileOpError(wrapping: error)) }
            }.value
            guard let self, !Task.isCancelled, self.currentPath == path else { return }
            switch result {
            case .success(let loaded):
                if loaded.items != self.items {
                    self.apply(loaded)
                    FileIndexWorker.shared.indexLoadedItems(loaded.items, in: path)   // also invalidates stale stats
                    self.reloadTreeBranch(for: path)
                }
            case .failure(let error):
                if !self.fs.isDirectory(path) {
                    self.fail(error)
                }
            }
        }
    }

    private func load(_ path: String) {
        loadTask?.cancel()
        if path == PathUtils.home {
            setLayout(.empty)
            isLoading = false; loadError = nil
            return
        }
        isLoading = true
        loadError = nil
        let fs = fs, settings = settings
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, FileOpError> in
                do {
                    let items = try fs.readDirectory(path)
                    return .success(Loaded.make(items, settings))
                } catch { return .failure(FileOpError(wrapping: error)) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let loaded):
                self.apply(loaded)
                FileIndexWorker.shared.indexLoadedItems(loaded.items, in: path)
            case .failure(let error): self.fail(error)
            }
        }
    }

    /// Items plus their sorted/grouped layout, computed together off the main thread.
    private struct Loaded: Sendable {
        let items: [FileItem]
        let visible: [FileItem]
        let sections: [ItemSection]
        let indexByPath: [String: Int]
        /// The settings this layout was computed with.
        let settings: ItemOrdering.Settings?

        static let empty = Loaded(items: [], visible: [], sections: [], indexByPath: [:], settings: nil)

        static func make(_ items: [FileItem], _ s: ItemOrdering.Settings) -> Loaded {
            let visible = ItemOrdering.visible(items, showHidden: s.showHidden, sortKey: s.sortKey, direction: s.sortDirection)
            var index = [String: Int](minimumCapacity: visible.count)
            for (i, item) in visible.enumerated() { index[item.path] = i }
            return Loaded(items: items, visible: visible, sections: ItemOrdering.sections(visible, groupBy: s.groupBy),
                          indexByPath: index, settings: s)
        }
    }

    /// Folders up to this size are re-sorted inline (no visible lag); larger ones off the main thread.
    private static let inlineLayoutLimit = 2_000

    private func setLayout(_ loaded: Loaded) {
        layoutTask?.cancel()
        items = loaded.items
        visibleItems = loaded.visible
        sections = loaded.sections
        indexByPath = loaded.indexByPath
        listVersion += 1
    }

    private func apply(_ loaded: Loaded) {
        setLayout(loaded)
        isLoading = false
        loadError = nil
        if let pending = pendingRenamePath {
            pendingRenamePath = nil
            if indexByPath[pending] != nil {
                selection = [pending]
                renamingPath = pending
            }
        } else if let toSelect = pendingSelectPath {
            pendingSelectPath = nil
            if indexByPath[toSelect] != nil {
                selection = [toSelect]
            }
        }
        let stillVisible = selection.filter { indexByPath[$0] != nil }
        if stillVisible.count != selection.count { selection = stillVisible }
        // Sort/group/hidden settings changed while this was loading: lay it out again.
        if loaded.settings != settings { recompute(settings) }
    }

    private func fail(_ error: FileOpError) {
        setLayout(.empty)
        isLoading = false
        loadError = error
    }

    private func recompute(_ s: ItemOrdering.Settings) {
        let items = items
        if items.count <= Self.inlineLayoutLimit {
            setLayout(Loaded.make(items, s))
            return
        }
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Loaded.make(items, s) }.value
            guard let self, !Task.isCancelled else { return }
            self.setLayout(loaded)
        }
    }

    // MARK: - Navigation

    func navigate(to path: String, replace: Bool = false, select: String? = nil) {
        pendingSelectPath = select
        updateActiveTab { tab in
            if replace { tab.history[tab.index] = path }
            else {
                tab.history = Array(tab.history.prefix(tab.index + 1)) + [path]
                tab.index = tab.history.count - 1
            }
        }
        show(path, select: select)
    }

    private func show(_ path: String, select: String? = nil) {
        currentPath = path
        selection = select.map { [$0] } ?? []
        pendingSelectPath = select
        renamingPath = nil
        isAddressEditing = false
        cancelSearch(reload: false)
        load(path)
        if path == PathUtils.home {
            watcher.stop()
        } else {
            watcher.watch(path: path)
        }
        syncTreeToOpenedFolder(path)
        scheduleSessionSave()
    }

    /// From search results: opens the original folder location and selects the target file.
    func openOriginalLocation(for path: String) {
        let parent = PathUtils.parent(path)
        guard fs.isDirectory(parent) else { return }
        cancelSearch(reload: false)
        navigate(to: parent, select: path)
    }

    var canGoBack: Bool { activeTab.index > 0 }
    var canGoForward: Bool { activeTab.index < activeTab.history.count - 1 }
    var canGoUp: Bool { !isHome && currentPath != "/" }

    func goBack() {
        guard canGoBack else { return }
        updateActiveTab { $0.index -= 1 }
        show(activeTab.path)
    }

    func goForward() {
        guard canGoForward else { return }
        updateActiveTab { $0.index += 1 }
        show(activeTab.path)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: PathUtils.parent(currentPath))
    }

    func goHome() { navigate(to: PathUtils.home) }

    /// Address-bar submit: expands "~", rejects missing folders with a message.
    func navigateTyped(_ text: String) {
        let path = PathUtils.resolveTyped(text, homeDir: homeDir, currentPath: currentPath)
        if fs.isDirectory(path) { navigate(to: path) }
        else if fs.exists(path) { navigate(to: PathUtils.parent(path)); selection = [path] }
        else { flash("Can't find \"\(PathUtils.basename(path))\". Check the spelling and try again.") }
        isAddressEditing = false
    }

    private func updateActiveTab(_ body: (inout Tab) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        body(&tabs[i])
    }

    // MARK: - Tabs

    func newTab(path: String? = nil) {
        let tab = Tab(path: path ?? PathUtils.home)
        tabs.append(tab)
        activeTabID = tab.id
        show(tab.path)
        scheduleSessionSave()
    }

    /// Opens in the background, like a browser's middle-click.
    func openInNewTab(_ path: String) {
        tabs.append(Tab(path: path))
        scheduleSessionSave()
    }

    func duplicateActiveTab() { newTab(path: currentPath) }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        let wasActive = id == activeTabID
        tabs.remove(at: idx)
        if wasActive {
            let next = tabs[min(idx, tabs.count - 1)]
            activeTabID = next.id
            show(next.path)
        }
        scheduleSessionSave()
    }

    func closeOtherTabs(keeping id: UUID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        if activeTabID != id { activeTabID = id; show(keep.path) }
        scheduleSessionSave()
    }

    func setActiveTab(_ id: UUID) {
        guard id != activeTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        show(tab.path)
        scheduleSessionSave()
    }

    // MARK: - Selection

    func setSelection(_ paths: Set<String>) { if paths != selection { selection = paths } }
    func selectOne(_ path: String) { selection = [path] }
    func selectAll() { selection = Set(visibleItems.map(\.path)) }
    func selectNone() { selection = [] }
    func invertSelection() { selection = Set(visibleItems.map(\.path)).subtracting(selection) }

    /// Selection a context menu should act on: the clicked item joins the selection if it
    /// isn't already part of it (same rule as Explorer).
    func contextSelection(for path: String) -> [String] {
        if !selection.contains(path) { selection = [path] }
        return Array(selection)
    }

    // MARK: Type-ahead (icon views; the table has native type-select)
    private var typeBuffer = ""
    private var typeTime = Date.distantPast

    func typeAhead(_ characters: String) {
        guard !visibleItems.isEmpty else { return }
        let now = Date()
        let expired = now.timeIntervalSince(typeTime) > 0.8
        typeTime = now
        var cycle = false
        if expired { typeBuffer = characters }
        else if typeBuffer.lowercased() == characters.lowercased() { typeBuffer = characters; cycle = true }
        else { typeBuffer += characters }
        let needle = typeBuffer.lowercased()
        var current = -1
        if selection.count == 1, let selected = selection.first, let idx = indexByPath[selected] { current = idx }
        let start = cycle ? (current + 1 + visibleItems.count) % visibleItems.count : 0
        for k in 0..<visibleItems.count {
            let idx = (start + k) % visibleItems.count
            if visibleItems[idx].name.lowercased().hasPrefix(needle) { selection = [visibleItems[idx].path]; return }
        }
    }

    func selectFirst() { if let f = visibleItems.first { selection = [f.path] } }
    func selectLast() { if let l = visibleItems.last { selection = [l.path] } }

    // MARK: - Opening

    func openItem(_ item: FileItem) {
        recordRecent(item.path)
        if item.opensAsFolder { navigate(to: item.path) }
        else if let error = SystemActions.open(item.path) { flash(error) }
    }

    func openSelection() {
        let chosen = selectedItems
        if chosen.count == 1 { openItem(chosen[0]) }
        else { chosen.filter { !$0.isDirectory || $0.kind == .app }.forEach(openItem) }
    }

    func openWithSelection() {
        guard let first = selection.first else { return }
        Task { if let error = await SystemActions.openWith(first) { flash(error) } }
    }

    func revealInFinder(_ path: String? = nil) {
        SystemActions.reveal(path ?? selection.first ?? currentPath)
    }

    func openTerminal(at path: String? = nil) {
        let target = path ?? currentPath
        SystemActions.openInTerminal(target == PathUtils.home ? homeDir : target)
    }

    func copyPaths() {
        let paths = Array(selection).sorted()
        SystemActions.copyText(paths.isEmpty ? currentPath : paths.joined(separator: "\n"))
        flash("Path copied")
    }

    func share(from view: NSView) { SystemActions.share(Array(selection), relativeTo: view) }

    // MARK: - Clipboard

    func copySelection() {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        clipboard = FileClipboard(paths: paths, mode: .copy)
        osClipboardHasFiles = true
        SystemActions.writeFiles(paths)
    }

    func cutSelection() {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        clipboard = FileClipboard(paths: paths, mode: .cut)
        osClipboardHasFiles = true
        // Other apps have no "cut"; pasting there behaves like a copy.
        SystemActions.writeFiles(paths)
    }

    func paste() {
        guard !isHome else { return }
        // The OS pasteboard is the source of truth, so files copied in Finder paste here too.
        // Our own clipboard only upgrades a paste of our own cut to a move.
        let os = SystemActions.readFiles()
        let paths = os.isEmpty ? (clipboard?.paths ?? []) : os
        guard !paths.isEmpty else { return }
        let isOwn = clipboard.map { Set($0.paths) == Set(paths) } ?? false
        let isCut = isOwn && clipboard?.mode == .cut
        performTransfer(paths, to: currentPath, op: isCut ? .move : .copy, clearCut: isCut)
    }

    func refreshClipboardStatus() { osClipboardHasFiles = !SystemActions.readFiles().isEmpty }

    // MARK: - Transfers

    /// What a drop should do: ⌃ (Ctrl) or ⌥ (Option) copies; otherwise a move on the same volume and a copy elsewhere.
    func dropOperation(sources: [String], destination: String, copyModifier: Bool) -> OpKind {
        if copyModifier { return .copy }
        guard let first = sources.first else { return .copy }
        return fs.sameVolume(first, destination) ? .move : .copy
    }

    func dropOperation(sources: [String], destination: String, optionDown: Bool) -> OpKind {
        dropOperation(sources: sources, destination: destination, copyModifier: optionDown)
    }

    /// False for drops that can't do anything (onto itself, move into the same folder).
    func canAccept(sources: [String], destination: String, op: OpKind) -> Bool {
        guard destination != PathUtils.home, !sources.isEmpty else { return false }
        let dest = PathUtils.standardized(destination)
        for src in sources.map(PathUtils.standardized) {
            if PathUtils.isInside(dest, root: src) { return false }
            if op == .move && PathUtils.parent(src) == dest { return false }
        }
        return true
    }

    func performTransfer(_ sources: [String], to destination: String, op: OpKind, clearCut: Bool = false) {
        guard !sources.isEmpty, destination != PathUtils.home else { return }
        let conflicts = fs.conflicts(sources: sources, destination: destination)
        if conflicts.isEmpty {
            runTransfer(sources, destination, op, .keepBoth, clearCut)
        } else {
            pendingTransfer = PendingTransfer(sources: sources, destination: destination, op: op,
                                              conflicts: conflicts, clearCut: clearCut)
        }
    }

    /// `nil` cancels.
    func resolveConflict(_ policy: ConflictPolicy?) {
        guard let pending = pendingTransfer else { return }
        pendingTransfer = nil
        guard let policy else { return }
        runTransfer(pending.sources, pending.destination, pending.op, policy, pending.clearCut)
    }

    private func runTransfer(_ sources: [String], _ destination: String, _ op: OpKind,
                             _ policy: ConflictPolicy, _ clearCut: Bool) {
        operation = OpProgress(op: op, done: 0, total: sources.count, name: "")
        let fs = fs
        let sink = progressSink()
        Task { [weak self] in
            let result = await self?.background { try fs.transfer(op, sources: sources, to: destination, policy: policy, progress: sink) }
            guard let self, let result else { return }
            self.operation = nil
            if clearCut { self.clipboard = nil; self.osClipboardHasFiles = false; SystemActions.clearPasteboard() }
            switch result {
            case .failure(let error): self.flash(error.message)
            case .success(let done) where !done.moves.isEmpty:
                self.record(op == .move ? .move(done.moves) : .copy(created: done.moves.map(\.to)))
            case .success: break
            }
            self.refresh()
        }
    }

    private func progressSink() -> @Sendable (OpProgress) -> Void {
        { [weak self] progress in Task { @MainActor in self?.updateProgress(progress) } }
    }

    private func updateProgress(_ p: OpProgress) { if operation != nil { operation = p } }

    // MARK: - Undo

    private func record(_ entry: UndoEntry) { undoStack = Array((undoStack + [entry]).suffix(50)) }

    func undo() {
        guard let entry = undoStack.last else { flash("Nothing to undo"); return }
        undoStack.removeLast()
        let fs = fs
        Task { [weak self] in
            let result: Result<Void, FileOpError>? = await self?.background {
                switch entry {
                case .rename(let from, let to): _ = try fs.rename(to, to: PathUtils.basename(from))
                case .move(let moves): try fs.restore(moves.map { FileMove(from: $0.from, to: $0.to) })
                case .trash(let moves): try fs.restore(moves)
                case .copy(let created):
                    let r = fs.trash(created)
                    if !r.failed.isEmpty { throw FileOpError("Couldn't undo: \(r.failed.joined(separator: ", "))") }
                }
            }
            if case .failure(let error)? = result { self?.flash(error.message) }
            self?.refresh()
        }
    }

    // MARK: - Rename / create / delete

    func beginRename(_ path: String? = nil) {
        guard let target = path ?? (selection.count == 1 ? selection.first : nil) else { return }
        selection = [target]
        renamingPath = target
    }

    func cancelRename() { renamingPath = nil }

    func commitRename(_ newName: String) {
        guard let target = renamingPath else { return }
        renamingPath = nil
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, newName != PathUtils.basename(target) else { return }
        let fs = fs
        Task { [weak self] in
            guard let result = await self?.background({ try fs.rename(target, to: newName) }) else { return }
            switch result {
            case .failure(let error): self?.flash(error.message)
            case .success(let item):
                self?.record(.rename(from: target, to: item.path))
                self?.selection = [item.path]
                FileIndexWorker.shared.removeEntry(at: target)
                if let dir = self?.currentPath { FileIndexWorker.shared.invalidateFolderStats(for: dir) }
            }
            self?.refresh()
        }
    }

    func createFolder() { create("New folder") { try $0.createFolder(in: $1, name: $2) } }
    func createTextFile() { create("New Text Document.txt") { try $0.createTextFile(in: $1, name: $2) } }

    private func create(_ name: String, _ make: @escaping @Sendable (FileSystemService, String, String) throws -> FileItem) {
        guard !isHome else { flash("Can't create items on the Home page"); return }
        let fs = fs, dir = currentPath
        Task { [weak self] in
            guard let result = await self?.background({ try make(fs, dir, name) }) else { return }
            switch result {
            case .failure(let error): self?.flash(error.message)
            case .success(let item):
                self?.pendingRenamePath = item.path
                FileIndexWorker.shared.invalidateFolderStats(for: dir)
                self?.refresh()
            }
        }
    }

    func deleteSelection() {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        let fs = fs
        Task { [weak self] in
            guard let result = await self?.background({ fs.trash(paths) }), let self else { return }
            if case .success(let r) = result {
                if !r.moves.isEmpty { self.record(.trash(r.moves)) }
                if !r.failed.isEmpty { self.flash("Couldn't delete: \(r.failed.joined(separator: ", "))") }
                paths.forEach { FileIndexWorker.shared.removeEntry(at: $0) }
                FileIndexWorker.shared.invalidateFolderStats(for: self.currentPath)
            }
            self.selection = []
            self.refresh()
        }
    }

    // MARK: - Archives

    func cancelOperation() {
        activeOperationHandle?.cancel()
        activeOperationHandle = nil
        operation = nil
        refresh()
    }

    func compressSelection() {
        let paths = Array(selection)
        guard !paths.isEmpty, !isHome else { return }
        let first = paths[0]
        let parent = PathUtils.parent(first)
        guard paths.allSatisfy({ PathUtils.parent($0) == parent }) else {
            flash("Select items from a single folder to compress them.")
            return
        }
        let defaultBase: String
        if paths.count == 1 {
            let base = PathUtils.basename(first)
            defaultBase = (base as NSString).deletingPathExtension
        } else {
            defaultBase = "Archive"
        }
        pendingCompression = PendingCompression(
            sources: paths,
            destination: currentPath,
            baseName: defaultBase.isEmpty ? "Archive" : defaultBase,
            format: .zip,
            level: .medium
        )
    }

    func startCompression(
        sources: [String],
        destination: String,
        name: String,
        format: ArchiveFormat,
        level: CompressionLevel
    ) {
        guard !sources.isEmpty else { return }
        let handle = ProcessHandle()
        activeOperationHandle = handle
        operation = OpProgress(op: .compress, done: 0, total: sources.count, name: "")
        let fs = fs
        let sink = progressSink()
        Task { [weak self] in
            let result = await self?.background({
                try fs.compressArchive(
                    sources,
                    into: destination,
                    archiveName: name,
                    format: format,
                    level: level,
                    handle: handle,
                    progress: sink
                )
            })
            guard let self else { return }
            self.activeOperationHandle = nil
            self.operation = nil
            guard let result else { return }
            switch result {
            case .failure(let error):
                if error.message != "Compression cancelled." {
                    self.flash(error.message)
                }
            case .success(let item):
                self.selection = [item.path]
            }
            self.refresh()
        }
    }

    func extractSelection() {
        let archives = selectedItems.filter { $0.ext == "zip" }
        guard !archives.isEmpty else { flash("Select a .zip archive to extract"); return }
        operation = OpProgress(op: .extract, done: 0, total: archives.count, name: "")
        let fs = fs, dir = currentPath
        Task { [weak self] in
            for (index, archive) in archives.enumerated() {
                let result = await self?.background({ try fs.extractZip(archive.path, into: dir) })
                if case .failure(let error)? = result { self?.flash(error.message) }
                self?.operation = OpProgress(op: .extract, done: index + 1, total: archives.count, name: archive.name)
            }
            self?.operation = nil
            self?.refresh()
        }
    }

    // MARK: - Search

    func setSearchQuery(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            if isSearchResults { cancelSearch(reload: true) }
            return
        }
        // Search as you type, debounced (Windows Explorer behaviour).
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { self?.runSearch() }
        }
    }

    func runSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isHome else { return }
        watcher.stop()
        searchTask?.cancel()
        loadTask?.cancel()
        isSearchResults = true
        isLoading = true
        selection = []
        let root = currentPath, settings = settings
        searchTask = Task { [weak self] in
            let results = await FileIndexWorker.shared.search(root: root, query: query)
            let loaded = Loaded.make(results, settings)
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded)
        }
    }

    func cancelSearch(reload: Bool) {
        searchTask?.cancel()
        let was = isSearchResults || !searchQuery.isEmpty
        searchQuery = ""
        isSearchResults = false
        if reload && was {
            load(currentPath)
            if currentPath != PathUtils.home {
                watcher.watch(path: currentPath)
            }
        }
    }

    // MARK: - View settings

    func setViewMode(_ mode: ViewMode) {
        prefs.value.viewMode = mode
        scheduleSessionSave()
    }

    func setGroupBy(_ key: GroupKey) {
        prefs.value.groupBy = key
        scheduleSessionSave()
    }

    func toggleShowHidden() { prefs.value.showHidden.toggle() }

    func togglePreview() {
        prefs.value.previewOpen.toggle()
        scheduleSessionSave()
    }

    func toggleNavigationPane() {
        prefs.value.navigationPaneOpen.toggle()
        scheduleSessionSave()
    }

    func setSortDirection(_ direction: SortDirection) {
        prefs.value.sortDirection = direction
        scheduleSessionSave()
    }

    /// Same key flips direction; a new key starts with the useful default
    /// (newest / largest first for date and size).
    func setSort(_ key: SortKey) {
        if prefs.value.sortKey == key { prefs.value.sortDirection = prefs.value.sortDirection.toggled }
        else {
            prefs.value.sortKey = key
            prefs.value.sortDirection = (key == .modified || key == .size) ? .descending : .ascending
        }
        scheduleSessionSave()
    }

    func setColumnWidth(_ column: String, _ width: Double) {
        prefs.value.columnWidths[column] = max(60, width.rounded())
    }

    func setPreviewWidth(_ width: Double) {
        prefs.value.previewWidth = min(Prefs.previewRange.upperBound, max(Prefs.previewRange.lowerBound, width.rounded()))
    }

    func setSidebarWidth(_ width: Double) {
        prefs.value.sidebarWidth = min(Prefs.sidebarRange.upperBound, max(Prefs.sidebarRange.lowerBound, width.rounded()))
    }

    // MARK: - Sidebar: pins, categories, recents

    func isPinned(_ path: String) -> Bool { pinnedLinks.contains { $0.path == path } }

    func pin(_ path: String, name: String? = nil) {
        guard !isPinned(path) else { return }
        prefs.value.pinnedLinks.append(QuickLink(name: name ?? PathUtils.basename(path), path: path, icon: .documents))
    }

    func unpin(_ path: String) { prefs.value.pinnedLinks.removeAll { $0.path == path } }

    @discardableResult
    func addCategory(name: String? = nil, paths: [String] = []) -> String {
        let id = "cat-\(UUID().uuidString.prefix(8))"
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        prefs.value.categories.append(SidebarCategory(id: id, name: trimmed.isEmpty ? "New category" : trimmed,
                                                      paths: paths, collapsed: false))
        renamingCategoryID = id          // new categories open in rename mode, like a new folder
        return id
    }

    func renameCategory(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let i = prefs.value.categories.firstIndex(where: { $0.id == id }) {
            prefs.value.categories[i].name = trimmed
        }
        renamingCategoryID = nil
    }

    func deleteCategory(_ id: String) {
        prefs.value.categories.removeAll { $0.id == id }
        if renamingCategoryID == id { renamingCategoryID = nil }
    }

    func toggleCategory(_ id: String) {
        if let i = prefs.value.categories.firstIndex(where: { $0.id == id }) { prefs.value.categories[i].collapsed.toggle() }
    }

    func addToCategory(_ id: String, paths: [String]) {
        guard let i = prefs.value.categories.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(prefs.value.categories[i].paths)
        prefs.value.categories[i].paths += paths.filter { !existing.contains($0) }
    }

    func removeFromCategory(_ id: String, path: String) {
        if let i = prefs.value.categories.firstIndex(where: { $0.id == id }) {
            prefs.value.categories[i].paths.removeAll { $0 == path }
        }
    }

    func recordRecent(_ path: String) {
        guard path != PathUtils.home else { return }
        prefs.value.recents = Array(([path] + prefs.value.recents.filter { $0 != path }).prefix(Prefs.maxRecents))
    }

    func removeRecent(_ path: String) { prefs.value.recents.removeAll { $0 == path } }
    func clearRecents() { prefs.value.recents = [] }

    /// Resolves stored paths to live items, dropping ones that no longer exist.
    func resolve(_ paths: [String]) async -> [FileItem] {
        let fs = fs
        return await Task.detached(priority: .utility) { paths.compactMap { try? fs.fileItem(at: $0) } }.value
    }

    // MARK: - Folder tree helpers

    func isTreeExpanded(_ path: String) -> Bool {
        treeExpandedPaths.contains(path)
    }

    func toggleTreeExpanded(_ path: String) {
        if treeExpandedPaths.contains(path) {
            treeExpandedPaths.remove(path)
        } else {
            expandTreeNode(path)
        }
        scheduleSessionSave()
    }

    func expandTreeNode(_ path: String) {
        treeExpandedPaths.insert(path)
        loadTreeChildren(for: path)
        scheduleSessionSave()
    }

    func loadTreeChildren(for path: String, forceReload: Bool = false) {
        guard forceReload || treeChildren[path] == nil else { return }
        guard !treeLoadingPaths.contains(path) else { return }
        treeLoadingPaths.insert(path)
        Task { [weak self] in
            guard let self else { return }
            let children = await self.childFolders(of: path)
            self.treeLoadingPaths.remove(path)
            self.treeChildren[path] = children
        }
    }

    func reloadTreeBranch(for path: String) {
        guard treeChildren[path] != nil || treeExpandedPaths.contains(path) else { return }
        loadTreeChildren(for: path, forceReload: true)
    }

    func syncTreeToOpenedFolder(_ path: String) {
        guard path != PathUtils.home, path.hasPrefix("/") else { return }
        let ancestors = PathUtils.ancestors(of: path)
        guard !ancestors.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for ancestor in ancestors {
                self.treeExpandedPaths.insert(ancestor)
                if self.treeChildren[ancestor] == nil {
                    let children = await self.childFolders(of: ancestor)
                    self.treeChildren[ancestor] = children
                }
            }
        }
    }

    /// Child folders for the navigation tree (respects showHidden, no app bundles).
    func childFolders(of path: String) async -> [FileItem] {
        let fs = fs
        let showHidden = showHidden
        return await Task.detached(priority: .utility) {
            ((try? fs.readDirectory(path)) ?? [])
                .filter { $0.opensAsFolder && (showHidden || !$0.isHidden) }
                .sorted { ItemOrdering.compareNames($0, $1) < 0 }
        }.value
    }

    // MARK: - Cloud

    func cloudInfo(for path: String) -> CloudInfo? { cloud.info(for: path, roots: cloudRoots) }

    func openCloudOnWeb(_ path: String) {
        let isDir = fs.isDirectory(path)
        if let url = cloud.webURL(for: path, roots: cloudRoots, isDirectory: isDir) { SystemActions.openWeb(url) }
        else { flash("Not inside a Dropbox or OneDrive folder") }
    }

    func makeAvailableOffline(_ paths: [String]) {
        operation = OpProgress(op: .download, done: 0, total: 1, name: "")
        let cloud = cloud, sink = progressSink()
        Task { [weak self] in
            guard let result = await self?.background({ try cloud.makeAvailableOffline(paths, progress: sink) }), let self else { return }
            self.operation = nil
            switch result {
            case .failure(let error): self.flash(error.message)
            case .success(let n): self.flash("\(n) file\(n == 1 ? "" : "s") available offline")
            }
            self.refresh()
        }
    }

    // MARK: - Misc UI

    func showProperties(_ path: String? = nil) {
        propertiesTarget = PropertiesTarget(id: path ?? selection.first ?? (isHome ? homeDir : currentPath))
    }

    func requestFocus(_ target: FocusTarget) {
        focusSerial += 1
        focusRequest = FocusRequest(target: target, serial: focusSerial)
    }

    func flash(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.statusMessage = nil }
        }
    }

    /// Reading the properties pane/dialog needs the filesystem; exposed so views don't build services.
    func loadProperties(_ path: String) async -> PropertyInfo? {
        let fs = fs
        if case .success(let info) = await background({ try fs.properties(path) }) { return info }
        return nil
    }

    func loadFolderSize(_ path: String) async -> FolderSize? {
        let fs = fs
        return await Task.detached(priority: .utility) { fs.folderSize(path) }.value
    }

    func loadTextPreview(_ path: String) async -> String? {
        let fs = fs
        if case .success(let text) = await background({ try fs.readTextPreview(path) }) { return text }
        return nil
    }
}

/// Windows that exist, so the OS can hand a folder ("Open With", default handler) to the
/// one the user is looking at. Weak references: closing a window frees its model.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()

    private struct Box { weak var model: ExplorerModel? }
    private var boxes: [Box] = []
    private weak var active: ExplorerModel?
    private var pending: [String] = []

    func register(_ model: ExplorerModel) {
        boxes.removeAll { $0.model == nil }
        boxes.append(Box(model: model))
        active = model
    }

    func markActive(_ model: ExplorerModel) { active = model }

    func saveAllSessions() {
        boxes.compactMap(\.model).forEach { $0.saveSession() }
    }

    func takePending() -> [String] {
        defer { pending = [] }
        return pending
    }

    /// Opens each path in a new tab (a file opens its folder). Before any window exists,
    /// the first window picks them up in `start()`.
    func open(_ paths: [String]) {
        let folders = paths.map { path -> String in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && !isDir.boolValue ? PathUtils.parent(path) : path
        }
        guard let target = active ?? boxes.compactMap(\.model).last else { pending += folders; return }
        folders.forEach { target.newTab(path: $0) }
        target.window?.makeKeyAndOrderFront(nil)
    }
}
