import Foundation
import Security

/// Where a gateway's credential lives, once the private key is no longer ours to
/// export. An identity references its own Keychain entry; pending replacements
/// use separate entries until admitted, so cancellation preserves live keys.
///
/// Used from the main thread only: the import cache is not synchronised, and the
/// one place a credential is needed off the main thread (a TLS challenge) is
/// handed a credential that was resolved before the request started.
final class IdentityVault {

    enum Failure: Error, Equatable {
        /// No credential is stored for this origin: the identity is an orphan.
        case missingCredential
        /// The stored credential could not be opened or is not a usable pair.
        case unusableCredential
    }

    private let keychain: KeychainCredentialStore
    private var imported: [String: DeviceCredential] = [:]
    private var versions: [String: Int] = [:]
    func version(origin: String) -> Int { versions[Self.alias(forOrigin:origin),default:0] }
    func version(aliasRef: String) -> Int { versions[aliasRef, default: 0] }

    init(keychain: KeychainCredentialStore = KeychainCredentialStore()) {
        self.keychain = keychain
    }

    /// The Keychain account an origin's credential is filed under.
    static func alias(forOrigin origin: String) -> String {
        Digest.originAlias(origin)
    }

    /// Writes a newly issued credential as one item, and returns the reference to
    /// keep. The password never leaves this call.
    @discardableResult
    func store(origin: String, pkcs12: Data, password: String) throws -> String {
        let alias = IdentityVault.alias(forOrigin: origin)
        try keychain.store(alias: alias, pkcs12: pkcs12, password: password)
        versions[alias,default:0] += 1
        _ = imported.removeValue(forKey: alias)
        return alias
    }

    /// Whether an origin's credential is present. This is what a profile is
    /// checked against: a profile whose credential is gone is an orphan.
    func hasCredential(origin: String) -> Bool {
        keychain.exists(alias: IdentityVault.alias(forOrigin: origin))
    }
    func hasCredential(aliasRef: String) -> Bool { keychain.exists(alias: aliasRef) }

    func storePending(pkcs12: Data, password: String) throws -> String {
        let alias = "pending-" + UUID().uuidString
        try keychain.store(alias: alias, pkcs12: pkcs12, password: password)
        return alias
    }

    /// Loads the device credential for an origin, re-importing it when the cache
    /// does not hold it yet.
    func credential(origin: String) throws -> DeviceCredential {
        try credential(aliasRef: IdentityVault.alias(forOrigin: origin))
    }

    func credential(aliasRef alias: String) throws -> DeviceCredential {
        if let cached = imported[alias] { return cached }
        guard let record = keychain.load(alias: alias) else { throw Failure.missingCredential }
        do {
            let material = try CredentialMaterial.importPKCS12(record.pkcs12, password: record.password)
            let credential = material.credential
            imported[alias] = credential
            return credential
        } catch {
            throw Failure.unusableCredential
        }
    }

    /// Resolves and caches a credential ahead of the traffic that needs it, so a
    /// TLS challenge is answered without a re-import in the middle of a handshake.
    @discardableResult
    func prepare(origin: String) -> DeviceCredential? {
        do {
            return try credential(origin: origin)
        } catch {
            return nil
        }
    }
    func prepare(aliasRef: String) -> DeviceCredential? { try? credential(aliasRef: aliasRef) }

    /// Deletes an origin's credential. The reference and the material go together.
    func forget(origin: String) {
        let alias = IdentityVault.alias(forOrigin: origin)
        versions[alias,default:0] += 1
        keychain.delete(alias: alias)
        _ = imported.removeValue(forKey: alias)
    }

    /// Drops a credential that no identity and no staged setup refers to any more.
    func forget(aliasRef: String) {
        versions[aliasRef,default:0] += 1
        keychain.delete(alias: aliasRef)
        _ = imported.removeValue(forKey: aliasRef)
    }
}
