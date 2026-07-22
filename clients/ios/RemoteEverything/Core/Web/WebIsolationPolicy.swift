import Foundation
import CryptoKit

/// Determines WebView data store identifiers and routing cookies.
/// Mirrors Android's `WebIsolationPolicy`.
enum WebIsolationPolicy {

    /// Generate the stable UUID used by the persistent WebKit data store.
    static func profileUUID(installationId: String, appId: String) -> UUID {
        let input = installationId + "\0" + appId
        let hash = SHA256.hash(data: Data(input.utf8))
        var bytes = [UInt8](hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Generate a stable, unique data store identifier for `WKWebsiteDataStore(forIdentifier:)`.
    /// Result: `SHA-256(installationId + NUL + appId)` mapped to a UUID string.
    static func profileIdentifier(installationId: String, appId: String) -> String {
        profileUUID(installationId: installationId, appId: appId).uuidString
    }

    /// The routing cookie set before first navigation.
    /// Format: `RemoteEverythingApp=<appId>; Path=/; Secure; SameSite=Strict`
    static func routingCookie(appId: String, origin: String) -> [String: String] {
        return [
            "name": "RemoteEverythingApp",
            "value": appId,
            "path": "/",
            "secure": "true",
        ]
    }
}
