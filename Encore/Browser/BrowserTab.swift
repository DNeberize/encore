import SafariServices
import SwiftUI
import WebKit

/// One of the app's two YouTube pages (see BrowserStore.Role).
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let role: BrowserStore.Role
    let webView: WKWebView
    weak var store: BrowserStore?

    @Published private(set) var url: URL?
    @Published private(set) var themeColor: UIColor?
    @Published var isPlayingMedia = false

    private var observations: [NSKeyValueObservation] = []

    /// `.allow` without letting iOS hand youtube.com links to the YouTube app
    /// (WebKit's `_WKNavigationActionPolicyAllowWithoutTryingAppLink`).
    private static let allowWithoutAppLink =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    private static let externalSchemes: Set<String> = [
        "tel", "mailto", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss",
    ]

    init(role: BrowserStore.Role, configuration: WKWebViewConfiguration, store: BrowserStore) {
        self.role = role
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.store = store
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Edge swipes go back while browsing; the player has no history to go back to.
        webView.allowsBackForwardNavigationGestures = role == .browse
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        // No pull-to-refresh: swiping down on YouTube must never reload the page.

        observations = [
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.themeColor) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
        ]
    }

    private func syncState() {
        if url != webView.url { url = webView.url }
        if themeColor != webView.themeColor { themeColor = webView.themeColor }
    }

    // MARK: - Actions

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Goes to a YouTube URL inside the already loaded page (YouTube's own
    /// in-page navigation, no reload), or loads it if the page can't.
    func open(_ url: URL) {
        guard webView.url != nil else { return load(url) }
        webView.evaluateJavaScript("window.__encore ? window.__encore.open(\(Self.jsString(url.absoluteString))) : false") { [weak self] result, _ in
            if result as? Bool != true { self?.load(url) }
        }
    }

    func reloadIfLoaded() {
        if webView.url != nil { webView.reload() }
    }

    /// Calls a function on the page script's `window.__encore` object.
    func run(_ call: String) {
        webView.evaluateJavaScript("window.__encore && window.__encore.\(call); void 0", completionHandler: nil)
    }

    /// Calls a function on `window.__encore` and hands back its result.
    func value(_ call: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript("window.__encore ? window.__encore.\(call) : null") { result, _ in
            completion(result)
        }
    }

    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())
    }

    /// YouTube and Google sign-in stay in the app; any other site opens in Safari.
    static func isInApp(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        let domains = ["youtube.com", "youtube-nocookie.com", "google.com", "gstatic.com", "googleusercontent.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) } || host.hasPrefix("google.")
            || host.contains(".google.")
    }

    /// Where a youtube.com/redirect link (description links) really goes.
    static func redirectTarget(_ url: URL) -> URL? {
        guard url.host?.lowercased().hasSuffix("youtube.com") == true, url.path == "/redirect",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
        return URL(string: target)
    }

    private func showInSafari(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        Presenter.present(safari)
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
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch scheme {
        case "http", "https":
            if mainFrame, let target = Self.redirectTarget(url), !Self.isInApp(target) {
                showInSafari(target)
                decisionHandler(.cancel)
            } else if mainFrame, role == .browse, let video = URLResolver.youTubeVideo(url) {
                // A video reached some other way than an in-page link: play it in the player.
                store?.openVideo(video)
                decisionHandler(.cancel)
            } else if mainFrame, !Self.isInApp(url) {
                showInSafari(url)
                decisionHandler(.cancel)
            } else if mainFrame, role == .player, webView.url != nil, navigationAction.navigationType == .linkActivated,
                      URLResolver.youTubeVideo(url) == nil {
                // A YouTube page that isn't a video, linked from the watch page: browse it.
                store?.showInBrowse(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(Self.allowWithoutAppLink)
            }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.pageDidLoad(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page was killed (usually memory pressure); bring it back.
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// `target=_blank` links and `window.open`: videos go to the player, YouTube
    /// pages to browsing, other sites to Safari. No extra windows.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard var url = navigationAction.request.url, let store else { return nil }
        if let target = Self.redirectTarget(url) { url = target }
        if let video = URLResolver.youTubeVideo(url) {
            store.openVideo(video)
        } else if Self.isInApp(url) {
            store.showInBrowse(url)
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            showInSafari(url)
        }
        return nil
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
