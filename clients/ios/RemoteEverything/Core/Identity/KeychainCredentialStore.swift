import Foundation
import Security

/// The one Keychain item an origin's credential lives in: the PKCS#12 bytes and
/// the one-shot password that opens them, together.
///
/// Together is the point. Two items would leave a window in which one exists
/// without the other, and a credential that cannot be opened is worse than no
/// credential at all. One item is written in one call and deleted in one call.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: usable while the app is
/// in the background after the first unlock, never synced to iCloud, never
/// carried to another device by a backup. Changing phones means pairing again.
final class KeychainCredentialStore {

    enum Failure: Error, Equatable {
        case writeFailed(OSStatus)
        case malformedRecord
    }

    /// What one item holds. Versioned so a future change can be told apart
    /// rather than misread.
    private struct Record: Codable {
        var schema: Int
        var password: String
        var pkcs12: String
    }

    private let service: String
    private let label: String

    init(service: String = "com.remoteeverything.credential") {
        self.service = service
        self.label = "Remote Everything device credential"
    }

    func store(alias: String, pkcs12: Data, password: String) throws {
        let record = Record(schema: 1, password: password, pkcs12: pkcs12.base64EncodedString())
        let encoder = JSONEncoder()
        guard let payload = try? encoder.encode(record) else { throw Failure.malformedRecord }

        // Replace, never update: the old item is gone before the new one exists,
        // so a half-written credential is not something a reader can find.
        delete(alias: alias)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: payload,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.writeFailed(status) }
    }

    func load(alias: String) -> (pkcs12: Data, password: String)? {
        guard let payload = loadPayload(alias: alias) else { return nil }
        let decoder = JSONDecoder()
        guard let record = try? decoder.decode(Record.self, from: payload), record.schema == 1,
              let pkcs12 = Data(base64Encoded: record.pkcs12)
        else { return nil }
        return (pkcs12, record.password)
    }

    func exists(alias: String) -> Bool {
        loadPayload(alias: alias) != nil
    }

    func delete(alias: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private func loadPayload(alias: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let payload = item as? Data else { return nil }
        return payload
    }
}
