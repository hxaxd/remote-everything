import Foundation

/// Decoded pairing credential from the server. Mirrors Android's `PairingCredential`.
struct PairingCredential {
    let encoded: String
    let fingerprint: String
    let pendingExpiresAt: String
}
