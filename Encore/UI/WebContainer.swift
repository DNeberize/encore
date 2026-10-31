import SwiftUI
import WebKit

/// The browse page (below the status bar, down to the bottom edge) with the
/// player panel over it. Both are plain UIKit views in one container, so
/// touches the mini player doesn't take go straight to the page.
struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    let dock: PlayerDock

    func makeUIView(context: Context) -> ContainerView {
        ContainerView()
    }

    func updateUIView(_ view: ContainerView, context: Context) {
        view.show(webView, dock: dock)
    }

    final class ContainerView: UIView {
        private weak var webView: WKWebView?
        private weak var dock: PlayerDock?

        func show(_ webView: WKWebView, dock: PlayerDock) {
            guard webView.superview !== self || dock.superview !== self else { return }
            self.webView = webView
            self.dock = dock
            webView.autoresizingMask = []
            addSubview(webView)
            addSubview(dock)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let top = window?.safeAreaInsets.top ?? safeAreaInsets.top
            webView?.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
            dock?.frame = bounds
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }
    }
}
