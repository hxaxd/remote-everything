import Foundation
import Observation

/// Persists non-secret profile metadata.
/// Mirrors Android's `SettingsStore` / `SetupProfileStore`.
@Observable
final class ProfileStore {
    private let defaults = UserDefaults.standard
    private let profilesKey = "remote_everything_profiles"
    private let activeProfileKey = "remote_everything_active_profile"

    var profiles: [ConnectionConfig] = []

    func load() throws {
        guard let data = defaults.data(forKey: profilesKey) else {
            profiles = []
            return
        }
        let decoder = JSONDecoder()
        profiles = try decoder.decode([ConnectionConfig].self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(profiles)
        defaults.set(data, forKey: profilesKey)
    }

    func add(_ profile: ConnectionConfig) throws {
        profiles.removeAll { $0.installationId == profile.installationId }
        profiles.append(profile)
        try save()
    }

    func remove(installationId: String) throws {
        profiles.removeAll { $0.installationId == installationId }
        try save()
        if activeInstallationId() == installationId {
            setActiveInstallationId(nil)
        }
        try KeychainStore.deleteAll(for: installationId)
    }

    func activeInstallationId() -> String? {
        let value = defaults.string(forKey: activeProfileKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func setActiveInstallationId(_ installationId: String?) {
        if let installationId, !installationId.isEmpty {
            defaults.set(installationId, forKey: activeProfileKey)
        } else {
            defaults.removeObject(forKey: activeProfileKey)
        }
    }
}
