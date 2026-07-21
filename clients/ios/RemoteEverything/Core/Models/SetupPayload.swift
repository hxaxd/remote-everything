import Foundation

/// Parsed setup URI payload. Mirrors Android's `SetupPayload`.
struct SetupPayload {
    let profile: ConnectionConfig
    let invitation: String
}
