import Foundation

/// Playback snapshot reported by the page script.
struct MediaState: Equatable {
    var videoID: String
    var playing: Bool
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: Double
    var position: Double
    var rate: Double
    var live: Bool

    init?(_ body: [String: Any]) {
        guard let playing = body["playing"] as? Bool else { return nil }
        self.playing = playing
        videoID = body["video"] as? String ?? ""
        let title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? "Now Playing" : title
        artist = body["artist"] as? String ?? ""
        album = body["album"] as? String ?? ""
        artworkURL = (body["artwork"] as? String).flatMap { URL(string: $0) }
        duration = body["duration"] as? Double ?? 0
        position = body["position"] as? Double ?? 0
        rate = body["rate"] as? Double ?? 1
        live = body["live"] as? Bool ?? false
    }
}
