import Foundation


/// Local persistence: settings, the identity list, and the last /nodes answer of
/// every origin. Nodes as such are never persisted — they are rebuilt from the
/// wire on every refresh; what is cached is the raw answer, so a cold start has
/// something to show before the first probe comes back.
final class ClientStore {

    private let defaults: UserDefaults
    private let directory: URL
    private let settingsStore: SettingsStore
    private let nodeCacheStore: NodeCacheStore

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent("RemoteEverything", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.settingsStore = SettingsStore(defaults: defaults)
        self.nodeCacheStore = NodeCacheStore(directory: directory)
    }

    /// Where pairing stages its pending setup, one file per origin.
    var pairingDirectory: URL {
        directory.appendingPathComponent("Pairing", isDirectory: true)
    }

    // MARK: - Settings

    func loadSettings() -> ClientSettings {
        settingsStore.loadSettings()
    }

    func saveSettings(_ settings: ClientSettings) {
        settingsStore.saveSettings(settings)
    }

    // MARK: - Identities

    func loadIdentities() -> [Identity] {
        settingsStore.loadIdentities()
    }

    func saveIdentities(_ identities: [Identity]) {
        settingsStore.saveIdentities(identities)
    }

    // MARK: - Node cache

    func cachedNodes(origin: String) -> NodesResponse? {
        nodeCacheStore.cachedNodes(origin: origin)
    }

    func saveCachedNodes(_ response: NodesResponse, origin: String) {
        nodeCacheStore.saveCachedNodes(response, origin: origin)
    }

    func clearCachedNodes(origin: String) {
        nodeCacheStore.clearCachedNodes(origin: origin)
    }
}
