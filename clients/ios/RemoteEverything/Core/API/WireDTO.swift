import Foundation

/// Strict decoding helpers.
///
/// The rule the schemas and the Go side both state is that a body a client does
/// not understand is rejected, not tolerated: unknown field, missing field and
/// unknown enum value are all failures. Foundation's synthesised decoding
/// ignores unknown fields, so every DTO here asks for the key list and compares
/// it with the contract.
enum WireStrict {

    /// A coding key for *any* field name, so the container can report keys the
    /// DTO does not declare.
    struct AnyKey: CodingKey, Hashable {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    /// Refuses a body with any field outside `allowed`.
    static func requireOnly(_ decoder: Decoder, _ allowed: Set<String>, _ context: String) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown field \"\(key.stringValue)\" in \(context)"
                )
            )
        }
    }

    /// A string that is exactly the length the contract allows, counted in
    /// Unicode code points (the same unit Go counts runes in).
    static func codePoints(_ value: String, maximum: Int, allowEmpty: Bool) -> Bool {
        let count = value.unicodeScalars.count
        guard count <= maximum else { return false }
        guard allowEmpty || count > 0 else { return false }
        return true
    }
}

// MARK: - Nodes

/// nodes.schema.json — `GET /__remote_everything/nodes`.
struct NodesResponse: Codable, Equatable {
    struct Node: Codable, Equatable {
        let id: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case id
            case name
        }
    }

    let ok: Bool
    let nodes: [Node]

    enum CodingKeys: String, CodingKey {
        case ok
        case nodes
    }
}

extension NodesResponse {
    init(from decoder: Decoder) throws {
        try WireStrict.requireOnly(decoder, ["ok", "nodes"], "nodes response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard ok else { throw DTORejection.notTrue("ok", "nodes response") }
        let nodes = try container.decode([Node].self, forKey: .nodes)
        for node in nodes {
            guard SetupURI.isHex64(node.id) else { throw DTORejection.badField("nodes[].id", "nodes response") }
            guard !node.name.isEmpty else { throw DTORejection.badField("nodes[].name", "nodes response") }
        }
        self.ok = ok
        self.nodes = nodes
    }
}

extension NodesResponse.Node {
    init(from decoder: Decoder) throws {
        try WireStrict.requireOnly(decoder, ["id", "name"], "node")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
    }
}

// MARK: - Catalog

/// catalog.schema.json — the answer `GET /__remote_everything/apps` and a
/// successful activation both give.
struct CatalogResponse: Codable, Equatable {
    enum Code: String, Codable {
        case ready
        case computerOffline = "computer_offline"
    }

    let ok: Bool
    let computerConnected: Bool
    let code: Code
    let apps: [AppDto]

    var applicationInfos: [AppInfo] {
        apps.map { $0.appInfo }
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case computerConnected = "computer_connected"
        case code
        case apps
    }
}

extension CatalogResponse {
    init(from decoder: Decoder) throws {
        try WireStrict.requireOnly(decoder, ["ok", "computer_connected", "code", "apps"], "catalog response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard ok else { throw DTORejection.notTrue("ok", "catalog response") }
        let connected = try container.decode(Bool.self, forKey: .computerConnected)
        let code = try container.decode(Code.self, forKey: .code)
        let apps = try container.decode([AppDto].self, forKey: .apps)
        // The two fields say the same thing twice; a body where they disagree is
        // a body this client does not understand.
        switch (connected, code) {
        case (true, .ready), (false, .computerOffline):
            break
        default:
            throw DTORejection.badField("code", "catalog response")
        }
        if !connected && !apps.isEmpty {
            throw DTORejection.badField("apps", "catalog response")
        }
        var seen = Set<String>()
        for app in apps where !seen.insert(app.id).inserted {
            throw DTORejection.badField("apps[].id", "catalog response")
        }
        self.ok = ok
        self.computerConnected = connected
        self.code = code
        self.apps = apps
    }
}

/// One application, as catalog.schema.json's `apps[]` describes it.
struct AppDto: Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let accent: String
    let launchFragment: String
    let computerConnected: Bool
    let enabled: Bool
    let running: Bool
    let code: AppState

    var appInfo: AppInfo {
        AppInfo(
            id: id,
            name: name,
            description: description,
            icon: icon,
            accent: accent,
            launchFragment: launchFragment,
            enabled: enabled,
            running: running,
            code: code
        )
    }
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case icon
        case accent
        case launchFragment = "launch_fragment"
        case computerConnected = "computer_connected"
        case enabled
        case running
        case code
    }
}

extension AppDto {
    init(from decoder: Decoder) throws {
        let allowed: Set<String> = [
            "id", "name", "description", "icon", "accent", "launch_fragment",
            "computer_connected", "enabled", "running", "code",
        ]
        try WireStrict.requireOnly(decoder, allowed, "catalog app")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let description = try container.decode(String.self, forKey: .description)
        let icon = try container.decode(String.self, forKey: .icon)
        let accent = try container.decode(String.self, forKey: .accent)
        let launchFragment = try container.decode(String.self, forKey: .launchFragment)
        let connected = try container.decode(Bool.self, forKey: .computerConnected)
        let enabled = try container.decode(Bool.self, forKey: .enabled)
        let running = try container.decode(Bool.self, forKey: .running)
        let code = try container.decode(AppState.self, forKey: .code)

        guard isApplicationID(id) else { throw DTORejection.badField("id", "catalog app") }
        guard WireStrict.codePoints(name, maximum: 80, allowEmpty: false),
              hasNoControlCharacters(name)
        else { throw DTORejection.badField("name", "catalog app") }
        guard WireStrict.codePoints(description, maximum: 240, allowEmpty: true),
              hasNoControlCharacters(description)
        else { throw DTORejection.badField("description", "catalog app") }
        guard WireStrict.codePoints(icon, maximum: 4, allowEmpty: true),
              hasNoControlCharacters(icon)
        else { throw DTORejection.badField("icon", "catalog app") }
        guard isAccentColor(accent) else { throw DTORejection.badField("accent", "catalog app") }
        guard launchFragment.isEmpty
            || (launchFragment.hasPrefix("#") && WireStrict.codePoints(launchFragment, maximum: 2048, allowEmpty: false))
        else { throw DTORejection.badField("launch_fragment", "catalog app") }
        guard connected else { throw DTORejection.badField("computer_connected", "catalog app") }
        // enabled + running and code have to agree; the schema says how.
        let expected: AppState
        switch (enabled, running) {
        case (true, true): expected = .ready
        case (true, false): expected = .starting
        case (false, true): expected = .stopping
        case (false, false): expected = .stopped
        }
        guard code == expected else { throw DTORejection.badField("code", "catalog app") }

        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.accent = accent
        self.launchFragment = launchFragment
        self.computerConnected = connected
        self.enabled = enabled
        self.running = running
        self.code = code
    }
}

// MARK: - Control

/// control.schema.json — status, start and stop.
struct ControlResponse: Codable, Equatable {
    enum Action: String, Codable {
        case status
        case start
        case stop
    }

    enum Code: String, Codable {
        case ready
        case starting
        case stopping
        case stopped
        case computerOffline = "computer_offline"
        case appNotFound = "app_not_found"
        case stateUpdateFailed = "state_update_failed"

        /// The state a state code names; the other codes say nothing about flags.
        var appState: AppState? {
            switch self {
            case .ready: return .ready
            case .starting: return .starting
            case .stopping: return .stopping
            case .stopped: return .stopped
            case .computerOffline, .appNotFound, .stateUpdateFailed: return nil
            }
        }
    }

    let ok: Bool
    let action: Action
    let computerConnected: Bool
    let enabled: Bool
    let running: Bool
    let code: Code
    let app: AppDto?
    let errorCode: String?
    enum CodingKeys: String, CodingKey {
        case ok
        case action
        case computerConnected = "computer_connected"
        case enabled
        case running
        case code
        case app
        case errorCode = "error_code"
    }
}

extension ControlResponse {
    init(from decoder: Decoder) throws {
        let allowed: Set<String> = [
            "ok", "action", "computer_connected", "enabled", "running", "code", "app", "error_code",
        ]
        try WireStrict.requireOnly(decoder, allowed, "control response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decode(Bool.self, forKey: .ok)
        self.action = try container.decode(Action.self, forKey: .action)
        self.computerConnected = try container.decode(Bool.self, forKey: .computerConnected)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.running = try container.decode(Bool.self, forKey: .running)
        self.code = try container.decode(Code.self, forKey: .code)
        self.app = try container.decodeIfPresent(AppDto.self, forKey: .app)
        let errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        if let errorCode, errorCode != "stop_command_failed" {
            throw DTORejection.badField("error_code", "control response")
        }
        self.errorCode = errorCode
        // A state code says what its flags do, exactly as on an apps[] entry; the
        // other control codes (offline, missing, failed) say nothing about them.
        let expected: AppState?
        switch (self.enabled, self.running) {
        case (true, true): expected = .ready
        case (true, false): expected = .starting
        case (false, true): expected = .stopping
        case (false, false): expected = .stopped
        }
        switch self.code {
        case .ready, .starting, .stopping, .stopped:
            guard expected == self.code.appState else { throw DTORejection.badField("code", "control response") }
        case .computerOffline, .appNotFound, .stateUpdateFailed:
            break
        }
    }
}

// MARK: - Pairing

/// The body `POST /__remote_everything_pair` carries. Strict in both directions:
/// the Go side refuses a body it cannot read, and a client that wrote one it
/// cannot read is a client this protocol does not have.
struct PairingRequest: Codable, Equatable {
    let deviceName: String
    let credentialPassword: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case credentialPassword = "credential_password"
    }
}

/// pairing.schema.json — the answer to redeeming an invitation.
struct PairingResponse: Codable, Equatable {
    let ok: Bool
    let deviceName: String
    let certificateFingerprint: String
    let credentialFormat: String
    let credentialPKCS12: String
    let pendingExpiresAt: String?

    var pendingExpiry: Date? { pendingExpiresAt.flatMap(WireDate.parse) }

    enum CodingKeys: String, CodingKey {
        case ok
        case deviceName = "device_name"
        case certificateFingerprint = "certificate_fingerprint"
        case credentialFormat = "credential_format"
        case credentialPKCS12 = "credential_pkcs12"
        case pendingExpiresAt = "pending_expires_at"
    }
}

extension PairingResponse {
    init(from decoder: Decoder) throws {
        let allowed: Set<String> = [
            "ok", "device_name", "certificate_fingerprint", "credential_format",
            "credential_pkcs12", "pending_expires_at",
        ]
        try WireStrict.requireOnly(decoder, allowed, "pairing response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard ok else { throw DTORejection.notTrue("ok", "pairing response") }
        let deviceName = try container.decode(String.self, forKey: .deviceName)
        guard !deviceName.isEmpty else { throw DTORejection.badField("device_name", "pairing response") }
        let fingerprint = try container.decode(String.self, forKey: .certificateFingerprint)
        guard SetupURI.isHex64(fingerprint) else {
            throw DTORejection.badField("certificate_fingerprint", "pairing response")
        }
        let format = try container.decode(String.self, forKey: .credentialFormat)
        guard format == "pkcs12" else { throw DTORejection.badField("credential_format", "pairing response") }
        let pkcs12 = try container.decode(String.self, forKey: .credentialPKCS12)
        guard !pkcs12.isEmpty, Data(base64Encoded: pkcs12) != nil else {
            throw DTORejection.badField("credential_pkcs12", "pairing response")
        }
        let expiresAt = try container.decodeIfPresent(String.self, forKey: .pendingExpiresAt)
        if let expiresAt, WireDate.parse(expiresAt) == nil {
            throw DTORejection.badField("pending_expires_at", "pairing response")
        }
        self.ok = ok
        self.deviceName = deviceName
        self.certificateFingerprint = fingerprint
        self.credentialFormat = format
        self.credentialPKCS12 = pkcs12
        self.pendingExpiresAt = expiresAt
    }
}

// MARK: - Errors

/// errors.schema.json — the body of every refusal.
struct ErrorResponse: Codable, Equatable {
    let ok: Bool
    let code: ErrorCode

    enum CodingKeys: String, CodingKey {
        case ok
        case code
    }
}

extension ErrorResponse {
    init(from decoder: Decoder) throws {
        try WireStrict.requireOnly(decoder, ["ok", "code"], "error response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard !ok else { throw DTORejection.notTrue("ok", "error response") }
        let code = try container.decode(ErrorCode.self, forKey: .code)
        self.ok = ok
        self.code = code
    }
}

// MARK: - Release manifest

/// clients/release.json — read from the published release, never from a gateway,
/// so a device that has never paired can still check for updates.
struct ReleaseManifest: Codable, Equatable {
    struct MinimumPlatforms: Codable, Equatable {
        let androidSdk: Int
        let ios: String
        let harmonyApi: String
    
        enum CodingKeys: String, CodingKey {
            case androidSdk
            case ios
            case harmonyApi
        }
}

    let schema: Int
    let versionName: String
    let buildNumber: Int
    let protocolVersion: Int
    let minimumPlatforms: MinimumPlatforms

    enum CodingKeys: String, CodingKey {
        case schema
        case versionName
        case buildNumber
        case protocolVersion
        case minimumPlatforms
    }
}

extension ReleaseManifest.MinimumPlatforms {
    init(from decoder: Decoder) throws {
        try WireStrict.requireOnly(decoder, ["androidSdk", "ios", "harmonyApi"], "minimum platform")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.androidSdk = try container.decode(Int.self, forKey: .androidSdk)
        self.ios = try container.decode(String.self, forKey: .ios)
        self.harmonyApi = try container.decode(String.self, forKey: .harmonyApi)
    }
}

extension ReleaseManifest {
    init(from decoder: Decoder) throws {
        let allowed: Set<String> = ["schema", "versionName", "buildNumber", "protocolVersion", "minimumPlatforms"]
        try WireStrict.requireOnly(decoder, allowed, "release manifest")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == 1 else { throw DTORejection.badField("schema", "release manifest") }
        let versionName = try container.decode(String.self, forKey: .versionName)
        guard isVersionName(versionName) else { throw DTORejection.badField("versionName", "release manifest") }
        let buildNumber = try container.decode(Int.self, forKey: .buildNumber)
        guard buildNumber >= 1 else { throw DTORejection.badField("buildNumber", "release manifest") }
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion >= 1 else { throw DTORejection.badField("protocolVersion", "release manifest") }
        self.schema = schema
        self.versionName = versionName
        self.buildNumber = buildNumber
        self.protocolVersion = protocolVersion
        self.minimumPlatforms = try container.decode(MinimumPlatforms.self, forKey: .minimumPlatforms)
    }
}

// MARK: - Shared checks

enum DTORejection: Error, Equatable {
    case notTrue(String, String)
    case badField(String, String)
}

/// `^[a-z0-9][a-z0-9._-]{0,63}$`
func isApplicationID(_ value: String) -> Bool {
    guard let first = value.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
    guard value.count <= 64 else { return false }
    return value.allSatisfy { character in
        character.isASCII && (character.isLowercase || character.isNumber || "._-".contains(character))
    }
}

/// `^#[0-9A-Fa-f]{6}$`
func isAccentColor(_ value: String) -> Bool {
    guard value.count == 7, value.hasPrefix("#") else { return false }
    return value.dropFirst().allSatisfy { character in
        (character >= "0" && character <= "9")
            || (character >= "a" && character <= "f")
            || (character >= "A" && character <= "F")
    }
}

/// `^\d+\.\d+\.\d+$`
func isVersionName(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(\.isNumber) }
}

func hasNoControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}

/// Timestamps on the wire are RFC 3339 in UTC with second precision.
enum WireDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

// MARK: - App state

extension AppState {
    /// The state one application row shows, spelled as the catalog spells it.
    var isSteady: Bool {
        self == .ready || self == .stopped
    }
}
