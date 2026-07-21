import Foundation
import Observation
import Security

/// Catalog UI state. Mirrors Android's `CatalogUiState`.
enum CatalogUiState {
    case loading
    case ready(CatalogSnapshot)
    case error(String)
}

/// Manages catalog polling, refresh, app control, and profile switching.
/// Mirrors Android's `SessionViewModel` catalog and profile logic.
@Observable
final class CatalogViewModel {
    private(set) var catalogState: CatalogUiState = .loading
    private(set) var isRefreshing = false
    private(set) var profiles: [ConnectionConfig] = []
    private(set) var activeProfile: ConnectionConfig?

    let profileStore: ProfileStore
    let identityStore: AppIdentityStore

    private var pollTask: Task<Void, Never>?
    private var catalogOfflineSince: TimeInterval = 0
    private var lastErrorNotifyAt: TimeInterval = 0

    private static let pollInterval: UInt64 = 5_000_000_000       // 5 seconds
    private static let offlineGraceNanos: UInt64 = 30_000_000_000 // 30 seconds
    private static let refreshTimeout: UInt64 = 15_000_000_000    // 15 seconds
    private static let errorSuppressInterval: TimeInterval = 30   // 30 seconds

    init(
        profileStore: ProfileStore = ProfileStore(),
        identityStore: AppIdentityStore = AppIdentityStore()
    ) {
        self.profileStore = profileStore
        self.identityStore = identityStore
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        stopPolling()
        do {
            try profileStore.load()
        } catch {
            // Profiles failed to load — start fresh
        }
        profiles = profileStore.profiles

        // Check for pending activation recovery
        if let staged = profileStore.stagedProfile(),
           staged.mode == .public,
           (try? identityStore.hasStagedCredential(installationId: staged.installationId)) == true {
            // Pending activation — handled by AppRoot
            activeProfile = nil
            return
        }

        // Find active profile
        let selected = profileStore.activeInstallationId()
            .flatMap { selectedId in profiles.first { $0.installationId == selectedId } }
            ?? profiles.first
        if let first = selected {
            // Verify credential exists for public profiles
            if first.mode == .public && !KeychainStore.hasCredential(installationId: first.installationId) {
                try? profileStore.remove(installationId: first.installationId)
                profiles = profileStore.profiles
                activeProfile = nil
                return
            }
            activeProfile = first
            profileStore.setActiveInstallationId(first.installationId)
            startPolling()
        }
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        catalogOfflineSince = 0
        catalogState = .loading

        guard let config = activeProfile else { return }

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let snapshot = try await self.fetchCatalog(config: config)
                    await MainActor.run { self.publishCatalog(snapshot) }
                } catch is DeviceAuthorizationException {
                    await MainActor.run { self.handleAuthorizationRevoked(config: config) }
                    return
                } catch {
                    await MainActor.run { self.handlePollError(error) }
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        catalogOfflineSince = 0
    }

    // MARK: - Refresh

    func refreshCatalog() async {
        guard let config = activeProfile, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = try await withTimeout(seconds: 15) {
                try await self.fetchCatalog(config: config)
            }
            guard activeProfile?.installationId == config.installationId else { return }
            await MainActor.run { publishCatalog(snapshot) }
        } catch is DeviceAuthorizationException {
            await MainActor.run { handleAuthorizationRevoked(config: config) }
        } catch {
            if case .ready = catalogState {
                notifyTransientError()
            }
        }
    }

    // MARK: - Control

    func controlApp(appId: String, action: String) async {
        guard let config = activeProfile else { return }
        do {
            let identity = clientIdentity(for: config)
            let body = try await SecureHTTP.request(
                config: config,
                url: config.appActionUrl(id: appId, action: action),
                method: "POST",
                identity: identity,
                headers: [:],
                body: nil
            )
            if body.status != 200 { throw RemoteAPI.APIError.httpStatus(body.status) }
            _ = try RemoteAPI.decodeAction(
                config: config,
                expectedAction: action,
                json: try body.json()
            )
        } catch {
            // Error handled by UI
        }
        await refreshCatalog()
    }

    // MARK: - Profiles

    func selectProfile(_ config: ConnectionConfig) {
        activeProfile = config
        profileStore.setActiveInstallationId(config.installationId)
        startPolling()
    }

    func addProfile(_ config: ConnectionConfig) throws {
        try profileStore.add(config)
        profiles = profileStore.profiles
    }

    func activateAfterSetup(_ config: ConnectionConfig) {
        profiles = profileStore.profiles
        activeProfile = config
        profileStore.setActiveInstallationId(config.installationId)
        startPolling()
    }

    func deleteProfile(_ config: ConnectionConfig) throws {
        try KeychainStore.deleteAll(for: config.installationId)
        try profileStore.remove(installationId: config.installationId)
        profiles = profileStore.profiles
        if activeProfile?.installationId == config.installationId {
            stopPolling()
            activeProfile = nil
            profileStore.setActiveInstallationId(nil)
        }
    }

    // MARK: - Private

    private func fetchCatalog(config: ConnectionConfig) async throws -> CatalogSnapshot {
        let identity = clientIdentity(for: config)
        let result = try await SecureHTTP.request(
            config: config,
            url: config.appsUrl,
            method: "GET",
            identity: identity,
            headers: ["Accept": "application/json"],
            body: nil
        )
        if result.status == 401 || result.status == 403 {
            throw DeviceAuthorizationException()
        }
        guard result.status == 200 else {
            throw RemoteAPI.APIError.httpStatus(result.status)
        }
        return try RemoteAPI.decodeCatalog(config: config, json: try result.json())
    }

    private func clientIdentity(for config: ConnectionConfig) -> ClientIdentity? {
        guard config.mode == .public else { return nil }
        guard let identity = try? KeychainStore.loadIdentity(
            installationId: config.installationId, state: .active
        ) else { return nil }
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        return ClientIdentity(
            identity: identity,
            certificateChain: certificate.map { [$0] } ?? []
        )
    }

    private func publishCatalog(_ snapshot: CatalogSnapshot) {
        if snapshot.computerConnected {
            catalogOfflineSince = 0
            catalogState = .ready(snapshot)
            return
        }

        // 30-second offline grace for transient blips
        if case .ready(let current) = catalogState, current.computerConnected {
            let now = ProcessInfo.processInfo.systemUptime
            if catalogOfflineSince == 0 { catalogOfflineSince = now }
            if now - catalogOfflineSince < 30 {
                notifyTransientError()
                return
            }
        }

        catalogState = .ready(snapshot)
    }

    private func handlePollError(_ error: Error) {
        if case .ready = catalogState {
            notifyTransientError()
        } else {
            let message = (error as NSError).localizedDescription
            catalogState = .error(message)
        }
    }

    private func notifyTransientError() {
        let now = Date().timeIntervalSince1970
        if now - lastErrorNotifyAt < Self.errorSuppressInterval { return }
        lastErrorNotifyAt = now
        // Error message will be shown via the UI binding
    }

    private func handleAuthorizationRevoked(config: ConnectionConfig) {
        try? KeychainStore.deleteAll(for: config.installationId)
        try? profileStore.remove(installationId: config.installationId)
        profiles = profileStore.profiles
        if activeProfile?.installationId == config.installationId {
            stopPolling()
            activeProfile = nil
        }
    }
}

/// Thrown when the device certificate is no longer valid.
struct DeviceAuthorizationException: Error {}

/// Run an async operation with a timeout.
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
