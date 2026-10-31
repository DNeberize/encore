import WebKit

/// Compiles the bundled network/cosmetic block list once and reuses the
/// compiled copy on later launches (the identifier changes with the file).
/// `json` replaces the bundled list (live development, see DevServer).
enum AdBlocker {
    @MainActor
    static func loadRuleList(json override: String? = nil, onError: ((Error) -> Void)? = nil) async -> WKContentRuleList? {
        guard let json = override ?? Bundle.main.url(forResource: "blocklist", withExtension: "json")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return nil }
        let store: WKContentRuleListStore = WKContentRuleListStore.default()

        let checksum = json.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let identifier = "encore-blocklist-\(checksum)"

        if let cached = await lookUp(identifier, in: store) { return cached }
        return await compile(identifier, json: json, in: store, onError: onError)
    }

    @MainActor
    private static func lookUp(_ identifier: String, in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    @MainActor
    private static func compile(_ identifier: String, json: String, in store: WKContentRuleListStore,
                                onError: ((Error) -> Void)?) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error {
                    print("Encore: block list failed to compile: \(error)")
                    onError?(error)
                }
                continuation.resume(returning: list)
            }
        }
    }
}
