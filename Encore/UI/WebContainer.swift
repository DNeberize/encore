import SwiftUI
import WebKit

/// Hosts every tab's web view and shows only the selected one. Background tabs
/// stay in the window (just hidden) so their audio keeps playing.
struct WebContainer: UIViewRepresentable {
    let tabs: [BrowserTab]
    let selected: BrowserTab

    func makeUIView(context: Context) -> ContainerView {
        ContainerView()
    }

    func updateUIView(_ view: ContainerView, context: Context) {
        view.show(tabs.map(\.webView), selected: selected.webView)
    }

    final class ContainerView: UIView {
        func show(_ webViews: [WKWebView], selected: WKWebView) {
            for case let old as WKWebView in subviews where !webViews.contains(where: { $0 === old }) {
                old.removeFromSuperview()
            }
            for webView in webViews {
                if webView.superview !== self {
                    webView.frame = bounds
                    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    addSubview(webView)
                }
                webView.isHidden = webView !== selected
            }
            bringSubviewToFront(selected)
        }
    }
}
