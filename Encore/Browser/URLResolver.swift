import Foundation

enum URLResolver {
    /// Turns address-bar input into a URL: full URLs pass through, bare domains
    /// get https://, anything else becomes a YouTube or Google search.
    static func resolve(_ input: String, preferYouTube: Bool) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return url
        }

        if !text.contains(" "), let url = URL(string: "https://" + text),
           let host = url.host, looksLikeDomain(host) {
            return url
        }

        var components = URLComponents(string: preferYouTube ? "https://m.youtube.com/results" : "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: preferYouTube ? "search_query" : "q", value: text)]
        return components.url
    }

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

    private static func looksLikeDomain(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last else { return false }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
