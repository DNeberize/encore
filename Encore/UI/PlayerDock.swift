import UIKit
import WebKit

/// The watch page as a panel over the browse page, like the YouTube app's
/// player: full screen, or a mini player docked above YouTube's tab bar.
///
/// - Swipe the video down (or the page, while it's scrolled to the top) to
///   shrink it. The page underneath never moved, so it's right where you were.
/// - Tap the mini player or swipe it up to bring the video back; swipe it down
///   or tap ✕ to close. Long-press it for the sleep timer and settings.
///
/// Everything moves with a transform on a clipping view around the web view.
/// The web view itself is never resized while it moves, so the video keeps
/// playing smoothly in the middle of a gesture.
@MainActor
final class PlayerDock: UIView {
    enum Mode { case hidden, full, mini }

    static let miniHeight: CGFloat = 64

    private(set) var mode: Mode = .hidden
    var onModeChange: ((Mode) -> Void)?
    var onClose: (() -> Void)?
    var onTogglePlay: (() -> Void)?
    var menu: (() -> UIMenu)?

    /// Top of YouTube's tab bar on the browse page, in this view's coordinates.
    /// The mini player sits right above it.
    var tabBarTop: CGFloat? {
        didSet {
            guard tabBarTop != oldValue, mode == .mini, !isBusy else { return }
            animate(to: 1)
        }
    }

    private let backdrop = UIView()
    private let clip = UIView()
    private let cover = UIView()
    private let coverImage = UIImageView()
    private let miniBar = MiniBar()
    private let playerPan = UIPanGestureRecognizer()
    private weak var webView: WKWebView?

    private var progress: CGFloat = 0       // 0 full screen … 1 mini player
    private var dismissOffset: CGFloat = 0  // slid down (closing, or opening from below)
    private var isBusy = false              // animating or following a finger
    private var animationID = 0
    private var dragStart: CGFloat = 0
    private var miniDragUp = false
    private var coverID = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backdrop.backgroundColor = .systemBackground
        backdrop.isUserInteractionEnabled = false
        clip.clipsToBounds = true
        clip.backgroundColor = .systemBackground
        cover.backgroundColor = .systemBackground
        cover.isUserInteractionEnabled = false
        cover.alpha = 0
        coverImage.backgroundColor = .black
        coverImage.contentMode = .scaleAspectFill
        coverImage.clipsToBounds = true
        cover.addSubview(coverImage)
        clip.addSubview(cover)
        addSubview(backdrop)
        addSubview(miniBar)
        addSubview(clip)

        playerPan.addTarget(self, action: #selector(panPlayer(_:)))
        playerPan.delegate = self
        clip.addGestureRecognizer(playerPan)

        miniBar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapMini)))
        miniBar.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panMini(_:))))
        miniBar.addInteraction(UIContextMenuInteraction(delegate: self))
        miniBar.playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        miniBar.closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Puts the player's web view in the panel (once, at launch).
    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.autoresizingMask = []
        clip.insertSubview(webView, at: 0)
        // The page only scrolls once a swipe turns out not to be a "shrink" swipe.
        webView.scrollView.panGestureRecognizer.require(toFail: playerPan)
        setNeedsLayout()
    }

    func update(_ state: MediaState?) {
        miniBar.update(state)
    }

    // MARK: - Showing and hiding

    /// Full screen: slides up from the bottom, or grows back from the mini player.
    func present() {
        switch mode {
        case .full:
            return
        case .mini:
            setMode(.full)
            animate(to: 0)
        case .hidden:
            setMode(.full)
            isHidden = false
            progress = 0
            dismissOffset = bounds.height
            apply()
            animate(to: 0)
        }
    }

    func minimize() {
        guard mode == .full else { return }
        setMode(.mini)
        animate(to: 1)
    }

    func hide() {
        guard mode != .hidden else { return }
        setMode(.hidden)
        animationID += 1
        let id = animationID
        isBusy = true
        let distance = progress > 0.5 ? Self.miniHeight + 60 : bounds.height
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.dismissOffset = distance
            self.apply()
        } completion: { _ in
            guard id == self.animationID else { return }
            self.isBusy = false
            self.isHidden = true
            self.progress = 0
            self.dismissOffset = 0
            self.cover.alpha = 0
            self.apply()
        }
    }

    /// The video's thumbnail over the page while it switches to a new video,
    /// so the previous one never flashes up.
    func showCover(videoID: String?) {
        coverID += 1
        let id = coverID
        coverImage.image = nil
        cover.alpha = 1
        Task { [weak self] in
            if let videoID, let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
               let result = try? await URLSession.shared.data(from: url),
               let image = UIImage(data: result.0),
               let self, self.coverID == id {
                self.coverImage.image = image
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let self, self.coverID == id { self.hideCover() }
        }
    }

    func hideCover() {
        coverID += 1
        guard cover.alpha > 0 else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.cover.alpha = 0
        }
    }

    private func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        clip.isUserInteractionEnabled = newMode == .full
        onModeChange?(newMode)
    }

    // MARK: - Layout

    private struct Metrics {
        var full: CGRect          // the web view when full screen (below the status bar)
        var videoHeight: CGFloat  // the video at the top of the watch page
        var mini: CGRect          // the mini player row
        var miniScale: CGFloat
    }

    private var metrics: Metrics {
        let safe = window?.safeAreaInsets ?? safeAreaInsets
        let full = CGRect(x: 0, y: safe.top, width: bounds.width, height: max(1, bounds.height - safe.top))
        // The page puts the video at the very top, 16:9 (YouTube's padding-bottom: 56.25%).
        let videoHeight = max(1, (full.width * 9 / 16).rounded())
        let floor = bounds.height - safe.bottom
        let bottom = min(tabBarTop ?? floor, floor)
        let mini = CGRect(x: 0, y: bottom - Self.miniHeight, width: bounds.width, height: Self.miniHeight)
        return Metrics(full: full, videoHeight: videoHeight, mini: mini, miniScale: Self.miniHeight / videoHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let l = metrics
        if let webView, webView.bounds.size != l.full.size {
            webView.frame = CGRect(origin: .zero, size: l.full.size)
        }
        cover.frame = CGRect(origin: .zero, size: l.full.size)
        coverImage.frame = CGRect(x: 0, y: 0, width: l.full.width, height: l.videoHeight)
        if !isBusy { apply() }
    }

    /// Places everything for the current progress (0 full … 1 mini).
    private func apply() {
        let l = metrics
        let p = progress
        let collapse = min(1, p * 1.6)   // the page under the video is gone well before the end
        let scale = 1 + (l.miniScale - 1) * p
        let height = l.full.height + (l.videoHeight - l.full.height) * collapse
        let top = l.full.minY + (l.mini.minY - l.full.minY) * p + dismissOffset

        clip.bounds = CGRect(x: 0, y: 0, width: l.full.width, height: height)
        clip.transform = CGAffineTransform(scaleX: scale, y: scale)
        clip.center = CGPoint(x: l.full.minX + l.full.width * scale / 2, y: top + height * scale / 2)

        let closing = p > 0.5 ? min(1, dismissOffset / 80) : 0
        clip.alpha = 1 - closing
        backdrop.frame = bounds
        backdrop.alpha = (1 - collapse) * (1 - min(1, dismissOffset / max(1, bounds.height)))

        miniBar.videoWidth = l.full.width * l.miniScale
        miniBar.bounds = CGRect(origin: .zero, size: l.mini.size)
        miniBar.center = CGPoint(x: l.mini.midX, y: l.mini.midY + dismissOffset)
        miniBar.alpha = max(0, min(1, (p - 0.55) / 0.45)) * (1 - closing)
    }

    private func animate(to target: CGFloat, velocity: CGFloat = 0) {
        animationID += 1
        let id = animationID
        isBusy = true
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: velocity,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.progress = target
            self.dismissOffset = 0
            self.apply()
        } completion: { _ in
            if id == self.animationID { self.isBusy = false }
        }
    }

    /// UIKit's spring velocity: the finger's speed relative to the distance left.
    private func springVelocity(_ speed: CGFloat, from: CGFloat, to: CGFloat, travel: CGFloat) -> CGFloat {
        let distance = (to - from) * travel
        return abs(distance) < 1 ? 0 : max(-20, min(20, speed / distance))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        switch mode {
        case .hidden: return false
        case .full: return true
        case .mini: return miniBar.frame.insetBy(dx: 0, dy: -4).contains(point)
        }
    }

    // MARK: - Gestures

    @objc private func panPlayer(_ pan: UIPanGestureRecognizer) {
        let l = metrics
        let travel = max(1, l.mini.minY - l.full.minY)
        switch pan.state {
        case .began:
            animationID += 1
            isBusy = true
            dragStart = progress
        case .changed:
            progress = min(1, max(0, dragStart + pan.translation(in: self).y / travel))
            apply()
        case .ended, .cancelled, .failed:
            let speed = pan.velocity(in: self).y
            let projected = progress + speed / travel * 0.25
            let target: CGFloat = pan.state == .ended && projected > 0.5 ? 1 : 0
            setMode(target == 1 ? .mini : .full)
            animate(to: target, velocity: springVelocity(speed, from: progress, to: target, travel: travel))
        default:
            break
        }
    }

    @objc private func tapMini() {
        guard mode == .mini, !isBusy else { return }
        present()
    }

    @objc private func panMini(_ pan: UIPanGestureRecognizer) {
        guard mode == .mini else { return }
        let l = metrics
        let travel = max(1, l.mini.minY - l.full.minY)
        let translation = pan.translation(in: self).y
        switch pan.state {
        case .began:
            animationID += 1
            isBusy = true
            miniDragUp = pan.velocity(in: self).y < 0
        case .changed:
            if miniDragUp {
                progress = min(1, max(0, 1 + translation / travel))
            } else {
                dismissOffset = max(0, translation)
            }
            apply()
        case .ended, .cancelled, .failed:
            let speed = pan.velocity(in: self).y
            if miniDragUp {
                let open = pan.state == .ended && progress + speed / travel * 0.25 < 0.75
                let target: CGFloat = open ? 0 : 1
                setMode(open ? .full : .mini)
                animate(to: target, velocity: springVelocity(speed, from: progress, to: target, travel: travel))
            } else if pan.state == .ended && (dismissOffset > 36 || speed > 500) {
                onClose?()
            } else {
                animate(to: 1)
            }
        default:
            break
        }
    }

    @objc private func togglePlay() { onTogglePlay?() }

    @objc private func closeTapped() { onClose?() }
}

// MARK: - UIGestureRecognizerDelegate

extension PlayerDock: UIGestureRecognizerDelegate {
    /// A shrink swipe: downward, on the video or on a page scrolled to the top,
    /// in portrait (in landscape the video owns the screen).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === playerPan else { return true }
        guard mode == .full, !isBusy, bounds.width < bounds.height, let webView else { return false }
        let velocity = playerPan.velocity(in: self)
        guard velocity.y > 0, velocity.y > abs(velocity.x) * 1.2 else { return false }
        let onVideo = playerPan.location(in: webView).y < metrics.videoHeight + 12
        let scrollView = webView.scrollView
        let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
        return onVideo || atTop
    }

    /// Lets the page keep its own touch handling (taps on the player's buttons)
    /// until the swipe takes over.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === playerPan && other !== webView?.scrollView.panGestureRecognizer
    }
}

// MARK: - UIContextMenuInteractionDelegate

extension PlayerDock: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard mode == .mini, let menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
    }
}

// MARK: - Mini player row

/// Title, channel, play/pause, close and a thin progress line. The video on
/// its left is the shrunken web view itself, drawn on top of this row.
@MainActor
private final class MiniBar: UIView {
    let playButton = UIButton(type: .system)
    let closeButton = UIButton(type: .system)
    var videoWidth: CGFloat = 114 {
        didSet { if videoWidth != oldValue { setNeedsLayout() } }
    }

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let separator = UIView()
    private let progressFill = UIView()
    private var state: MediaState?
    private var stateTime = Date()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : .white }
        separator.backgroundColor = .separator
        progressFill.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .label
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        playButton.tintColor = .label
        closeButton.tintColor = .label
        closeButton.setImage(Self.symbol("xmark", size: 17), for: .normal)
        closeButton.accessibilityLabel = "Close"
        [separator, titleLabel, subtitleLabel, playButton, closeButton, progressFill].forEach(addSubview)
        update(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width, height = bounds.height
        separator.frame = CGRect(x: 0, y: 0, width: width, height: 1 / (window?.screen.scale ?? 2))
        closeButton.frame = CGRect(x: width - 50, y: 0, width: 46, height: height)
        playButton.frame = CGRect(x: width - 96, y: 0, width: 46, height: height)
        let textX = videoWidth + 12
        let textWidth = max(0, playButton.frame.minX - textX - 4)
        titleLabel.frame = CGRect(x: textX, y: height / 2 - 19, width: textWidth, height: 19)
        subtitleLabel.frame = CGRect(x: textX, y: height / 2 + 1, width: textWidth, height: 17)
        updateProgress()
    }

    func update(_ newState: MediaState?) {
        state = newState
        stateTime = Date()
        titleLabel.text = newState?.title
        subtitleLabel.text = newState?.artist
        let playing = newState?.playing == true
        playButton.setImage(Self.symbol(playing ? "pause.fill" : "play.fill", size: 20), for: .normal)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
        updateProgress()
        if playing, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateProgress() }
            }
        } else if !playing {
            timer?.invalidate()
            timer = nil
        }
    }

    private func updateProgress() {
        guard let state, state.duration > 0, !state.live else {
            progressFill.frame = .zero
            return
        }
        let elapsed = state.playing ? Date().timeIntervalSince(stateTime) * state.rate : 0
        let fraction = min(1, max(0, (state.position + elapsed) / state.duration))
        progressFill.frame = CGRect(x: 0, y: bounds.height - 2, width: bounds.width * fraction, height: 2)
    }

    private static func symbol(_ name: String, size: CGFloat) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }
}
