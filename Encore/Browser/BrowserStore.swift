import SwiftUI
import WebKit

/// Owns every tab plus the pieces they share: cookies/logins (the default
/// website data store), the injected page script and the ad-block rule list.
@MainActor
final class BrowserStore: ObservableObject {
    static let home = URL(string: "https://m.youtube.com/")!
    static let youTubeMusic = URL(string: "https://music.youtube.com/")!

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: UUID?
    @Published var adBlockEnabled: Bool {
        didSet {
            guard adBlockEnabled != oldValue else { return }
            UserDefaults.standard.set(adBlockEnabled, forKey: Keys.adBlock)
            applyContentRules()
            installScripts()
            tabs.forEach { $0.reloadIfLoaded() }
        }
    }

    private let userContent = WKUserContentController()
    private let router = ScriptMessageRouter()
    private var ruleList: WKContentRuleList?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }

    private enum Keys {
        static let adBlock = "adBlockEnabled"
        static let sessionURLs = "session.urls"
        static let sessionSelected = "session.selected"
    }

    init() {
        adBlockEnabled = UserDefaults.standard.object(forKey: Keys.adBlock) as? Bool ?? true
        router.store = self
        userContent.add(router, name: "encore")
        installScripts()
        observeAppLifecycle()

        Task {
            ruleList = await AdBlocker.loadRuleList()
            applyContentRules()
            restoreSession()
        }
    }

    // MARK: - Tabs

    @discardableResult
    func openTab(url: URL?, select: Bool = true, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration ?? makeConfiguration(), store: self)
        tab.pendingURL = url
        if let current = selectedTab, let index = tabs.firstIndex(where: { $0 === current }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select { self.select(tab) }
        return tab
    }

    func select(_ tab: BrowserTab) {
        if let current = selectedTab, current !== tab { current.captureSnapshot() }
        selectedID = tab.id
        tab.loadPendingIfNeeded()
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        NowPlayingCenter.shared.mediaGone(from: tab)
        tab.teardown()
        tabs.remove(at: index)
        if tabs.isEmpty {
            openTab(url: Self.home)
        } else if selectedID == tab.id {
            select(tabs[min(index, tabs.count - 1)])
        }
    }

    func closeAllTabs() {
        for tab in tabs {
            NowPlayingCenter.shared.mediaGone(from: tab)
            tab.teardown()
        }
        tabs.removeAll()
        openTab(url: Self.home)
    }

    func newTab() { openTab(url: Self.home) }

    func open(_ url: URL) {
        if let tab = selectedTab { tab.load(url) } else { openTab(url: url) }
    }

    func goHome() { open(Self.home) }

    /// Handles text typed into the address bar: a URL, a bare domain or a search.
    func submit(_ text: String) {
        let onYouTube = selectedTab?.url?.host?.contains("youtube.com") ?? true
        guard let url = URLResolver.resolve(text, preferYouTube: onYouTube) else { return }
        open(url)
    }

    // MARK: - Lifecycle

    /// Extra signals for the page script's playback keeper. The page resumes
    /// iOS's background pause by itself; these just tell it a bit earlier
    /// that the app is leaving the screen (UIKit notifications arrive before
    /// WebKit pauses the video, unlike SwiftUI's scenePhase).
    private func observeAppLifecycle() {
        observe(UIApplication.willResignActiveNotification) { store in
            store.tabs.forEach { $0.run("prepareBackground()") }
        }
        observe(UIApplication.didEnterBackgroundNotification) { store in
            store.saveSession()
            store.enterBackground()
        }
        observe(UIApplication.didBecomeActiveNotification) { store in
            store.tabs.forEach { $0.run("setBackground(false)") }
        }
    }

    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (BrowserStore) -> Void) {
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let self { action(self) }
            }
        })
    }

    private func enterBackground() {
        tabs.forEach { $0.run("setBackground(true)") }

        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "encore.resume") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
        Task {
            for delay: UInt64 in [150, 400, 800, 1_300, 2_000] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard UIApplication.shared.applicationState == .background else { break }
                tabs.forEach { $0.run("kick()") }
            }
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func saveSession() {
        let urls = tabs.map { ($0.webView.url ?? $0.pendingURL)?.absoluteString ?? Self.home.absoluteString }
        UserDefaults.standard.set(urls, forKey: Keys.sessionURLs)
        UserDefaults.standard.set(tabs.firstIndex { $0.id == selectedID } ?? 0, forKey: Keys.sessionSelected)
    }

    private func restoreSession() {
        // A tab that was showing a video comes back as YouTube home: nothing
        // starts playing by itself on launch.
        let urls = (UserDefaults.standard.stringArray(forKey: Keys.sessionURLs) ?? [])
            .compactMap { URL(string: $0) }
            .map { URLResolver.youTubeVideo($0) == nil ? $0 : Self.home }
        guard !urls.isEmpty else {
            openTab(url: Self.home)
            return
        }
        let restored = urls.map { openTab(url: $0, select: false) }
        let index = UserDefaults.standard.integer(forKey: Keys.sessionSelected)
        select(restored[min(max(index, 0), restored.count - 1)])
    }

    // MARK: - Web configuration

    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = Self.userAgentSuffix
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        return config
    }

    /// Makes sites (and Google sign-in) treat the app like Mobile Safari.
    private static var userAgentSuffix: String {
        let version = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(version) Mobile/15E148 Safari/604.1"
    }

    private func installScripts() {
        userContent.removeAllUserScripts()
        guard let url = Bundle.main.url(forResource: "encore", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        let prelude = "window.__encoreAdblock = \(adBlockEnabled);\n"
        userContent.addUserScript(WKUserScript(source: prelude + source,
                                               injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false))
    }

    private func applyContentRules() {
        userContent.removeAllContentRuleLists()
        if adBlockEnabled, let ruleList { userContent.add(ruleList) }
    }

    // MARK: - Page messages

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let webView = message.webView,
              let tab = tabs.first(where: { $0.webView === webView }),
              let body = message.body as? [String: Any],
              body["type"] as? String == "media" else { return }

        if body["event"] as? String == "gone" {
            tab.isPlayingMedia = false
            NowPlayingCenter.shared.mediaGone(from: tab)
        } else if let state = MediaState(body) {
            tab.isPlayingMedia = state.playing
            NowPlayingCenter.shared.update(state, from: tab)
        }
    }
}

/// Forwards page messages without the user content controller retaining the store.
@MainActor
private final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    weak var store: BrowserStore?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        store?.handle(message)
    }
}
