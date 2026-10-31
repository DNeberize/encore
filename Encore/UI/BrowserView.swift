import SwiftUI

/// YouTube and nothing else: the browse page edge to edge, with the player
/// panel (full screen or mini player) over it.
struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        ZStack {
            PageBackground(tab: store.browse)
            // The pages handle their own keyboard; YouTube's tab bar sits on the home indicator.
            WebContainer(webView: store.browse.webView, dock: store.dock)
                .ignoresSafeArea()
        }
    }
}

/// The page's own colour behind the status bar.
private struct PageBackground: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Color(uiColor: tab.themeColor ?? .systemBackground).ignoresSafeArea()
    }
}
