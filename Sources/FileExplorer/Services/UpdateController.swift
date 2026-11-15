import Foundation

/// Update check against GitHub Releases. Notify-only: it never downloads or runs code.
/// The banner opens the release page and the user installs the signed build themselves.
///
/// (The Electron build used electron-updater. A silent in-place updater should be Sparkle
/// with EdDSA-signed appcasts; that is a deliberate follow-up, not something to hand-roll.)
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var state: UpdateState?

    private let releasesURL = URL(string: "https://api.github.com/repos/file-explorer-mac/file-explorer-mac/releases/latest")!
    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Updates only make sense for an installed app; stay silent in `swift run` / tests.
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FE_NO_UPDATES"] == nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func checkOnLaunch() {
        guard isEnabled else { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        guard isEnabled else {
            if manual { show(.failed(message: "Updates are only available in the installed app.", manual: true)) }
            return
        }
        guard task == nil else { return }
        if manual { show(.checking(manual: true)) }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                let release = try await Self.fetchLatest(from: self.releasesURL)
                if Validation.isVersion(release.version, newerThan: self.currentVersion) {
                    self.show(.available(version: release.version, url: release.url))
                } else {
                    self.show(manual ? UpdateState.upToDate(manual: true) : nil)
                }
            } catch {
                self.show(manual ? UpdateState.failed(message: "Couldn't check for updates.", manual: true) : nil)
            }
        }
    }

    func dismiss() { state = nil }

    private func show(_ new: UpdateState?) {
        state = new
        dismissTask?.cancel()
        // Status messages fade out by themselves; an available update stays until dismissed.
        if let new, !isAvailable(new) {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { self?.state = nil }
            }
        }
    }

    private func isAvailable(_ s: UpdateState) -> Bool {
        if case .available = s { return true }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    private static func fetchLatest(from url: URL) async throws -> (version: String, url: URL) {
        let config = URLSessionConfiguration.ephemeral          // no cookies, no disk cache
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["Accept": "application/vnd.github+json"]
        let (data, response) = try await URLSession(configuration: config).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        // Only ever hand a github.com https page to the browser.
        guard let page = URL(string: release.html_url),
              Validation.isTrustedWebURL(page, allowedHostSuffixes: ["github.com"]) else {
            throw URLError(.badURL)
        }
        return (release.tag_name, page)
    }
}
