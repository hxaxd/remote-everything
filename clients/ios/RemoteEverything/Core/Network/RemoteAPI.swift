import Foundation

/// Strict API decoder for gateway responses.
/// Mirrors Android's `RemoteApi` and Go server response shapes.
enum RemoteAPI {
    private static let appIdPattern = try! Regex("^[a-z0-9][a-z0-9._-]{0,63}$")
    private static let fingerprintPattern = try! Regex("^[a-f0-9]{64}$")
    private static let accentPattern = try! Regex("^#[0-9A-Fa-f]{6}$")

    private static let catalogKeys: Set<String> = ["ok", "computer_connected", "code", "apps"]
    private static let appKeys: Set<String> = [
        "id", "name", "description", "icon", "accent",
        "launch_fragment", "computer_connected", "enabled", "running", "code"
    ]
    private static let pairingKeys: Set<String> = [
        "ok", "device_name", "certificate_fingerprint",
        "credential_format", "credential_pkcs12", "pending_expires_at"
    ]
    private static let actionKeys: Set<String> = [
        "ok", "action", "computer_connected", "enabled", "running", "code"
    ]

    enum APIError: Error, CustomStringConvertible {
        case invalidFields(String)
        case inconsistentState(String)
        case deviceAuthorization
        case httpStatus(Int)

        var description: String {
            switch self {
            case .invalidFields(let msg): return "字段无效: \(msg)"
            case .inconsistentState(let msg): return "状态不一致: \(msg)"
            case .deviceAuthorization: return "设备授权已失效"
            case .httpStatus(let code): return "服务返回 \(code)"
            }
        }
    }

    // MARK: - Catalog

    static func decodeCatalog(config: ConnectionConfig, json: [String: Any]) throws -> CatalogSnapshot {
        let keys = Set(json.keys)
        guard keys == catalogKeys else {
            throw APIError.invalidFields("目录响应字段无效")
        }
        guard json["ok"] as? Bool == true else {
            throw APIError.invalidFields(json["code"] as? String ?? "unknown")
        }
        let connected = json["computer_connected"] as? Bool ?? false
        let code = json["code"] as? String ?? ""
        guard let rawApps = json["apps"] as? [[String: Any]] else {
            throw APIError.invalidFields("目录响应缺少 apps")
        }

        var ids = Set<String>()
        let apps: [RemoteApp] = try rawApps.map { appJson in
            let app = try decodeApp(config: config, json: appJson)
            guard ids.insert(app.id).inserted else {
                throw APIError.invalidFields("应用目录 ID 重复")
            }
            return app
        }

        if connected {
            guard code == "ready" else {
                throw APIError.inconsistentState("目录连接状态无效")
            }
        } else {
            guard code == "computer_offline" && apps.isEmpty else {
                throw APIError.inconsistentState("目录连接状态无效")
            }
        }

        return CatalogSnapshot(computerConnected: connected, code: code, apps: apps)
    }

    private static func decodeApp(config: ConnectionConfig, json: [String: Any]) throws -> RemoteApp {
        let keys = Set(json.keys)
        guard keys == appKeys else {
            throw APIError.invalidFields("应用目录字段无效")
        }

        let id = json["id"] as? String ?? ""
        let name = json["name"] as? String ?? ""
        let description = json["description"] as? String ?? ""
        let icon = json["icon"] as? String ?? ""
        let accent = json["accent"] as? String ?? ""
        let launchFragment = json["launch_fragment"] as? String ?? ""
        let connected = json["computer_connected"] as? Bool ?? false
        let enabled = json["enabled"] as? Bool ?? false
        let running = json["running"] as? Bool ?? false
        let code = json["code"] as? String ?? ""

        let expectedCode: String
        if enabled {
            expectedCode = running ? "ready" : "starting"
        } else {
            expectedCode = running ? "stopping" : "stopped"
        }

        guard try appIdPattern.wholeMatch(in: id) != nil,
              validMetadata(name, max: 80, allowEmpty: false),
              validMetadata(description, max: 240, allowEmpty: true),
              validMetadata(icon, max: 4, allowEmpty: true),
              try accentPattern.wholeMatch(in: accent) != nil,
              launchFragment.isEmpty || (launchFragment.hasPrefix("#") && validMetadata(launchFragment, max: 2048, allowEmpty: false)),
              connected,
              code == expectedCode else {
            throw APIError.invalidFields("应用目录内容无效")
        }

        return RemoteApp(
            id: id,
            name: name,
            description: description,
            icon: icon,
            accent: accent,
            openUrl: config.appOpenUrl(id: id) + launchFragment,
            code: RemoteApp.AppCode(rawValue: code) ?? .stopped
        )
    }

    // MARK: - Pairing

    static func decodePairingCredential(json: [String: Any]) throws -> PairingCredential {
        let keys = Set(json.keys)
        guard keys == pairingKeys, json["ok"] as? Bool == true else {
            throw APIError.invalidFields("配对响应字段无效")
        }

        let deviceName = json["device_name"] as? String ?? ""
        guard !deviceName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError.invalidFields("配对设备名无效")
        }

        let certFingerprint = json["certificate_fingerprint"] as? String ?? ""
        guard try fingerprintPattern.wholeMatch(in: certFingerprint) != nil else {
            throw APIError.invalidFields("配对证书指纹无效")
        }

        let format = json["credential_format"] as? String ?? ""
        guard format == "pkcs12" else {
            throw APIError.invalidFields("配对凭据格式无效")
        }

        let expiresAt = json["pending_expires_at"] as? String ?? ""
        guard let _ = ISO8601DateFormatter().date(from: expiresAt) else {
            throw APIError.invalidFields("配对期限无效")
        }

        let encoded = json["credential_pkcs12"] as? String ?? ""
        guard !encoded.isEmpty else {
            throw APIError.invalidFields("配对凭据为空")
        }

        return PairingCredential(encoded: encoded, fingerprint: certFingerprint, pendingExpiresAt: expiresAt)
    }

    // MARK: - Control

    static func decodeAction(config: ConnectionConfig, expectedAction: String, json: [String: Any]) throws -> Bool {
        let keys = Set(json.keys)
        let validKeySets = [actionKeys, actionKeys.union(["app"]), actionKeys.union(["app", "error_code"])]
        guard validKeySets.contains(keys) else {
            throw APIError.invalidFields("控制响应字段无效")
        }

        let ok = json["ok"] as? Bool ?? false
        let action = json["action"] as? String ?? ""
        let connected = json["computer_connected"] as? Bool ?? false
        let enabled = json["enabled"] as? Bool ?? false
        let running = json["running"] as? Bool ?? false
        let code = json["code"] as? String ?? ""

        guard action == expectedAction else {
            throw APIError.invalidFields("控制动作无效")
        }

        if !connected {
            guard !ok && !enabled && !running && code == "computer_offline" && json["app"] == nil else {
                throw APIError.inconsistentState("离线控制响应无效")
            }
            return false
        }

        guard let appJson = json["app"] as? [String: Any] else {
            if ok || enabled || running || !["app_not_found", "state_update_failed"].contains(code) {
                throw APIError.inconsistentState("失败控制响应无效")
            }
            return false
        }

        let app = try decodeApp(config: config, json: appJson)
        guard enabled == (app.code == .ready || app.code == .starting),
              running == (app.code == .ready || app.code == .stopping),
              code == app.code.rawValue else {
            throw APIError.inconsistentState("控制状态不一致")
        }

        if json["error_code"] != nil {
            guard !ok && (json["error_code"] as? String) == "stop_command_failed" else {
                throw APIError.invalidFields("控制错误无效")
            }
        } else {
            guard ok else {
                throw APIError.invalidFields("控制结果无效")
            }
        }

        return ok
    }

    // MARK: - Helpers

    private static func validMetadata(_ value: String, max: Int, allowEmpty: Bool) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard value == trimmed else { return false }
        guard allowEmpty || !value.isEmpty else { return false }
        let count = value.unicodeScalars.count
        guard count <= max else { return false }
        return value.allSatisfy { ($0.asciiValue ?? 128) >= 32 && ($0.asciiValue ?? 0) != 127 }
    }
}
