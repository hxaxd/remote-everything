import Foundation

/// Local persistence: settings and the identity list.
final class SettingsStore {

    private enum Key {
        static let settings = "settings"
        static let identities = "identities"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
}
