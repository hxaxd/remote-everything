import Foundation

/// Strict parser for `remote-everything://setup` URIs.
/// Mirrors Android's `AppConfig` and Go `internal/setup/setup.go`.
enum SetupParser {
    private static let installationIdPattern = try! Regex("^[a-f0-9]{64}$")
    private static let fingerprintPattern = try! Regex("^[a-f0-9]{64}$")
    private static let invitationPattern = try! Regex("^[A-Za-z0-9_-]{43}$")
    private static let publicKeyPinPattern = try! Regex("^[A-Za-z0-9+/]{43}=$")

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ uriString: String) throws -> SetupPayload {
        guard let url = URL(string: uriString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "remote-everything",
              url.host == "setup",
              (url.path.isEmpty || url.path == "/"),
              url.fragment == nil else {
            throw ParseError(description: "初始化链接无效")
        }

        guard let query = url.query else {
            throw ParseError(description: "初始化链接缺少参数")
        }

        var values: [String: String] = [:]
        for item in query.split(separator: "&") where !item.isEmpty {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw ParseError(description: "初始化链接参数无效")
            }
            let key = try decodeQueryPart(String(parts[0]))
            guard values[key] == nil else {
                throw ParseError(description: "初始化链接包含重复参数")
            }
            values[key] = try decodeQueryPart(String(parts[1]))
        }

        guard values["v"] == "2" else {
            throw ParseError(description: "初始化链接版本不受支持")
        }

        let mode = values["mode"] ?? ""
        let expectedKeys: Set<String> = mode == "lan"
            ? ["v", "id", "name", "mode", "origin", "fingerprint", "public_key_pin"]
            : ["v", "id", "name", "mode", "origin", "invitation"]

        guard Set(values.keys) == expectedKeys else {
            throw ParseError(description: "初始化链接参数不完整")
        }

        let profile = try create(
            installationId: values["id"] ?? "",
            name: values["name"] ?? "",
            mode: mode,
            origin: values["origin"] ?? "",
            fingerprint: values["fingerprint"] ?? "",
            publicKeyPin: values["public_key_pin"] ?? ""
        )

        if mode == "public" {
            let invitation = values["invitation"] ?? ""
            guard try invitationPattern.wholeMatch(in: invitation) != nil else {
                throw ParseError(description: "公网邀请无效")
            }
            return SetupPayload(profile: profile, invitation: invitation)
        }

        return SetupPayload(profile: profile, invitation: "")
    }

    static func create(
        installationId: String,
        name: String,
        mode: String,
        origin: String,
        fingerprint: String = "",
        publicKeyPin: String = ""
    ) throws -> ConnectionConfig {
        guard try installationIdPattern.wholeMatch(in: installationId) != nil else {
            throw ParseError(description: "安装实例标识无效")
        }

        let normalized = name.trimmingCharacters(in: .whitespaces)
        let codePoints = normalized.unicodeScalars.count
        guard !normalized.isEmpty && codePoints <= 80 &&
              normalized.allSatisfy({ $0.asciiValue ?? 128 >= 32 && $0.asciiValue != 127 }) else {
            throw ParseError(description: "安装实例名称无效")
        }

        guard mode == "lan" || mode == "public" else {
            throw ParseError(description: "连接模式无效")
        }

        guard let parsed = URL(string: origin.trimmingCharacters(in: .whitespaces)),
              parsed.scheme == "https",
              parsed.host != nil,
              parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              (parsed.path.isEmpty || parsed.path == "/") else {
            throw ParseError(description: "服务地址必须是 HTTPS 源站")
        }

        guard parsed.port != 0 else {
            throw ParseError(description: "服务地址端口无效")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = parsed.host!.lowercased()
        components.port = parsed.port
        guard let normalizedOrigin = components.url?.absoluteString else {
            throw ParseError(description: "服务地址必须是 HTTPS 源站")
        }

        let normalizedFingerprint = fingerprint
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")

        let configMode: ConnectionConfig.ConnectionMode = mode == "lan" ? .lan : .public
        if configMode == .lan {
            guard try fingerprintPattern.wholeMatch(in: normalizedFingerprint) != nil else {
                throw ParseError(description: "局域网服务证书指纹无效")
            }
            guard try publicKeyPinPattern.wholeMatch(in: publicKeyPin) != nil else {
                throw ParseError(description: "局域网服务公钥摘要无效")
            }
        }

        return ConnectionConfig(
            installationId: installationId,
            name: normalized,
            mode: configMode,
            gatewayOrigin: normalizedOrigin,
            gatewayFingerprint: configMode == .lan ? normalizedFingerprint : "",
            gatewayPublicKeyPin: configMode == .lan ? publicKeyPin : ""
        )
    }

    private static func decodeQueryPart(_ value: String) throws -> String {
        let formEncoded = value.replacingOccurrences(of: "+", with: " ")
        guard let decoded = formEncoded.removingPercentEncoding else {
            throw ParseError(description: "初始化链接参数编码无效")
        }
        return decoded
    }
}
