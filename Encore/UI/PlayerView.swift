import SwiftUI
import WebKit

/// The full-screen video player. It slides down off screen when collapsed but
/// stays in the window, so the video keeps playing while you browse.
struct PlayerOverlay: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var player: BrowserTab
    let expanded: Bool

    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.85)))
    private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let hiddenOffset = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom + 40
            VStack(spacing: 0) {
                header
                PlayerWebView(webView: player.webView)
            }
            .background(Color(uiColor: player.themeColor ?? .systemBackground).ignoresSafeArea())
            .offset(y: expanded ? max(0, dragOffset) : hiddenOffset)
            .animation(.spring(response: 0.38, dampingFraction: 0.9), value: expanded)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { store.playerExpanded = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }

            VStack(spacing: 4) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 36, height: 5)
                Text(PlayerTitle.clean(player.title))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Button { store.closePlayer() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .frame(height: 48)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($dragOffset) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    if value.translation.height > 110 || value.predictedEndTranslation.height > 320 {
                        store.playerExpanded = false
                    }
                }
        )
    }
}

/// Collapsed miniplayer bar for the player.
struct PlayerBar: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var player: BrowserTab
    @ObservedObject var nowPlaying: NowPlayingCenter

    var body: some View {
        let live = nowPlaying.tab === player ? nowPlaying.state : nil
        MiniPlayer(title: live?.title ?? PlayerTitle.clean(player.title),
                   subtitle: live?.artist ?? "",
                   artwork: live == nil ? nil : nowPlaying.artwork,
                   isPlaying: live?.playing ?? false,
                   onOpen: { store.playerExpanded = true },
                   onTogglePlay: {
                       if live != nil { nowPlaying.togglePlayPause() } else { player.run("toggle()") }
                   },
                   onNext: { player.run("next()") },
                   onClose: { store.closePlayer() })
    }
}

enum PlayerTitle {
    static func clean(_ title: String) -> String {
        let trimmed = title.replacingOccurrences(of: " - YouTube", with: "")
        return trimmed.isEmpty ? "YouTube" : trimmed
    }
}

/// Hosts the player's web view (swaps it if the player is replaced).
struct PlayerWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WebContainer.ContainerView {
        WebContainer.ContainerView()
    }

    func updateUIView(_ view: WebContainer.ContainerView, context: Context) {
        view.show([webView], selected: webView)
    }
}
