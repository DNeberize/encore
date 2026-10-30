import AVFoundation
import UIKit

/// Tracks what is playing (for the in-app player bar and tab icons), sets up
/// the audio session, pauses for calls and unplugged headphones, and runs the
/// sleep timer.
///
/// The lock screen / Control Center controls are WebKit's own: they drive the
/// page directly (with the privilege to resume after iOS pauses it), and the
/// page script records those taps as your intent. The app deliberately does
/// not register a second set of controls, which would fight with them.
@MainActor
final class NowPlayingCenter: ObservableObject {
    static let shared = NowPlayingCenter()

    @Published private(set) var state: MediaState?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var sleepDeadline: Date?

    /// The tab whose media is playing (or last played).
    private(set) weak var tab: BrowserTab?

    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var sleepTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    // Playback is held (paused, no auto-resume) while either of these is true.
    private var audioInterrupted = false
    private var callActive = false
    private var holding = false
    private var callMonitor: CallMonitor?

    private init() {
        // Category only; WebKit activates the session when something plays, so
        // opening the app doesn't stop music from other apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        observeAudioSession()
        callMonitor = CallMonitor { [weak self] active in
            Task { @MainActor in self?.callChanged(active) }
        }
    }

    // MARK: - Page updates

    func update(_ newState: MediaState, from source: BrowserTab) {
        // A paused tab never takes over from the one that is playing.
        guard newState.playing || tab == nil || tab === source else { return }
        if tab !== source {
            objectWillChange.send()
            tab = source
        }
        if newState.playing {
            // Audio is flowing again, so any interruption is over (iOS doesn't
            // always send the "ended" notice).
            audioInterrupted = false
            holding = callActive
        }
        state = newState
        loadArtwork(newState.artworkURL)
    }

    func mediaGone(from source: BrowserTab) {
        guard tab === source else { return }
        objectWillChange.send()
        tab = nil
        state = nil
        artwork = nil
        artworkURL = nil
        artworkTask?.cancel()
    }

    // MARK: - Commands (in-app player bar, sleep timer)

    func play() {
        audioInterrupted = false
        holding = false
        tab?.run("play()")
        state?.playing = true
    }

    func pause() {
        tab?.run("pause()")
        state?.playing = false
    }

    func togglePlayPause() {
        if state?.playing == true { pause() } else { play() }
    }

    func next() { tab?.run("next()") }

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

    // MARK: - Artwork

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

    // MARK: - Calls and headphones

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
                guard let self else { return }
                self.audioInterrupted = began
                self.updateHold(resume: shouldResume)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            // Wired headphones unplugged or Bluetooth/AirPods disconnected:
            // pause and stay paused, like any music player.
            Task { @MainActor in self?.pause() }
        })
    }

    private func callChanged(_ active: Bool) {
        callActive = active
        // When the call ends, pick the music back up (like Apple Music).
        updateHold(resume: true)
    }

    /// Pauses the page (without counting it as your pause) when a call or other
    /// interruption starts, and resumes it afterwards if it was playing.
    private func updateHold(resume: Bool) {
        let shouldHold = audioInterrupted || callActive
        guard shouldHold != holding else { return }
        holding = shouldHold
        tab?.run("interrupted(\(shouldHold), \(resume))")
        if shouldHold { state?.playing = false }
    }
}
