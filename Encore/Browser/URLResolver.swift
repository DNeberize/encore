import Foundation

enum URLResolver {
    /// The m.youtube.com watch page for a YouTube video link (youtube.com/watch,
    /// youtu.be/ID), or nil if the URL isn't a video.
    static func youTubeVideo(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = components.queryItems ?? []

        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !id.isEmpty, !id.contains("/") else { return nil }
            query.insert(URLQueryItem(name: "v", value: id), at: 0)
        } else if host == "youtube.com" || (host.hasSuffix(".youtube.com") && host != "music.youtube.com") {
            guard url.path == "/watch", query.contains(where: { $0.name == "v" && $0.value?.isEmpty == false }) else {
                return nil
            }
        } else {
            return nil
        }

        components.scheme = "https"
        components.host = "m.youtube.com"
        components.path = "/watch"
        components.queryItems = query.filter { $0.name != "app" }
        return components.url
    }

    /// The `v=` video id of a watch URL.
    static func videoID(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "v" }?.value
    }
}
