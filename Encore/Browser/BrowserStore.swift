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

    let userContent = WKUserContentController()
    private let router = ScriptMessageRouter()
    private var ruleList: WKContentRuleList?

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

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            saveSession()
            setBackground(true)
        case .active:
            setBackground(false)
        default:
            break
        }
    }

    /// Tells pages the app is in the background so the page script resumes any
    /// playback iOS pauses on the way out, then nudges the playing tab a few
    /// times while the transition settles.
    private func setBackground(_ background: Bool) {
        tabs.forEach { $0.run("setBackground(\(background))") }
        guard background else { return }

        let task = UIApplication.shared.beginBackgroundTask(withName: "encore.resume", expirationHandler: nil)
        Task {
            for delay: UInt64 in [300, 900, 1_800, 3_500] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                NowPlayingCenter.shared.tab?.run("kick()")
            }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func saveSession() {
        let urls = tabs.map { ($0.webView.url ?? $0.pendingURL)?.absoluteString ?? Self.home.absoluteString }
        UserDefaults.standard.set(urls, forKey: Keys.sessionURLs)
        UserDefaults.standard.set(tabs.firstIndex { $0.id == selectedID } ?? 0, forKey: Keys.sessionSelected)
    }

    private func restoreSession() {
        let urls = (UserDefaults.standard.stringArray(forKey: Keys.sessionURLs) ?? []).compactMap { URL(string: $0) }
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
