import Foundation

/// A saved connection profile. Mirrors Android's `ConnectionConfig`.
struct ConnectionConfig: Codable, Hashable, Identifiable {
    let installationId: String
    let name: String
    let mode: ConnectionMode
    let gatewayOrigin: String
    let gatewayFingerprint: String
    let gatewayPublicKeyPin: String
    let accessToken: String

    var id: String { installationId }

    enum ConnectionMode: String, Codable {
        case lan
        case `public`
    }

    var gatewayHost: String {
        URL(string: gatewayOrigin)?.host ?? gatewayOrigin
    }

    var gatewayPort: Int {
        URL(string: gatewayOrigin)?.port ?? 443
    }

    var pairUrl: String { "\(gatewayOrigin)/__remote_everything_pair" }
    var activateUrl: String { "\(gatewayOrigin)/__remote_everything_activate" }
    var appsUrl: String { "\(gatewayOrigin)/__remote_everything/apps" }

    func appActionUrl(id: String, action: String) -> String {
        "\(appsUrl)/\(id)/\(action)"
    }

    func appOpenUrl(id: String) -> String {
        "\(gatewayOrigin)/__remote_everything/open/\(id)"
    }

    func authorizationHeaders() -> [String: String] {
        if mode == .lan && !accessToken.isEmpty {
            return ["Authorization": "Bearer \(accessToken)"]
        }
        return [:]
    }

    func isGatewayEndpoint(host: String?, port: Int) -> Bool {
        host?.lowercased() == gatewayHost.lowercased() && port == gatewayPort
    }

    func isGatewayUrl(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.host != nil else {
            return false
        }
        return isGatewayEndpoint(host: url.host, port: url.port ?? 443)
    }
}
