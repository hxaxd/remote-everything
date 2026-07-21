import Foundation
import Security

/// Manages PKCS#12 credentials in the iOS Keychain with pending/active staging.
/// Mirrors Android's `DeviceIdentity`.
enum KeychainStore {
    private static let credentialService = "com.remoteeverything.credential"
    private static let passwordService = "com.remoteeverything.credential-password"

    enum KeychainError: Error, CustomStringConvertible {
        case importFailed(OSStatus)
        case notFound
        case duplicate
        case keyMismatch
        case invalidPKCS12
        case randomGenerationFailed(OSStatus)

        var description: String {
            switch self {
            case .importFailed(let status): return "Keychain 操作失败: \(status)"
            case .notFound: return "凭据未找到"
            case .duplicate: return "凭据已存在"
            case .keyMismatch: return "证书与私钥不匹配"
            case .invalidPKCS12: return "PKCS#12 文件无效"
            case .randomGenerationFailed(let status): return "安全随机数生成失败: \(status)"
            }
        }
    }

    // MARK: - Tag Construction

    /// Tag format maps to Android's SharedPreferences key namespace:
    /// "com.remoteeverything.credential.{installationId}.{state}" where state is "pending" or "active".
    enum CredentialState: String {
        case pending
        case active
    }

    private static func account(for installationId: String, state: CredentialState) -> String {
        "\(installationId).\(state.rawValue)"
    }

    // MARK: - Private Helpers

    /// SecPKCS12Import the raw bytes and extract the identity.
    private static func importPKCS12(data: Data, password: String) throws -> (SecIdentity, SecCertificate) {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess else {
            throw KeychainError.importFailed(status)
        }

        guard let array = items as? [[String: Any]],
              let first = array.first else {
            throw KeychainError.invalidPKCS12
        }

        guard let identity = first[kSecImportItemIdentity as String] as? SecIdentity,
              let trust = first[kSecImportItemTrust as String] as? SecTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            throw KeychainError.invalidPKCS12
        }

        return (identity, certificate)
    }

    /// Verify private key matches the certificate by signing a challenge.
    private static func verifyKeyPair(identity: SecIdentity) throws {
        var privateKey: SecKey?
        let copyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard copyStatus == errSecSuccess, let key = privateKey else {
            throw KeychainError.keyMismatch
        }

        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certStatus == errSecSuccess, let cert = certificate else {
            throw KeychainError.keyMismatch
        }

        guard let publicKey = SecCertificateCopyKey(cert) else {
            throw KeychainError.keyMismatch
        }

        // Sign a 32-byte challenge and verify
        let challenge = try randomData(count: 32)

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            &signError
        ) as Data? else {
            throw KeychainError.keyMismatch
        }

        let verified = SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            signature as CFData,
            &signError
        )

        guard verified else {
            throw KeychainError.keyMismatch
        }
    }

    // MARK: - Credential Password

    /// Generate a new random URL-safe password, stored in Keychain for recovery.
    /// Mirrors Android's `credentialPassword()`.
    static func credentialPassword(installationId: String) throws -> String {
        // Check if we already have a pending password
        if let existing = try? loadPassword(installationId: installationId, state: .pending) {
            return existing
        }

        let passwordData = try randomData(count: 24)
        let password = passwordData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        try storePassword(installationId: installationId, state: .pending, password: password)
        return password
    }

    // MARK: - Stage / Promote / Discard

    /// Store the PKCS#12 credential in pending state, validating key match and fingerprint.
    /// Mirrors Android's `stageCredential()`.
    static func stageCredential(
        installationId: String,
        encoded: String,
        password: String,
        expectedFingerprint: String
    ) throws {
        guard let pkcs12Data = Data(base64Encoded: encoded) else {
            throw KeychainError.invalidPKCS12
        }

        let (identity, certificate) = try importPKCS12(data: pkcs12Data, password: password)
        try verifyKeyPair(identity: identity)

        let certData = SecCertificateCopyData(certificate) as Data
        let actualFingerprint = GatewaySecurityPolicy.fingerprint(certificateData: certData)

        guard actualFingerprint == expectedFingerprint else {
            throw KeychainError.keyMismatch
        }

        try storeCredentialData(
            installationId: installationId,
            state: .pending,
            data: pkcs12Data
        )
        do {
            try storePassword(installationId: installationId, state: .pending, password: password)
        } catch {
            try? deleteCredential(installationId: installationId, state: .pending)
            throw error
        }
    }

    /// Atomically promote pending → active. Fails if no pending credential exists.
    /// Mirrors Android's `promoteCredential()`.
    static func promoteCredential(installationId: String) throws {
        guard try hasStagedCredential(installationId: installationId) else {
            throw KeychainError.notFound
        }

        let credential = try loadCredentialData(installationId: installationId, state: .pending)
        let password = try loadPassword(installationId: installationId, state: .pending)

        try storeCredentialData(installationId: installationId, state: .active, data: credential)
        do {
            try storePassword(installationId: installationId, state: .active, password: password)
        } catch {
            try? deleteCredential(installationId: installationId, state: .active)
            throw error
        }

        // Remove pending
        try deleteCredential(installationId: installationId, state: .pending)
        try deletePassword(installationId: installationId, state: .pending)
    }

    /// Check if a pending credential exists.
    static func hasStagedCredential(installationId: String) throws -> Bool {
        return (try? loadIdentity(installationId: installationId, state: .pending)) != nil
    }

    /// Check if an active credential exists.
    static func hasCredential(installationId: String) -> Bool {
        return (try? loadIdentity(installationId: installationId, state: .active)) != nil
    }

    /// Discard the pending credential and all associated secrets.
    /// Mirrors Android's `discardStagedCredential()`.
    static func discardStagedCredential(installationId: String) throws {
        try? deleteCredential(installationId: installationId, state: .pending)
        try? deletePassword(installationId: installationId, state: .pending)
    }

    /// Delete all credentials for a profile (pending, active, passwords).
    /// Mirrors Android's `removeCredential()`.
    static func deleteAll(for installationId: String) throws {
        try? deleteCredential(installationId: installationId, state: .pending)
        try? deleteCredential(installationId: installationId, state: .active)
        try? deletePassword(installationId: installationId, state: .pending)
        try? deletePassword(installationId: installationId, state: .active)
    }

    // MARK: - Identity Storage

    /// Load a client identity from the Keychain.
    static func loadIdentity(installationId: String, state: CredentialState) throws -> SecIdentity {
        let credential = try loadCredentialData(installationId: installationId, state: state)
        let password = try loadPassword(installationId: installationId, state: state)
        return try importPKCS12(data: credential, password: password).0
    }

    static func deleteCredential(installationId: String, state: CredentialState) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credentialService,
            kSecAttrAccount as String: account(for: installationId, state: state),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.importFailed(status)
        }
    }

    private static func storeCredentialData(
        installationId: String,
        state: CredentialState,
        data: Data
    ) throws {
        try upsertSecret(
            service: credentialService,
            account: account(for: installationId, state: state),
            data: data
        )
    }

    private static func loadCredentialData(
        installationId: String,
        state: CredentialState
    ) throws -> Data {
        try loadSecret(
            service: credentialService,
            account: account(for: installationId, state: state)
        )
    }

    // MARK: - Password Storage (for credential password)

    private static func storePassword(installationId: String, state: CredentialState, password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidPKCS12
        }
        try upsertSecret(
            service: passwordService,
            account: account(for: installationId, state: state),
            data: data
        )
    }

    private static func loadPassword(installationId: String, state: CredentialState) throws -> String {
        let data = try loadSecret(
            service: passwordService,
            account: account(for: installationId, state: state)
        )
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw KeychainError.notFound
        }
        return password
    }

    private static func deletePassword(installationId: String, state: CredentialState) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: account(for: installationId, state: state),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.importFailed(status)
        }
    }

    private static func upsertSecret(service: String, account: String, data: Data) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.importFailed(updateStatus)
        }

        var insert = lookup
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.importFailed(addStatus)
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw KeychainError.randomGenerationFailed(status)
        }
        return data
    }

    private static func loadSecret(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.notFound
        }
        return data
    }
}
