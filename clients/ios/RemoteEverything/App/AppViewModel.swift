import Foundation
import Observation
import Security

@Observable
final class AppViewModel {
    var profiles: [ConnectionConfig] = []
    var activeProfile: ConnectionConfig?
    var catalogSnapshot: CatalogSnapshot?
    var navigationPath: [AppRoute] = []

    // Setup flow
    var setupTransaction: SetupTransaction?
    let profileStore: ProfileStore
    let identityStore: AppIdentityStore

    init() {
        self.profileStore = ProfileStore()
        self.identityStore = AppIdentityStore()
    }

    enum AppRoute: Hashable {
        case catalog
        case connections
        case settings
        case remote(appId: String, openUrl: String)
        case setupWizard
    }

    func loadProfiles() throws {
        try profileStore.load()
        profiles = profileStore.profiles
    }

    func activateProfile(_ profile: ConnectionConfig) throws {
        try profileStore.add(profile)
        profileStore.setActiveInstallationId(profile.installationId)
        activeProfile = profile
    }

    func removeProfile(_ installationId: String) throws {
        try profileStore.remove(installationId: installationId)
        if activeProfile?.installationId == installationId {
            activeProfile = nil
        }
    }

    func switchToProfile(_ profile: ConnectionConfig) {
        profileStore.setActiveInstallationId(profile.installationId)
        activeProfile = profile
    }
}

/// Bridges KeychainStore to the SetupIdentityStore protocol for the setup transaction.
/// Mirrors Android's `DeviceIdentity` class which implements `SetupIdentityStore`.
@Observable
final class AppIdentityStore: SetupIdentityStore {
    func credentialPassword(installationId: String) throws -> String {
        try KeychainStore.credentialPassword(installationId: installationId)
    }

    func stageCredential(
        installationId: String,
        encoded: String,
        password: String,
        expectedFingerprint: String
    ) throws {
        try KeychainStore.stageCredential(
            installationId: installationId,
            encoded: encoded,
            password: password,
            expectedFingerprint: expectedFingerprint
        )
    }

    func stagedClientIdentity(installationId: String) throws -> ClientIdentity? {
        let identity = try KeychainStore.loadIdentity(
            installationId: installationId,
            state: .pending
        )

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)

        var chain: [SecCertificate] = []
        if let cert = certificate {
            chain = [cert]
        }

        return ClientIdentity(identity: identity, certificateChain: chain)
    }

    func promoteCredential(installationId: String) throws {
        try KeychainStore.promoteCredential(installationId: installationId)
    }

    func hasStagedCredential(installationId: String) throws -> Bool {
        try KeychainStore.hasStagedCredential(installationId: installationId)
    }

    func discardStagedCredential(installationId: String) throws {
        try KeychainStore.discardStagedCredential(installationId: installationId)
    }
}

/// Make ProfileStore conform to SetupProfileStore for setup transactions.
extension ProfileStore: SetupProfileStore {
    private static let stagedProfileKey = "remote_everything_staged_profile"

    func stagedProfile() -> ConnectionConfig? {
        guard let data = UserDefaults.standard.data(forKey: Self.stagedProfileKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectionConfig.self, from: data)
    }

    func stageProfile(_ value: ConnectionConfig) throws {
        let data = try JSONEncoder().encode(value)
        UserDefaults.standard.set(data, forKey: Self.stagedProfileKey)
    }

    func commitStagedProfile() throws -> ConnectionConfig {
        guard let staged = stagedProfile() else {
            throw ProfileStoreError.missingStagedProfile
        }
        try add(staged)
        discardStagedProfile()
        return staged
    }

    func discardStagedProfile() {
        UserDefaults.standard.removeObject(forKey: Self.stagedProfileKey)
    }
}

enum ProfileStoreError: Error {
    case missingStagedProfile
}
