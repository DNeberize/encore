import SwiftUI
import WebKit

/// Owns every tab, the miniplayer, and the pieces they share: cookies/logins
/// (the default website data store), the injected page script and the
/// ad-block rule list.
@MainActor
final class BrowserStore: ObservableObject {
    static let home = URL(string: "https://m.youtube.com/")!
    static let youTubeMusic = URL(string: "https://music.youtube.com/")!

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: UUID?

    /// Videos play here, YouTube-app style: full screen when expanded, a bar
    /// above the toolbar when collapsed, while tabs keep their place.
    @Published private(set) var player: BrowserTab?
    @Published var playerExpanded = false

    @Published var adBlockEnabled: Bool {
        didSet {
            guard adBlockEnabled != oldValue else { return }
            UserDefaults.standard.set(adBlockEnabled, forKey: Keys.adBlock)
            applyContentRules()
            installScripts()
            allTabs.forEach { $0.reloadIfLoaded() }
        }
    }

    /// Normal tabs and the player get the same script, told which role they play.
    private let tabContent = WKUserContentController()
    private let playerContent = WKUserContentController()
    private let router = ScriptMessageRouter()
    private var ruleList: WKContentRuleList?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }

    private var allTabs: [BrowserTab] { player.map { tabs + [$0] } ?? tabs }

    private enum Keys {
        static let adBlock = "adBlockEnabled"
        static let sessionURLs = "session.urls"
        static let sessionSelected = "session.selected"
    }

    init() {
        adBlockEnabled = UserDefaults.standard.object(forKey: Keys.adBlock) as? Bool ?? true
        router.store = self
        tabContent.add(router, name: "encore")
        playerContent.add(router, name: "encore")
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
        if let video = URLResolver.youTubeVideo(url) {
            openVideo(video)
        } else if let tab = selectedTab {
            tab.load(url)
        } else {
            openTab(url: url)
        }
    }

    func goHome() {
        playerExpanded = false
        open(Self.home)
    }

    /// Handles text typed into the address bar: a URL, a bare domain or a search.
    func submit(_ text: String) {
        let onYouTube = selectedTab?.url?.host?.contains("youtube.com") ?? true
        guard let url = URLResolver.resolve(text, preferYouTube: onYouTube) else { return }
        playerExpanded = false
        open(url)
    }

    // MARK: - Miniplayer

    func openVideo(_ url: URL) {
        let tab: BrowserTab
        if let existing = player {
            tab = existing
        } else {
            tab = BrowserTab(configuration: makeConfiguration(forPlayer: true), store: self, isPlayer: true)
            player = tab
        }
        if tab.webView.url != url { tab.load(url) }
        playerExpanded = true
    }

    /// A non-video page opened from inside the player goes to the current tab.
    func openInBrowser(_ url: URL, newTab: Bool = false) {
        playerExpanded = false
        if newTab { openTab(url: url) } else if let tab = selectedTab { tab.load(url) } else { openTab(url: url) }
    }

    func closePlayer() {
        guard let player else { return }
        NowPlayingCenter.shared.mediaGone(from: player)
        player.teardown()
        playerExpanded = false
        self.player = nil
    }

    // MARK: - Lifecycle

    /// iOS pauses web video when the app leaves the screen (Home Screen, app
    /// switch, screen lock). UIKit notifications are used rather than SwiftUI's
    /// scenePhase because they arrive *before* WebKit pauses the video:
    ///  - will resign active: pages note what is playing right now;
    ///  - entered background: pages resume it, retried while iOS settles.
    private func observeAppLifecycle() {
        observe(UIApplication.willResignActiveNotification) { store in
            store.allTabs.forEach { $0.run("prepareBackground()") }
        }
        observe(UIApplication.didEnterBackgroundNotification) { store in
            store.saveSession()
            store.enterBackground()
        }
        observe(UIApplication.didBecomeActiveNotification) { store in
            store.allTabs.forEach { $0.run("setBackground(false)") }
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
        allTabs.forEach { $0.run("setBackground(true)") }

        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "encore.resume") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
        Task {
            for delay: UInt64 in [150, 400, 800, 1_500, 2_500, 4_000, 6_000] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard UIApplication.shared.applicationState == .background else { break }
                allTabs.forEach { $0.run("kick()") }
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

    func makeConfiguration(forPlayer: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = forPlayer ? playerContent : tabContent
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
        guard let url = Bundle.main.url(forResource: "encore", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        for (controller, role) in [(tabContent, "browse"), (playerContent, "player")] {
            controller.removeAllUserScripts()
            let prelude = "window.__encoreAdblock = \(adBlockEnabled); window.__encoreRole = '\(role)';\n"
            controller.addUserScript(WKUserScript(source: prelude + source,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
        }
    }

    private func applyContentRules() {
        for controller in [tabContent, playerContent] {
            controller.removeAllContentRuleLists()
            if adBlockEnabled, let ruleList { controller.add(ruleList) }
        }
    }

    // MARK: - Page messages

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let webView = message.webView,
              let tab = allTabs.first(where: { $0.webView === webView }),
              let body = message.body as? [String: Any] else { return }

        switch body["type"] as? String {
        case "media":
            if body["event"] as? String == "gone" {
                tab.isPlayingMedia = false
                NowPlayingCenter.shared.mediaGone(from: tab)
            } else if let state = MediaState(body) {
                tab.isPlayingMedia = state.playing
                NowPlayingCenter.shared.update(state, from: tab)
            }
        case "openVideo":
            if !tab.isPlayer, let url = (body["url"] as? String).flatMap({ URL(string: $0) }) {
                openVideo(URLResolver.youTubeVideo(url) ?? url)
            }
        case "openInBrowser":
            if tab.isPlayer, let url = (body["url"] as? String).flatMap({ URL(string: $0) }) {
                openInBrowser(url)
            }
        default:
            break
        }
    }
}

/// Forwards page messages without the user content controllers retaining the store.
@MainActor
private final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    weak var store: BrowserStore?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        store?.handle(message)
    }
}
