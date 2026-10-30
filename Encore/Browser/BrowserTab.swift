import SwiftUI
import WebKit

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    weak var store: BrowserStore?
    /// The miniplayer's web view (plays videos) rather than a normal tab.
    let isPlayer: Bool

    /// URL to load the first time the tab is shown (restored tabs load lazily).
    var pendingURL: URL?

    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var themeColor: UIColor?
    @Published private(set) var snapshot: UIImage?
    @Published var isPlayingMedia = false

    private var observations: [NSKeyValueObservation] = []

    /// `.allow` without letting iOS hand youtube.com links to the YouTube app
    /// (WebKit's `_WKNavigationActionPolicyAllowWithoutTryingAppLink`).
    private static let allowWithoutAppLink =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    private static let externalSchemes: Set<String> = [
        "tel", "mailto", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss",
    ]

    init(configuration: WKWebViewConfiguration, store: BrowserStore, isPlayer: Bool = false) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.store = store
        self.isPlayer = isPlayer
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        // No pull-to-refresh: swiping down on YouTube must never reload the page.

        observations = [
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.themeColor) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
        ]
    }

    private func syncState() {
        assign(\.title, webView.title ?? "")
        assign(\.url, webView.url)
        assign(\.progress, webView.estimatedProgress)
        assign(\.isLoading, webView.isLoading)
        assign(\.canGoBack, webView.canGoBack)
        assign(\.canGoForward, webView.canGoForward)
        assign(\.themeColor, webView.themeColor)
    }

    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<BrowserTab, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: - Actions

    func load(_ url: URL) {
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    func loadPendingIfNeeded() {
        guard let pendingURL, webView.url == nil else { return }
        load(pendingURL)
    }

    func reloadIfLoaded() {
        if webView.url != nil { webView.reload() }
    }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    /// Calls a function on the page script's `window.__encore` object.
    func run(_ call: String) {
        webView.evaluateJavaScript("window.__encore && window.__encore.\(call); void 0", completionHandler: nil)
    }

    func captureSnapshot() {
        guard webView.url != nil else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 360
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    func teardown() {
        run("pause()")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        switch scheme {
        case "http", "https":
            if let store, navigationAction.targetFrame?.isMainFrame == true {
                let video = URLResolver.youTubeVideo(url)
                let type = navigationAction.navigationType
                if !isPlayer, let video, type != .backForward, type != .reload {
                    // Videos always open in the miniplayer, leaving this page as it is.
                    decisionHandler(.cancel)
                    store.openVideo(video)
                    return
                }
                if isPlayer, video == nil, type == .linkActivated {
                    decisionHandler(.cancel)
                    store.openInBrowser(url)
                    return
                }
            }
            decisionHandler(Self.allowWithoutAppLink)
        case "about", "data", "blob", "file":
            decisionHandler(.allow)
        case _ where Self.externalSchemes.contains(scheme):
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        default:
            // youtube://, vnd.youtube:, intent:// and other "open the app" links.
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page was killed (usually memory pressure); bring it back.
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// `target=_blank` links and `window.open` (e.g. sign-in popups) open as new tabs.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let store else { return nil }
        if isPlayer {
            // Keep the player single-purpose; pop-ups open as normal tabs.
            if let url = navigationAction.request.url { store.openInBrowser(url, newTab: true) }
            return nil
        }
        return store.openTab(url: nil, configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if isPlayer { store?.closePlayer() } else { store?.close(self) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if !Presenter.present(alert) { completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if !Presenter.present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        if !Presenter.present(alert) { completionHandler(nil) }
    }
}

@MainActor
enum Presenter {
    @discardableResult
    static func present(_ controller: UIViewController) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else { return false }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
        return true
    }
}
