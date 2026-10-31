import Foundation

/// Live development: loads encore.js and blocklist.json from `npm run dev` on a
/// computer on the same Wi-Fi instead of the app bundle, and reports each time
/// either file is saved there. Page console output is sent back to that
/// terminal. Off while no address is set.
@MainActor
final class DevServer {
    private(set) var isConnected = false
    private(set) var script: String?
    private(set) var blocklist: String?

    /// The files changed, or live mode was turned off (both are nil then).
    var onFilesChange: (() -> Void)?
    var onConnectionChange: (() -> Void)?

    private var baseURL: URL?
    private var loop: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Accepts "192.168.1.20:8787" or a full http:// address; "" turns it off.
    func connect(to address: String) {
        loop?.cancel()
        baseURL = Self.url(from: address)
        setConnected(false)
        if script != nil || blocklist != nil {
            script = nil
            blocklist = nil
            onFilesChange?()
        }
        guard let baseURL else { return }
        loop = Task { [weak self] in await self?.watch(baseURL) }
    }

    func log(_ level: String, _ text: String, page: String = "app") {
        guard isConnected, let baseURL else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("log"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["level": level, "text": text, "page": page])
        session.dataTask(with: request).resume()
    }

    static func url(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// Long-polls the server: each answer is the current version of the files,
    /// returned as soon as it differs from the one we have.
    private func watch(_ base: URL) async {
        var version = ""
        while !Task.isCancelled {
            do {
                var components = URLComponents(url: base.appendingPathComponent("changes"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "since", value: version)]
                guard let changesURL = components?.url else { return }
                let latest = String(decoding: try await fetch(changesURL), as: UTF8.self)
                if latest != version {
                    let newScript = String(decoding: try await fetch(base.appendingPathComponent("encore.js")), as: UTF8.self)
                    let newBlocklist = String(decoding: try await fetch(base.appendingPathComponent("blocklist.json")), as: UTF8.self)
                    guard !Task.isCancelled else { return }
                    version = latest
                    setConnected(true)
                    if newScript != script || newBlocklist != blocklist {
                        script = newScript
                        blocklist = newBlocklist
                        onFilesChange?()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                setConnected(false)
                version = ""
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onConnectionChange?()
    }
}
