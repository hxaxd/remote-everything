import Foundation

/// Where a detail column can go. S1 → S3 → S4.
enum AppRoute: Hashable {
    case node(String)
    case application(nodeID: String, appID: String)
}

/// S3's whole-page state (ui-contract §2/S3).
enum CatalogState: Equatable {
    case loading
    case ready([AppInfo])
    /// `computer_offline` is an answer, not an error: the machine is off, asleep
    /// or its tunnel is down.
    case offline
    /// The gateway says this device may not reach the node any more.
    case unauthorized
    /// The gateway itself could not be reached: the network, not the node.
    case unreachable
    case refused(ClientError)

    var applications: [AppInfo] {
        if case .ready(let apps) = self { return apps }
        return []
    }
}

/// The light notices (toast/banner) of ui-contract §3 — nothing here is a page.
enum Notice: Equatable, Identifiable {
    case busy
    case appGone
    case stopFailed
    case controlFailed
    case network
    case nodeGone
    case invitationExpired
    case credentialLost(String)

    var id: String {
        switch self {
        case .busy: return "busy"
        case .appGone: return "appGone"
        case .stopFailed: return "stopFailed"
        case .controlFailed: return "controlFailed"
        case .network: return "network"
        case .nodeGone: return "nodeGone"
        case .invitationExpired: return "invitationExpired"
        case .credentialLost(let origin): return "credentialLost-\(origin)"
        }
    }
}

/// S2's state machine.
enum PairingPhase: Equatable {
    case idle
    case pairing
    case failed(PairingFailure)
}

enum PairingFailure: Equatable {
    case refusal(ClientError)
    case network
    /// A client-side failure: malformed values on the way in or out. It is our
    /// bug, and the copy says so rather than blaming the operator.
    case client
}

enum UpdateState: Equatable {
    case idle
    case checking
    case result(UpdateResult)
}

/// What an application's WebView needs: where to go, and who answers for it.
struct WebTarget {
    let gatewayOrigin: String
    let url: URL
    let handler: GatewayChallengeHandler
    let isPrivate: Bool
}
