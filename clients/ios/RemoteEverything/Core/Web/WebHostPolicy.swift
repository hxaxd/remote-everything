import Foundation
import WebKit

enum WebHostPolicy {
    static func mayOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http", "mailto", "tel"].contains(scheme)
    }

    static func mayDownload(_ url: URL, config: ConnectionConfig) -> Bool {
        if isStrictGatewayURL(url, config: config) {
            return true
        }
        guard url.scheme?.lowercased() == "blob" else { return false }
        let value = url.absoluteString
        guard value.lowercased().hasPrefix("blob:"),
              let embeddedURL = URL(string: String(value.dropFirst(5))) else {
            return false
        }
        return isStrictGatewayURL(embeddedURL, config: config)
    }

    /// HTTP redirects are evaluated independently at every WKDownload hop.
    /// A blob URL can initiate a download but can never be an HTTP redirect target.
    static func mayFollowDownloadRedirect(_ url: URL, config: ConnectionConfig) -> Bool {
        isStrictGatewayURL(url, config: config)
    }

    static func isGatewayOrigin(_ origin: WKSecurityOrigin, config: ConnectionConfig) -> Bool {
        guard let gateway = URL(string: config.gatewayOrigin),
              origin.protocol.lowercased() == gateway.scheme?.lowercased(),
              origin.host.lowercased() == gateway.host?.lowercased() else { return false }
        let expectedPort = gateway.port ?? (gateway.scheme?.lowercased() == "https" ? 443 : 80)
        return origin.port == expectedPort
    }

    static func safeFilename(_ proposed: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let parts = proposed.components(separatedBy: forbidden)
        let value = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "." || value == ".." { return "download" }
        return String(value.prefix(120))
    }

    private static func isStrictGatewayURL(_ url: URL, config: ConnectionConfig) -> Bool {
        url.user == nil &&
            url.password == nil &&
            GatewaySecurityPolicy.isGatewayOrigin(url, config: config)
    }
}
