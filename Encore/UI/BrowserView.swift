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

/// Web page, miniplayer and bottom toolbar for the selected tab.
private struct BrowserChrome: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var nowPlaying = NowPlayingCenter.shared

    @State private var editingAddress = false
    @State private var showingTabs = false
    @State private var pageKeyboardVisible = false

    private enum Bar: Equatable { case none, player, otherTab }

    private var bar: Bar {
        if editingAddress { return .none }
        if store.player != nil { return store.playerExpanded ? .none : .player }
        if nowPlaying.state != nil, nowPlaying.tab !== tab { return .otherTab }
        return .none
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                WebContainer(tabs: store.tabs, selected: tab)

                if !pageKeyboardVisible || editingAddress {
                    VStack(spacing: 0) {
                        miniBar
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

            if let player = store.player {
                PlayerOverlay(player: player, expanded: store.playerExpanded)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: bar)
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

    @ViewBuilder
    private var miniBar: some View {
        switch bar {
        case .player:
            if let player = store.player {
                PlayerBar(player: player, nowPlaying: nowPlaying)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .otherTab:
            if let state = nowPlaying.state {
                MiniPlayer(title: state.title,
                           subtitle: state.artist,
                           artwork: nowPlaying.artwork,
                           isPlaying: state.playing,
                           onOpen: { if let playing = nowPlaying.tab { store.select(playing) } },
                           onTogglePlay: { nowPlaying.togglePlayPause() },
                           onNext: { nowPlaying.next() })
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .none:
            EmptyView()
        }
    }
}
