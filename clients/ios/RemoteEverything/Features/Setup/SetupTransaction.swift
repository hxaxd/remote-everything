import Foundation

// MARK: - Protocols

/// Profile staging for transactional setup flows.
/// Mirrors Android's `SetupProfileStore`.
protocol SetupProfileStore {
    func stagedProfile() -> ConnectionConfig?
    func stageProfile(_ value: ConnectionConfig) throws
    func commitStagedProfile() throws -> ConnectionConfig
    func discardStagedProfile()
}

/// Identity staging for transactional credential management.
/// Mirrors Android's `SetupIdentityStore`.
protocol SetupIdentityStore {
    func credentialPassword(installationId: String) throws -> String
    func stageCredential(installationId: String, encoded: String, password: String, expectedFingerprint: String) throws
    func stagedClientIdentity(installationId: String) throws -> ClientIdentity?
    func promoteCredential(installationId: String) throws
    func hasStagedCredential(installationId: String) throws -> Bool
    func discardStagedCredential(installationId: String) throws
}

/// Network transport for setup operations.
/// Mirrors Android's `SetupTransport`.
protocol SetupTransport {
    func verifyCatalog(config: ConnectionConfig) async throws
    func request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity?,
        headers: [String: String],
        body: String?
    ) async throws -> HTTPResult
}

// MARK: - State & Action

/// Setup state machine actions.
/// Mirrors Android's `SetupAction`.
enum SetupAction {
    case retryPairing
    case retryActivation
    case restartSetup
}

/// Setup state machine states.
/// Mirrors Android's `SetupState` sealed interface.
enum SetupState {
    case pairing(ConnectionConfig)
    case activating(ConnectionConfig, pendingExpiresAt: String?)
    case awaitingApproval(ConnectionConfig, pendingExpiresAt: String?)
    case ready(ConnectionConfig)
    case failed(ConnectionConfig, message: String, action: SetupAction)

    var config: ConnectionConfig {
        switch self {
        case .pairing(let c): return c
        case .activating(let c, _): return c
        case .awaitingApproval(let c, _): return c
        case .ready(let c): return c
        case .failed(let c, _, _): return c
        }
    }
}

// MARK: - Production Transport

/// Real network transport backed by RemoteAPI + SecureHTTP.
/// Mirrors Android's `ProductionSetupTransport`.
struct ProductionSetupTransport: SetupTransport {
    func verifyCatalog(config: ConnectionConfig) async throws {
        let response = try await SecureHTTP.request(
            config: config,
            url: config.appsUrl,
            method: "GET",
            identity: nil
        )
        guard response.status == 200 else {
            throw RemoteAPI.APIError.httpStatus(response.status)
        }
        _ = try RemoteAPI.decodeCatalog(config: config, json: try response.json())
    }

    func request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity?,
        headers: [String: String],
        body: String?
    ) async throws -> HTTPResult {
        try await SecureHTTP.request(
            config: config,
            url: url,
            method: method,
            identity: identity,
            headers: headers,
            body: body
        )
    }
}

// MARK: - Helpers

/// Truncate a string to at most `maximum` Unicode code points.
private func codePointPrefix(_ value: String, maximum: Int) -> String {
    let scalars = value.unicodeScalars
    if scalars.count <= maximum { return value }
    return String(scalars.prefix(maximum))
}

/// Extract the root cause message from an error chain.
private func failureDetail(_ error: Error, fallback: String) -> String {
    let message = String(describing: error)
    return message.isEmpty ? fallback : message
}

// MARK: - Transaction

/// Setup transaction state machine.
/// Mirrors Android's `SetupTransaction`.
final class SetupTransaction {
    private let settings: any SetupProfileStore
    private let identity: any SetupIdentityStore
    private let deviceName: String
    private let transport: any SetupTransport

    init(
        settings: any SetupProfileStore,
        identity: any SetupIdentityStore,
        deviceName: String,
        transport: any SetupTransport = ProductionSetupTransport()
    ) {
        self.settings = settings
        self.identity = identity
        self.deviceName = deviceName
        self.transport = transport
    }

    /// Recover a partially-completed public setup that has a staged credential.
    /// Returns the config if recoverable, nil otherwise.
    /// Mirrors Android's `recover()`.
    func recover() -> ConnectionConfig? {
        guard let staged = settings.stagedProfile() else { return nil }

        if staged.mode == .public && (try? identity.hasStagedCredential(installationId: staged.installationId)) == true {
            return staged
        }

        try? identity.discardStagedCredential(installationId: staged.installationId)
        settings.discardStagedProfile()
        return nil
    }

    /// Begin a setup flow from a parsed setup URI.
    /// Mirrors Android's `begin()`.
    func begin(_ setup: SetupPayload) async -> SetupState {
        discardPending()

        if setup.profile.mode == .lan {
            return await connectLAN(config: setup.profile)
        } else {
            return await pair(setup)
        }
    }

    /// Retry pairing after a previous failure. Only meaningful for public mode.
    /// Mirrors Android's `retryPairing()`.
    func retryPairing(_ setup: SetupPayload) async -> SetupState {
        return await pair(setup)
    }

    /// Retry activation with an existing staged credential. Does not re-pair.
    /// Mirrors Android's `retryActivation()`.
    func retryActivation(config: ConnectionConfig) async -> SetupState {
        return await activate(config: config, pendingExpiresAt: nil)
    }

    /// Discard any pending transaction state.
    /// Mirrors Android's `discardPending()`.
    func discardPending() {
        guard let staged = settings.stagedProfile() else { return }
        try? identity.discardStagedCredential(installationId: staged.installationId)
        settings.discardStagedProfile()
    }

    func cancel() {
        discardPending()
    }

    // MARK: - Private Steps

    /// LAN connection: verify catalog → commit profile → ready.
    /// Mirrors Android's `connectLan()`.
    private func connectLAN(config: ConnectionConfig) async -> SetupState {
        do {
            try await transport.verifyCatalog(config: config)
            try settings.stageProfile(config)
            let committed = try settings.commitStagedProfile()
            settings.discardStagedProfile()
            return .ready(committed)
        } catch {
            discardPending()
            return .failed(config, message: failureDetail(error, fallback: "局域网连接验证失败"), action: .restartSetup)
        }
    }

    /// Public pairing: POST pair → stage credential → advance to activate.
    /// Mirrors Android's `pair()`.
    private func pair(_ setup: SetupPayload) async -> SetupState {
        let config = setup.profile
        do {
            try settings.stageProfile(config)
        } catch {
            return .failed(config, message: failureDetail(error, fallback: "无法暂存连接"), action: .restartSetup)
        }

        // Generate or retrieve credential password
        let password: String
        do {
            password = try identity.credentialPassword(installationId: config.installationId)
        } catch {
            discardPending()
            return .failed(config, message: failureDetail(error, fallback: "无法创建设备身份"), action: .restartSetup)
        }

        // Build pair request body
        let body: String
        do {
            let payload: [String: String] = [
                "device_name": codePointPrefix(deviceName, maximum: 80),
                "credential_password": password,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            body = String(data: jsonData, encoding: .utf8) ?? ""
        } catch {
            discardPending()
            return .failed(config, message: failureDetail(error, fallback: "无法构造配对请求"), action: .restartSetup)
        }

        // POST pair
        let response: HTTPResult
        do {
            response = try await transport.request(
                config: config,
                url: config.pairUrl,
                method: "POST",
                identity: nil,
                headers: ["Authorization": "Invitation \(setup.invitation)"],
                body: body
            )
        } catch {
            return .failed(config, message: failureDetail(error, fallback: "无法连接配对服务"), action: .retryPairing)
        }

        if response.status == 401 {
            discardPending()
            return .failed(config, message: "邀请不可用、已过期或已被使用", action: .restartSetup)
        }

        guard response.status == 200 else {
            return .failed(config, message: "配对服务返回 \(response.status)", action: .retryPairing)
        }

        // Decode pairing credential
        let credential: PairingCredential
        do {
            let json = try response.json()
            credential = try RemoteAPI.decodePairingCredential(json: json)
        } catch {
            return .failed(config, message: failureDetail(error, fallback: "配对响应无效"), action: .retryPairing)
        }

        // Stage the credential
        do {
            try identity.stageCredential(
                installationId: config.installationId,
                encoded: credential.encoded,
                password: password,
                expectedFingerprint: credential.fingerprint
            )
        } catch {
            discardPending()
            return .failed(config, message: failureDetail(error, fallback: "设备身份保存失败"), action: .restartSetup)
        }

        return await activate(config: config, pendingExpiresAt: credential.pendingExpiresAt)
    }

    /// Activate: POST activate with mTLS → commit credential and profile → ready.
    /// Mirrors Android's `activate()`.
    private func activate(config: ConnectionConfig, pendingExpiresAt: String?) async -> SetupState {
        // Load staged client identity
        let clientIdentity: ClientIdentity?
        do {
            clientIdentity = try identity.stagedClientIdentity(installationId: config.installationId)
        } catch {
            discardPending()
            return .failed(config, message: "待激活设备身份已丢失", action: .restartSetup)
        }

        // POST activate
        let response: HTTPResult
        do {
            response = try await transport.request(
                config: config,
                url: config.activateUrl,
                method: "POST",
                identity: clientIdentity,
                headers: [:],
                body: nil
            )
        } catch {
            return .failed(config, message: failureDetail(error, fallback: "无法连接激活服务"), action: .retryActivation)
        }

        if response.status == 401 {
            discardPending()
            return .failed(config, message: "待激活设备身份已被服务器拒绝", action: .restartSetup)
        }

        if response.status == 202 {
            let json = try? response.json()
            let code = json?["code"] as? String
            if code == "approval_pending" {
                return .awaitingApproval(config, pendingExpiresAt: pendingExpiresAt)
            }
            return .failed(config, message: "审批响应无效", action: .retryActivation)
        }

        if response.status == 503 {
            return .failed(config, message: "节点暂时不可用，设备身份已保留", action: .retryActivation)
        }

        guard response.status == 200 else {
            return .failed(config, message: "激活服务返回 \(response.status)", action: .retryActivation)
        }

        // Decode catalog from activation response
        let catalog: CatalogSnapshot
        do {
            catalog = try RemoteAPI.decodeCatalog(config: config, json: try response.json())
        } catch {
            return .failed(config, message: failureDetail(error, fallback: "激活响应无效"), action: .retryActivation)
        }

        guard catalog.computerConnected else {
            return .failed(config, message: "节点暂时不可用，设备身份已保留", action: .retryActivation)
        }

        // Commit: promote credential + commit profile
        let committed: ConnectionConfig
        do {
            try identity.promoteCredential(installationId: config.installationId)
            committed = try settings.commitStagedProfile()
        } catch {
            return .failed(config, message: failureDetail(error, fallback: "连接保存失败"), action: .retryActivation)
        }

        // Clean up staging artifacts
        try? identity.discardStagedCredential(installationId: config.installationId)
        settings.discardStagedProfile()

        return .ready(committed)
    }
}
