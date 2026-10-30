import AVFoundation
import MediaPlayer
import UIKit

/// Bridges the playing page to iOS: audio session, lock screen / Control
/// Center info, remote commands (play, pause, next, scrubbing), interruptions
/// and the sleep timer.
@MainActor
final class NowPlayingCenter: ObservableObject {
    static let shared = NowPlayingCenter()

    @Published private(set) var state: MediaState?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var sleepDeadline: Date?

    /// The tab whose media is shown on the lock screen.
    private(set) weak var tab: BrowserTab?

    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var sleepTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
    }

    // MARK: - Page updates

    func update(_ newState: MediaState, from source: BrowserTab) {
        // A paused tab never steals the lock screen from the one that is playing.
        guard newState.playing || tab == nil || tab === source else { return }
        if tab !== source {
            objectWillChange.send()
            tab = source
        }
        if newState.playing { activateAudioSession() }
        state = newState
        loadArtwork(newState.artworkURL)
        publish()
    }

    func mediaGone(from source: BrowserTab) {
        guard tab === source else { return }
        objectWillChange.send()
        tab = nil
        state = nil
        artwork = nil
        artworkURL = nil
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Commands

    func play() {
        tab?.run("play()")
        setOptimisticPlaying(true)
    }

    func pause() {
        tab?.run("pause()")
        setOptimisticPlaying(false)
    }

    func togglePlayPause() {
        if state?.playing == true { pause() } else { play() }
    }

    func next() { tab?.run("next()") }
    func previous() { tab?.run("previous()") }

    func seek(to seconds: Double) {
        tab?.run("seek(\(seconds))")
        state?.position = seconds
        publish()
    }

    private func setOptimisticPlaying(_ playing: Bool) {
        guard state != nil else { return }
        state?.playing = playing
        publish()
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        guard let minutes, minutes > 0 else { return }
        let interval = TimeInterval(minutes * 60)
        sleepDeadline = Date().addingTimeInterval(interval)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
                self?.sleepDeadline = nil
            }
        }
    }

    // MARK: - Lock screen info

    private func publish() {
        guard let state else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? state.rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: state.live,
        ]
        if !state.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = state.album }
        if state.duration > 0, !state.live { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: iOS asks for the image on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0) else { return }
            let cropped = Self.squareCrop(image, isYouTubeThumbnail: url.host?.contains("ytimg.com") == true)
            guard let self, self.artworkURL == url else { return }
            self.artwork = cropped
            self.publish()
        }
    }

    /// Square cover art: drops the black bars YouTube bakes into 4:3
    /// thumbnails, then takes the centre square.
    nonisolated private static func squareCrop(_ image: UIImage, isYouTubeThumbnail: Bool) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        var content = CGRect(x: 0, y: 0, width: width, height: height)
        if isYouTubeThumbnail, abs(width / height - 4.0 / 3.0) < 0.02 {
            let bandHeight = width * 9 / 16
            content = CGRect(x: 0, y: (height - bandHeight) / 2, width: width, height: bandHeight)
        }
        let side = min(content.width, content.height)
        let square = CGRect(x: content.midX - side / 2, y: content.midY - side / 2, width: side, height: side).integral
        guard let cropped = cg.cropping(to: square) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        // Category only; the session activates when something actually plays so
        // opening the app doesn't stop music from other apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            let began = type == .began
            Task { @MainActor in
                self?.tab?.run("interrupted(\(began), \(shouldResume))")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            // Headphones unplugged / AirPods removed: pause like any music player.
            Task { @MainActor in self?.pause() }
        })
    }

    // MARK: - Remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }

        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
    }
}
