import CryptoKit
import Foundation

enum WebSessionScope {
    static func profileName(gatewayOrigin: String, appKey: String) -> String {
        precondition(!gatewayOrigin.isEmpty && !appKey.isEmpty &&
                     !gatewayOrigin.contains("\n") && !appKey.contains("\n"))
        let input = "remote-everything:web-session\n\(gatewayOrigin)\n\(appKey)"
        return "app-" + SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func identifier(gatewayOrigin: String, appKey: String) -> UUID {
        let hex = String(profileName(gatewayOrigin: gatewayOrigin, appKey: appKey).dropFirst(4).prefix(32))
        let parts = [8, 4, 4, 4, 12]
        var offset = hex.startIndex
        let formatted = parts.map { count in
            let end = hex.index(offset, offsetBy: count)
            defer { offset = end }
            return String(hex[offset..<end])
        }.joined(separator: "-")
        return UUID(uuidString: formatted)!
    }
}
