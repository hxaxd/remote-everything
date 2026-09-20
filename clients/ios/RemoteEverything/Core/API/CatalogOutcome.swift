import Foundation

/// What a catalog answer means for the screen — the same four conclusions every
/// client draws, so the behaviour fixtures can assert them by name.
enum CatalogOutcome: Equatable {
    case apps([AppInfo])
    case offline
    case unauthorized
    case gatewayTrouble

    /// The screen one catalog answer calls for. `computer_offline` is an answer,
    /// not a failure: the machine is off, and the screen says so.
    static func forAnswer(_ response: CatalogResponse) -> CatalogOutcome {
        guard response.computerConnected else { return .offline }
        return .apps(response.applicationInfos)
    }

    /// The screen one refusal calls for.
    static func forRefusal(_ error: ClientError) -> CatalogOutcome {
        switch error.code {
        case .unauthorized, .nodeRequired, .nodeNotFound:
            return .unauthorized
        case .computerOffline:
            return .offline
        default:
            return .gatewayTrouble
        }
    }
}
