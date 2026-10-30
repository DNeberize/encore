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

    private static func looksLikeDomain(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last else { return false }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
