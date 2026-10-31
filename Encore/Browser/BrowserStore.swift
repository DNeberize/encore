import SwiftUI
import WebKit

/// Owns the app's two YouTube pages plus what they share: cookies/logins (the
/// default website data store), the injected page script and the ad-block
/// rule list.
///
/// - `browse`: home, search, channels, Shorts. It never leaves for a video, so
///   it keeps its place (scroll position included) while something plays.
/// - `player`: the watch page, in the `PlayerDock` panel (full screen or the
///   mini player). It is loaded at launch, so opening a video is an in-page
///   navigation of an already running YouTube instead of a fresh page load.
@MainActor
final class BrowserStore: ObservableObject {
    static let home = URL(string: "https://m.youtube.com/")!

    enum Role: String {
        case browse, player
    }

    @Published var adBlockEnabled: Bool {
        didSet {
            guard adBlockEnabled != oldValue else { return }
            UserDefaults.standard.set(adBlockEnabled, forKey: Keys.adBlock)
            applyContentRules()
            installScripts()
            tabs.forEach { $0.reloadIfLoaded() }
        }
    }
    /// Address of `npm run dev` on the computer ("" = off). See DevServer.
    @Published var devServerAddress: String {
        didSet {
            guard devServerAddress != oldValue else { return }
            UserDefaults.standard.set(devServerAddress, forKey: Keys.devServer)
            devServer.connect(to: devServerAddress)
        }
    }
    @Published private(set) var devServerConnected = false

    private(set) var browse: BrowserTab!
    private(set) var player: BrowserTab!
    let dock = PlayerDock()
    var tabs: [BrowserTab] { [browse, player] }

    private let devServer = DevServer()
    private let browseContent = WKUserContentController()
    private let playerContent = WKUserContentController()
    private let router = ScriptMessageRouter()
    private var ruleList: WKContentRuleList?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The video the player is switching to (its thumbnail covers the page until then).
    private var pendingVideoID: String?

    private var contents: [(Role, WKUserContentController)] {
        [(.browse, browseContent), (.player, playerContent)]
    }

    private enum Keys {
        static let adBlock = "adBlockEnabled"
        static let devServer = "devServerAddress"
    }

    init() {
        adBlockEnabled = UserDefaults.standard.object(forKey: Keys.adBlock) as? Bool ?? true
        devServerAddress = UserDefaults.standard.string(forKey: Keys.devServer) ?? ""
        router.store = self
        contents.forEach { $0.1.add(router, name: "encore") }
        installScripts()
        browse = BrowserTab(role: .browse, configuration: makeConfiguration(browseContent), store: self)
        player = BrowserTab(role: .player, configuration: makeConfiguration(playerContent), store: self)
        setUpDock()
        observeAppLifecycle()

        Task {
            ruleList = await AdBlocker.loadRuleList()
            applyContentRules()
            browse.load(Self.home)
            startDevServer()
        }
    }

    // MARK: - Videos

    /// Plays a video in the player, full screen, from wherever you are.
    func openVideo(_ url: URL) {
        let watch = URLResolver.youTubeVideo(url) ?? url
        pendingVideoID = URLResolver.videoID(watch)
        browse.run("pauseAll()")
        measureTabBar()
        dock.showCover(videoID: pendingVideoID)
        dock.present()
        player.open(watch)
        let id = pendingVideoID
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if pendingVideoID == id { pendingVideoID = nil }
        }
    }

    /// Shows a YouTube page in browsing; a playing video shrinks to the mini player.
    func showInBrowse(_ url: URL) {
        dock.minimize()
        browse.open(url)
    }

    func closePlayer() {
        player.run("pause()")
        NowPlayingCenter.shared.mediaGone(from: player)
        player.isPlayingMedia = false
        pendingVideoID = nil
        dock.update(nil)
        dock.hide()
        // Leave the watch page so the lock screen lets go of the video too.
        player.run("open('/')")
    }

    func pageDidLoad(_ tab: BrowserTab) {
        guard tab === browse else { return }
        measureTabBar()
        guard player.webView.url == nil else { return }
        // Start the player's YouTube once browsing is up, so the first video opens fast.
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if player.webView.url == nil { player.load(Self.home) }
        }
    }

    private func setUpDock() {
        dock.attach(player.webView)
        dock.onClose = { [weak self] in self?.closePlayer() }
        dock.onTogglePlay = { [weak self] in self?.player.run("toggle()") }
        dock.menu = { [weak self] in self?.makeMenu() ?? UIMenu(children: []) }
        dock.onModeChange = { [weak self] mode in
            guard let self else { return }
            browse.run("setBottomInset(\(mode == .mini ? Int(PlayerDock.miniHeight) : 0))")
            if mode == .mini { measureTabBar() }
        }
    }

    /// Finds YouTube's tab bar on the browse page so the mini player can sit on it.
    private func measureTabBar() {
        browse.value("tabBarTop()") { [weak self] result in
            guard let self else { return }
            guard let top = (result as? NSNumber).map({ CGFloat(truncating: $0) }) else {
                dock.tabBarTop = nil
                return
            }
            let webView = browse.webView
            let point = CGPoint(x: 0, y: webView.scrollView.adjustedContentInset.top + top)
            dock.tabBarTop = webView.convert(point, to: dock).y
        }
    }

    // MARK: - Mini player menu

    private func makeMenu() -> UIMenu {
        let nowPlaying = NowPlayingCenter.shared
        var sleepItems: [UIMenuElement] = [15, 30, 45, 60, 90].map { minutes in
            UIAction(title: "\(minutes) minutes") { _ in nowPlaying.setSleepTimer(minutes: minutes) }
        }
        var sleepTitle = "Sleep Timer"
        if let deadline = nowPlaying.sleepDeadline {
            sleepTitle += " · \(max(1, Int(ceil(deadline.timeIntervalSinceNow / 60)))) min left"
            sleepItems.append(UIAction(title: "Turn Off", attributes: .destructive) { _ in
                nowPlaying.setSleepTimer(minutes: nil)
            })
        }
        let sleep = UIMenu(title: sleepTitle, image: UIImage(systemName: "moon.zzz"), children: sleepItems)

        let adBlock = UIAction(title: "Block Ads", image: UIImage(systemName: "shield.lefthalf.filled"),
                               state: adBlockEnabled ? .on : .off) { [weak self] _ in
            self?.adBlockEnabled.toggle()
        }

        let liveTitle: String
        if devServerAddress.isEmpty {
            liveTitle = "Live Script Server"
        } else {
            liveTitle = devServerConnected ? "Live Script · Connected" : "Live Script · Not Connected"
        }
        let live = UIAction(title: liveTitle, image: UIImage(systemName: "antenna.radiowaves.left.and.right")) { [weak self] _ in
            self?.editDevServer()
        }
        return UIMenu(children: [sleep, UIMenu(options: .displayInline, children: [adBlock, live])])
    }

    private func editDevServer() {
        let alert = UIAlertController(
            title: "Live Script Server",
            message: "Run npm run dev on your computer (same Wi-Fi) and type the address it prints. "
                + "The app then uses encore.js and blocklist.json from there and reloads when you save them.",
            preferredStyle: .alert)
        let current = devServerAddress
        alert.addTextField { field in
            field.text = current
            field.placeholder = "192.168.1.20:8787"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            self?.devServerAddress = alert?.textFields?.first?.text ?? ""
        })
        if !devServerAddress.isEmpty {
            alert.addAction(UIAlertAction(title: "Turn Off", style: .destructive) { [weak self] _ in
                self?.devServerAddress = ""
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Presenter.present(alert)
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
            store.enterBackground()
        }
        observe(UIApplication.didBecomeActiveNotification) { store in
            store.tabs.forEach { $0.run("setBackground(false)") }
            store.readSettings()
        }
    }

    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (BrowserStore) -> Void) {
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let self { action(self) }
            }
        })
    }

    /// Picks up changes made in the Settings app (Settings → Encore).
    private func readSettings() {
        let defaults = UserDefaults.standard
        if let enabled = defaults.object(forKey: Keys.adBlock) as? Bool, enabled != adBlockEnabled {
            adBlockEnabled = enabled
        }
        let address = defaults.string(forKey: Keys.devServer) ?? ""
        if address != devServerAddress { devServerAddress = address }
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

    // MARK: - Web configuration

    private func makeConfiguration(_ content: WKUserContentController) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = content
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
        guard let source = devServer.script ?? Bundle.main.url(forResource: "encore", withExtension: "js")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return }
        for (role, content) in contents {
            content.removeAllUserScripts()
            var prelude = "window.__encoreAdblock = \(adBlockEnabled);\nwindow.__encoreRole = '\(role.rawValue)';\n"
            if devServer.script != nil { prelude += Self.consoleForwarder }
            content.addUserScript(WKUserScript(source: prelude + source,
                                               injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false))
        }
    }

    // MARK: - Live development

    private func startDevServer() {
        devServer.onConnectionChange = { [weak self] in
            guard let self else { return }
            devServerConnected = devServer.isConnected
        }
        devServer.onFilesChange = { [weak self] in self?.reloadDevFiles() }
        devServer.connect(to: devServerAddress)
    }

    /// Swaps in the computer's (or, when live mode ends, the bundled) script and
    /// block list, then reloads the open pages so they run the new copy.
    private func reloadDevFiles() {
        installScripts()
        Task {
            ruleList = await AdBlocker.loadRuleList(json: devServer.blocklist) { [weak self] error in
                self?.devServer.log("error", "blocklist.json failed to compile: \(error.localizedDescription)")
            }
            applyContentRules()
            tabs.forEach { $0.reloadIfLoaded() }
            devServer.log("info", "Reloaded both pages with the new files")
        }
    }

    /// Live mode only: copies the page's console output and uncaught errors to
    /// the `npm run dev` terminal.
    private static let consoleForwarder = """
    (function () {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.encore;
      if (!bridge) return;
      function send(level, args) {
        try {
          var text = Array.prototype.map.call(args, function (v) {
            if (typeof v === 'string') return v;
            if (v instanceof Error) return v.stack || String(v);
            try { return JSON.stringify(v); } catch (e) { return String(v); }
          }).join(' ');
          bridge.postMessage({ type: 'log', level: level, text: text, page: (window.__encoreRole || '') + ' ' + location.host });
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () { send(level, arguments); return original.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) {
        send('error', [e.message + ' (' + e.filename + ':' + e.lineno + ':' + e.colno + ')']);
      });
      window.addEventListener('unhandledrejection', function (e) { send('error', ['Unhandled rejection:', e.reason]); });
    })();

    """

    private func applyContentRules() {
        for (_, content) in contents {
            content.removeAllContentRuleLists()
            if adBlockEnabled, let ruleList { content.add(ruleList) }
        }
    }

    // MARK: - Page messages

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let webView = message.webView,
              let tab = tabs.first(where: { $0.webView === webView }),
              let body = message.body as? [String: Any] else { return }
        let url = (body["url"] as? String).flatMap { URL(string: $0) }

        switch body["type"] as? String {
        case "log":
            devServer.log(body["level"] as? String ?? "log", body["text"] as? String ?? "",
                          page: body["page"] as? String ?? "")
        case "openVideo":
            if let url { openVideo(url) }
        case "browse":
            if let url { showInBrowse(url) }
        case "route":
            if tab === browse {
                measureTabBar()
            } else if body["video"] as? Bool == false, dock.mode != .hidden, let url {
                // The player left the watch page some other way (its video is gone):
                // close it and show that page in browsing instead.
                closePlayer()
                browse.open(url)
            }
        case "media":
            handleMedia(body, from: tab)
        default:
            break
        }
    }

    private func handleMedia(_ body: [String: Any], from tab: BrowserTab) {
        if body["event"] as? String == "gone" {
            tab.isPlayingMedia = false
            NowPlayingCenter.shared.mediaGone(from: tab)
            if tab === player { dock.update(nil) }
            return
        }
        guard let state = MediaState(body) else { return }
        let wasPlaying = tab.isPlayingMedia
        tab.isPlayingMedia = state.playing

        if tab === player {
            // Media from the video we're switching away from doesn't count.
            if let pending = pendingVideoID, !state.videoID.isEmpty, state.videoID != pending { return }
            if pendingVideoID != nil {
                pendingVideoID = nil
                dock.hideCover()
            }
            guard dock.mode != .hidden else { return }
            dock.update(state)
            if state.playing, !wasPlaying { browse.run("pauseAll()") }
        } else if state.playing, !wasPlaying, player.isPlayingMedia {
            // Something with sound started while browsing (Shorts): the video pauses.
            player.run("pause()")
        }
        NowPlayingCenter.shared.update(state, from: tab)
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
