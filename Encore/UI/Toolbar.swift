import SwiftUI

struct Toolbar: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var nowPlaying = NowPlayingCenter.shared
    @Binding var editing: Bool
    var onShowTabs: () -> Void

    @State private var editingDevServer = false
    @State private var devServerDraft = ""

    private let haptics = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 4) {
            if editing {
                editingField
            } else {
                barButton("chevron.backward", enabled: tab.canGoBack) { tab.webView.goBack() }
                barButton("chevron.forward", enabled: tab.canGoForward) { tab.webView.goForward() }
                addressPill
                tabsButton
                menu
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            ProgressLine(progress: tab.progress, visible: tab.isLoading)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: editing)
        .alert("Live Script Server", isPresented: $editingDevServer) {
            TextField("192.168.1.20:8787", text: $devServerDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect") { store.devServerAddress = devServerDraft }
            if !store.devServerAddress.isEmpty {
                Button("Turn Off", role: .destructive) { store.devServerAddress = "" }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Run npm run dev on your computer (same Wi-Fi) and type the address it prints. The app then uses encore.js and blocklist.json from there and reloads when you save them.")
        }
    }

    // MARK: - Address

    private var isOnYouTube: Bool { tab.url?.host?.contains("youtube.com") ?? true }

    private var displayHost: String {
        guard let host = tab.url?.host else { return isOnYouTube ? "Search YouTube" : "Search or enter website" }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            return String(host.dropFirst(prefix.count))
        }
        return host
    }

    private var addressPill: some View {
        Button {
            haptics.impactOccurred()
            editing = true
        } label: {
            HStack(spacing: 5) {
                if tab.url?.scheme == "https" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(displayHost)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 34)
            .frame(height: 40)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button {
                haptics.impactOccurred()
                tab.reloadOrStop()
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var editingField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                AddressField(initialText: tab.url?.absoluteString ?? "",
                             placeholder: isOnYouTube ? "Search YouTube or enter address" : "Search or enter address") { text in
                    store.submit(text)
                    editing = false
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button("Cancel") { editing = false }
                .font(.system(size: 16, weight: .medium))
        }
        .padding(.horizontal, 4)
        .transition(.opacity)
    }

    // MARK: - Buttons

    private func barButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            haptics.impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }

    private var tabsButton: some View {
        Button {
            haptics.impactOccurred()
            onShowTabs()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lineWidth: 1.8)
                    .frame(width: 21, height: 21)
                Text("\(min(store.tabs.count, 99))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
        }
    }

    private var menu: some View {
        Menu {
            Button { store.goHome() } label: { Label("YouTube", systemImage: "play.rectangle.fill") }
            Button { store.open(BrowserStore.youTubeMusic) } label: { Label("YouTube Music", systemImage: "music.note") }
            Button { store.newTab() } label: { Label("New Tab", systemImage: "plus.square.on.square") }

            if let url = tab.url {
                Section {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                }
            }

            Section {
                sleepTimerMenu
                Toggle(isOn: $store.adBlockEnabled) {
                    Label("Block Ads", systemImage: "shield.lefthalf.filled")
                }
            }

            Section {
                Button {
                    devServerDraft = store.devServerAddress
                    editingDevServer = true
                } label: {
                    if store.devServerAddress.isEmpty {
                        Label("Live Script Server", systemImage: "antenna.radiowaves.left.and.right")
                    } else if store.devServerConnected {
                        Label("Live Script · Connected", systemImage: "antenna.radiowaves.left.and.right")
                    } else {
                        Label("Live Script · Not Connected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) minutes") { nowPlaying.setSleepTimer(minutes: minutes) }
            }
            if nowPlaying.sleepDeadline != nil {
                Button("Turn Off", role: .destructive) { nowPlaying.setSleepTimer(minutes: nil) }
            }
        } label: {
            if let deadline = nowPlaying.sleepDeadline {
                let minutes = max(1, Int(ceil(deadline.timeIntervalSinceNow / 60)))
                Label("Sleep Timer · \(minutes) min left", systemImage: "moon.zzz.fill")
            } else {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }
        }
    }
}

private struct ProgressLine: View {
    let progress: Double
    let visible: Bool

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.encoreAccent)
                .frame(width: proxy.size.width * max(0.05, progress), height: 2.5)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2.5)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: visible)
        .allowsHitTesting(false)
    }
}
