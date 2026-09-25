import Foundation

/// Where a detail column can go. S1 → S3 → S4, and S2 pushed over any of them;
/// settings is a pushed page on a phone (a sheet cannot follow an appearance
/// change reliably) and a pane beside the list on a wide screen.
enum AppRoute: Hashable {
    case node(String)
    case application(nodeID: String, appID: String)
    case pair
    case settings
}

/// S3's whole-page state — the five phases all three clients share: loading,
/// the applications, the machine off, the device refused, and a gateway in
/// trouble. A catalog the phone simply cannot reach is an offline machine, not
/// a state of its own; a gateway that answers a refusal it does not understand
/// is one in trouble. (The other two clients read it the same way.)
enum CatalogState: Equatable {
    case loading
    case ready([AppInfo])
    /// `computer_offline` is an answer, and so is "could not be reached at all":
    /// the machine is off, asleep, or its tunnel is down.
    case offline
    /// The gateway says this device may not reach the node any more.
    case unauthorized
    /// The gateway answered, and its answer is a refusal that is neither the
    /// machine being off nor this device being refused: the deployment, not the
    /// phone, is the question.
    case gatewayTrouble

    var applications: [AppInfo] {
        if case .ready(let apps) = self { return apps }
        return []
    }
}

/// The light notices (toast/banner) — nothing here is a page.
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
    /// The device paired and its operator has not approved it yet: the page
    /// stays open on the same screen Android keeps, with a retry and a way back.
    case pendingApproval(nodeName: String)
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
