import Foundation

/// What language the app speaks. `system` means: Chinese when the system's first
/// preferred language is Chinese, English otherwise (ui-contract §2/S5).
enum Language: String, Codable, CaseIterable, Identifiable {
    case system
    case zh
    case en

    var id: String { rawValue }

    /// The language this setting resolves to right now.
    var resolved: Language {
        switch self {
        case .system: return Language.systemResolved
        case .zh, .en: return self
        }
    }

    static var systemResolved: Language {
        for preferred in Locale.preferredLanguages {
            let tag = preferred.lowercased()
            if tag.hasPrefix("zh") { return .zh }
            if tag.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// Light or dark, overriding the system when it says so.
enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

/// The two settings the app keeps (ui-contract §2/S5).
struct ClientSettings: Codable, Equatable {
    var language: Language = .system
    var appearance: Appearance = .system
}

/// Local persistence: settings, the identity list, and the last /nodes answer of
/// every origin. Nodes as such are never persisted — they are rebuilt from the
/// wire on every refresh; what is cached is the raw answer, so a cold start has
/// something to show before the first probe comes back.
final class ClientStore {

    private enum Key {
        static let settings = "settings"
        static let identities = "identities"
    }

    private let defaults: UserDefaults
    private let directory: URL

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent("RemoteEverything", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Where pairing stages its pending setup, one file per origin.
    var pairingDirectory: URL {
        directory.appendingPathComponent("Pairing", isDirectory: true)
    }

    // MARK: - Settings

    func loadSettings() -> ClientSettings {
        guard let data = defaults.data(forKey: Key.settings) else { return ClientSettings() }
        let decoder = JSONDecoder()
        guard let settings = try? decoder.decode(ClientSettings.self, from: data) else { return ClientSettings() }
        return settings
    }

    func saveSettings(_ settings: ClientSettings) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Key.settings)
    }

    // MARK: - Identities

    func loadIdentities() -> [Identity] {
        guard let data = defaults.data(forKey: Key.identities) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let identities = try? decoder.decode([Identity].self, from: data) else { return [] }
        return identities
    }

    func saveIdentities(_ identities: [Identity]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(identities) else { return }
        defaults.set(data, forKey: Key.identities)
    }

    // MARK: - Node cache

    private func cacheURL(origin: String) -> URL {
        directory.appendingPathComponent("nodes-\(Digest.originAlias(origin)).json")
    }

    func cachedNodes(origin: String) -> NodesResponse? {
        guard let data = AtomicFile.read(cacheURL(origin: origin)) else { return nil }
        return try? JSONDecoder().decode(NodesResponse.self, from: data)
    }

    func saveCachedNodes(_ response: NodesResponse, origin: String) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? AtomicFile.write(data, to: cacheURL(origin: origin))
    }

    func clearCachedNodes(origin: String) {
        AtomicFile.remove(cacheURL(origin: origin))
    }
}
