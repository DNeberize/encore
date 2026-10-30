import CallKit

/// Reports whether any phone or VoIP call (FaceTime, WhatsApp, ...) is ringing
/// or in progress, so music pauses for the whole call even if iOS skips its
/// usual audio-interruption notice.
final class CallMonitor: NSObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    var isCallActive: Bool {
        observer.calls.contains { !$0.hasEnded }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onChange(isCallActive)
    }
}
