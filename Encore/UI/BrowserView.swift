import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        Group {
            if let tab = store.selectedTab {
                BrowserChrome(tab: tab)
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
    }
}

/// Web page, mini player and bottom toolbar for the selected tab.
private struct BrowserChrome: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var nowPlaying = NowPlayingCenter.shared

    @State private var editingAddress = false
    @State private var showingTabs = false
    @State private var pageKeyboardVisible = false

    private var showsMiniPlayer: Bool {
        nowPlaying.state != nil && nowPlaying.tab !== tab && !editingAddress
    }

    var body: some View {
        VStack(spacing: 0) {
            WebContainer(tabs: store.tabs, selected: tab)

            if !pageKeyboardVisible || editingAddress {
                VStack(spacing: 0) {
                    if showsMiniPlayer {
                        MiniPlayer(nowPlaying: nowPlaying) {
                            if let playing = nowPlaying.tab { store.select(playing) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Toolbar(tab: tab, editing: $editingAddress) {
                        tab.captureSnapshot()
                        showingTabs = true
                    }
                }
                .background(.bar, ignoresSafeAreaEdges: .bottom)
                .transition(.opacity)
            }
        }
        // Let WKWebView handle keyboards raised by the page itself; only our own
        // address field should push the toolbar up.
        .ignoresSafeArea(editingAddress ? SafeAreaRegions() : .keyboard, edges: .bottom)
        .background(Color(uiColor: tab.themeColor ?? .systemBackground).ignoresSafeArea())
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showsMiniPlayer)
        .animation(.easeOut(duration: 0.18), value: pageKeyboardVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            pageKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            pageKeyboardVisible = false
        }
        .sheet(isPresented: $showingTabs) {
            TabSwitcher()
                .environmentObject(store)
        }
    }
}
