import Foundation

/// An application registered on the node. Mirrors Android's `RemoteApp`.
struct RemoteApp: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let accent: String
    let openUrl: String
    let code: AppCode

    enum AppCode: String, Codable {
        case ready
        case starting
        case stopping
        case stopped
    }
}

/// A catalog snapshot returned by the gateway. Mirrors Android's `CatalogSnapshot`.
struct CatalogSnapshot: Codable {
    let computerConnected: Bool
    let code: String
    let apps: [RemoteApp]
}
