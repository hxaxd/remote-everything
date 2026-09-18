import Foundation
import Security

// The value types every layer shares. The field names are the ones the other two
// clients use for the same things, so a reader can hold the three side by side.

/// One pairing result for one gateway origin: the device certificate plus what
/// the client remembers about that gateway. The wire counterpart is the pairing
/// response; the certificate itself lives in platform secure storage (Keychain)
/// and is only ever referenced here by `credentialRef`.
struct Identity: Codable, Equatable, Identifiable {
    /// `https://host[:port]` — the origin the invitation carried.
    var origin: String
    /// The name this device was admitted under.
    var deviceName: String
    /// SHA-256 of the issued client certificate, 64 lowercase hex digits.
    var certFingerprint: String
    /// The Keychain account this origin's credential is stored under. Never a key.
    var credentialRef: String
    /// Present only for a gateway that signs its own certificate (a LAN entrance).
    var serverPin: ServerPin?
    var createdAt: Date

    var id: String { origin }
}

/// The two halves of a self-signed gateway's identity: the certificate
/// fingerprint it was first seen with, and the public key pin that survives a
/// renewal that keeps the key.
struct ServerPin: Codable, Equatable {
    var certFingerprint: String
    var publicKeyPin: String
}

/// The merged view of one machine: the same node id seen through one or more
/// gateways. Built in memory from the wire on every refresh — never persisted
/// and never edited row by row.
struct Node: Identifiable, Equatable {
    /// 64 lowercase hex digits.
    var id: String
    var name: String
    var paths: [Path]
}

/// One gateway's road to a node.
struct Path: Equatable {
    var origin: String
    var identityRef: String
    /// nil = not probed yet.
    var reachable: Bool?
    var latencyMs: Int?
    /// Whether the origin's host is a private address (RFC1918 / link-local).
    var isPrivate: Bool
    var lastCheckedAt: Date?
}

/// S1's per-row state machine. `unknown` is the initial transient.
enum NodeStatus: Equatable {
    case unknown
    case onlineLan
    case onlineTunnel
    case offline
    case pendingApproval

    var isOnline: Bool {
        self == .onlineLan || self == .onlineTunnel
    }
}

/// catalog.schema.json's per-application code.
enum AppState: String, Codable, Equatable {
    case ready
    case starting
    case stopping
    case stopped
}

/// One application a node runs — catalog.schema.json's apps[] entry.
struct AppInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var icon: String
    var accent: String
    var launchFragment: String
    var enabled: Bool
    var running: Bool
    var code: AppState
}

/// Every refusal code in contracts/schemas/errors.schema.json — all nineteen,
/// none dropped, spelled exactly as the wire spells them.
enum ErrorCode: String, Codable, Equatable, CaseIterable {
    case nodeRequired = "node_required"
    case unauthorized
    case invitationDenied = "invitation_denied"
    case invitationExpired = "invitation_expired"
    case approvalPending = "approval_pending"
    case nodeNotFound = "node_not_found"
    case appNotFound = "app_not_found"
    case notFound = "not_found"
    case forbidden
    case computerOffline = "computer_offline"
    case activationFailed = "activation_failed"
    case invalidDeviceName = "invalid_device_name"
    case invalidCredentialPassword = "invalid_credential_password"
    case invalidBody = "invalid_body"
    case invalidJson = "invalid_json"
    case rateLimited = "rate_limited"
    case serverBusy = "server_busy"
    case pairingFailed = "pairing_failed"
    case internalError = "internal_error"
}

/// A refusal from the wire: the code drives presentation, never the prose.
/// `httpStatus` is carried for logging and for the "same decision written twice"
/// rule; when the two disagree the code wins.
struct ClientError: Error, Equatable {
    let code: ErrorCode
    let httpStatus: Int?

    init(_ code: ErrorCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }
}

/// A failure below the protocol: DNS, TLS, timeout, cancellation. No code
/// travels here, and no code is invented for it.
struct NetworkFailure: Error {
    let underlying: Error?

    init(_ underlying: Error? = nil) {
        self.underlying = underlying
    }
}

/// Where a node's credential stands, as the UI needs to say it.
enum IdentityCondition: Equatable {
    case ok
    /// The gateway refused this device: authorisation was withdrawn. The
    /// credential is kept — a temporary gateway fault must not cost a pairing.
    case unauthorized
    /// The credential is not in secure storage: pair again, and say so.
    case needsPairing
    /// The gateway could not be reached at all.
    case unreachable
}

/// The device credential as the TLS stack needs it: the identity and the chain
/// that goes with it.
struct DeviceCredential {
    let identity: SecIdentity
    let certificates: [SecCertificate]
}
