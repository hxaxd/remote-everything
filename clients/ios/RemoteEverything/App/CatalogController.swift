import Foundation

@MainActor
final class CatalogController: ObservableObject {

    @Published private(set) var catalogs: [String: CatalogState] = [:]

    private let nodesController: NodesController
    private let clients: GatewayClientPool
    private let vault: IdentityVault
    private let pathSelector: PathSelector.Cache

    var onNotice: ((Notice) -> Void)?

    private var catalogLoop: Task<Void, Never>?
    private var controlTasks: [String: Task<Void, Never>] = [:]
    private var catalogNodeID: String?
    private var generation = 0
    private var catalogRequests: [String: Int] = [:]
    private var controlTokens: [String: UUID] = [:]

    private func current(_ identity: Identity) -> Bool {
        !Task.isCancelled && nodesController.identities.contains(identity)
    }

    init(
        nodesController: NodesController,
        clients: GatewayClientPool,
        vault: IdentityVault,
        pathSelector: PathSelector.Cache
    ) {
        self.nodesController = nodesController
        self.clients = clients
        self.vault = vault
        self.pathSelector = pathSelector
    }

    func stopLoops() {
        generation += 1
        catalogLoop?.cancel()
        catalogLoop = nil
        for task in controlTasks.values { task.cancel() }
        controlTasks.removeAll()
        controlTokens.removeAll()
    }

    func clear() {
        stopLoops()
        catalogs.removeAll()
    }

    func setCatalog(_ state: CatalogState, forNodeID nodeID: String) {
        catalogs[nodeID] = state
    }

    // MARK: - Polling & Catalog Loading

    func beginCatalogPolling(nodeID: String) {
        if catalogNodeID == nodeID, catalogLoop != nil { return }
        stopLoops()
        catalogNodeID = nodeID
        catalogLoop?.cancel()
        catalogLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.loadCatalog(nodeID: nodeID)
                do {
                    try await Task.sleep(nanoseconds: Cadence.catalogRefreshNanos)
                } catch {
                    return
                }
            }
        }
    }

    func endCatalogPolling(nodeID: String) {
        guard catalogNodeID == nodeID else { return }
        stopLoops()
        catalogNodeID = nil
    }

    func resumeLoops() {
        if let nodeID = catalogNodeID { beginCatalogPolling(nodeID: nodeID) }
    }

    func loadCatalog(nodeID: String) async {
        let generation = self.generation
        let request = (catalogRequests[nodeID] ?? 0) + 1
        catalogRequests[nodeID] = request
        guard let node = nodesController.node(withID: nodeID) else {
            catalogs[nodeID] = .offline
            return
        }
        if catalogs[nodeID] == nil { catalogs[nodeID] = .loading }

        var lastError: Error?
        for path in nodesController.orderedPaths(for: node) {
            guard let identity = nodesController.identity(forPath: path),
                  let client = clients.deviceClient(for: identity, vault: vault)
            else {
                nodesController.setCondition(origin: path.origin, condition: .needsPairing)
                continue
            }
            let started = Date()
            do {
                let response = try await client.catalog(nodeID: nodeID)
                guard current(identity), generation == self.generation, catalogRequests[nodeID] == request else { return }
                if !response.computerConnected {
                    nodesController.markUnreachable(path: path, nodeID: nodeID)
                    continue
                }
                nodesController.markReachable(path: path, nodeID: nodeID, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
                nodesController.setCondition(origin: identity.origin, condition: .ok)
                let state = CatalogController.state(for: response)
                if case .ready(let apps) = state, case .ready(let previous) = catalogs[nodeID] {
                    catalogs[nodeID] = .ready(apps.map { app in
                        controlTasks["\(nodeID)/\(app.id)"] != nil ? previous.first(where: { $0.id == app.id }) ?? app : app
                    })
                } else { catalogs[nodeID] = state }
                return
            } catch let error as ClientError {
                guard current(identity), generation == self.generation, catalogRequests[nodeID] == request else { return }
                if error.code == .unauthorized {
                    nodesController.setCondition(origin: identity.origin, condition: .unauthorized)
                    catalogs[nodeID] = .unauthorized
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    onNotice?(.busy)
                }
                if error.code == .computerOffline {
                    nodesController.markUnreachable(path: path, nodeID: nodeID)
                    continue
                }
                lastError = error
            } catch {
                guard current(identity), generation == self.generation, catalogRequests[nodeID] == request else { return }
                lastError = error
            }
            nodesController.markUnreachable(path: path, nodeID: nodeID)
            pathSelector.invalidate(nodeID: nodeID)
        }
        guard !Task.isCancelled, generation == self.generation, catalogRequests[nodeID] == request else { return }
        if let failure = lastError {
            catalogs[nodeID] = (failure is NetworkFailure) ? .unreachable : CatalogController.state(for: asClientError(failure))
        } else {
            catalogs[nodeID] = .offline
        }
    }

    // MARK: - App Control

    func startApplication(nodeID: String, appID: String) {
        control(nodeID: nodeID, appID: appID, action: .start)
    }

    func stopApplication(nodeID: String, appID: String) {
        control(nodeID: nodeID, appID: appID, action: .stop)
    }

    private enum ControlAction {
        case start
        case stop

        var pendingState: AppState { self == .start ? .starting : .stopping }
    }

    private func control(nodeID: String, appID: String, action: ControlAction) {
        let key = "\(nodeID)/\(appID)"
        guard controlTasks[key] == nil else { return }
        let token = UUID()
        controlTokens[key] = token
        updateApplication(nodeID: nodeID, appID: appID) { app in
            var updated = app
            updated.code = action.pendingState
            updated.enabled = app.enabled
            updated.running = app.running
            return updated
        }
        controlTasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.performControl(nodeID: nodeID, appID: appID, action: action)
            guard self.controlTokens[key] == token else { return }
            self.controlTasks.removeValue(forKey: key)
            self.controlTokens.removeValue(forKey: key)
            if !Task.isCancelled { await self.loadCatalog(nodeID: nodeID) }
        }
    }

    private func performControl(nodeID: String, appID: String, action: ControlAction) async {
        guard let node = nodesController.node(withID: nodeID) else { return }
        var requestError: Error?
        for path in nodesController.orderedPaths(for: node) {
            guard let identity = nodesController.identity(forPath: path),
                  let client = clients.deviceClient(for: identity, vault: vault)
            else { continue }
            var commandSent = false
            do {
                let preflight = try await client.status(nodeID: nodeID, appID: appID)
                guard current(identity) else { return }
                if preflight.code == .computerOffline {
                    nodesController.markUnreachable(path: path, nodeID: nodeID)
                    continue
                }
                if preflight.code == .appNotFound { onNotice?(.appGone); return }
                let response: ControlResponse
                commandSent = true
                switch action {
                case .start: response = try await client.start(nodeID: nodeID, appID: appID)
                case .stop: response = try await client.stop(nodeID: nodeID, appID: appID)
                }
                guard current(identity) else { return }
                if response.code == .computerOffline {
                    catalogs[nodeID] = .offline
                    return
                }
                if response.code == .appNotFound {
                    onNotice?(.appGone)
                    await loadCatalog(nodeID: nodeID)
                    return
                }
                if response.errorCode == "stop_command_failed" {
                    onNotice?(.stopFailed)
                }
                if let app = response.app {
                    applyApplication(nodeID: nodeID, info: app.appInfo)
                } else {
                    updateApplication(nodeID: nodeID, appID: appID) { app in
                        var updated = app
                        updated.enabled = response.enabled
                        updated.running = response.running
                        updated.code = response.code.appState ?? state(enabled: response.enabled, running: response.running)
                        return updated
                    }
                }
                await pollStatus(nodeID: nodeID, appID: appID, client: client, path: path, identity: identity)
                return
            } catch let error as ClientError {
                guard current(identity) else { return }
                if error.code == .appNotFound {
                    onNotice?(.appGone)
                    await loadCatalog(nodeID: nodeID)
                    return
                }
                if error.code == .unauthorized {
                    catalogs[nodeID] = .unauthorized
                    nodesController.setCondition(origin: path.origin, condition: .unauthorized)
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    onNotice?(.busy)
                }
                requestError = error
            } catch {
                guard current(identity) else { return }
                requestError = error
            }
            if commandSent {
                onNotice?(.controlFailed)
                await pollStatus(nodeID: nodeID, appID: appID, client: client, path: path, identity: identity)
                return
            }
            nodesController.markUnreachable(path: path, nodeID: nodeID)
        }
        if requestError is NetworkFailure {
            onNotice?(.network)
        } else if requestError != nil {
            onNotice?(.controlFailed)
        }
        await loadCatalog(nodeID: nodeID)
    }

    private func pollStatus(nodeID: String, appID: String, client: GatewayClient, path: Path, identity: Identity) async {
        let deadline = Date().addingTimeInterval(Cadence.controlPollTimeout)
        var interval = Cadence.controlPoll
        while !Task.isCancelled, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: Cadence.nanoseconds(seconds: min(interval, max(0, deadline.timeIntervalSinceNow))))
            } catch {
                return
            }
            do {
                guard deadline > Date(), current(identity) else { break }
                  let response = try await readStatus(nodeID:nodeID,appID:appID,deadline:deadline)
                guard current(identity) else { return }
                if response.code == .computerOffline {
                    catalogs[nodeID] = .offline
                    return
                }
                if response.code == .appNotFound {
                    onNotice?(.appGone)
                    await loadCatalog(nodeID: nodeID)
                    return
                }
                if let app = response.app {
                    applyApplication(nodeID: nodeID, info: app.appInfo)
                    if app.code.isSteady { return }
                } else {
                    updateApplication(nodeID: nodeID, appID: appID) { app in
                        var updated = app
                        updated.enabled = response.enabled
                        updated.running = response.running
                        updated.code = response.code.appState ?? state(enabled: response.enabled, running: response.running)
                        return updated
                    }
                    if response.code.appState?.isSteady == true { return }
                }
            } catch let error as ClientError {
                guard current(identity) else { return }
                if error.code == .unauthorized {
                    catalogs[nodeID] = .unauthorized
                    nodesController.setCondition(origin: path.origin, condition: .unauthorized)
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    onNotice?(.busy)
                }
            } catch {
                guard current(identity) else { return }
            }
            interval = min(interval * Cadence.controlPollFactor, Cadence.controlPollCeiling)
        }
        if current(identity) { onNotice?(.controlFailed) }
    }

    private func state(enabled: Bool, running: Bool) -> AppState {
        switch (enabled, running) {
        case (true, true): return .ready
        case (true, false): return .starting
        case (false, true): return .stopping
        case (false, false): return .stopped
        }
    }

    private func readStatus(nodeID: String, appID: String, deadline: Date) async throws -> ControlResponse {
        guard let node = nodesController.node(withID:nodeID) else { throw ClientError(.nodeNotFound) }
        var lastError: Error = ClientError(.computerOffline)
        for path in nodesController.orderedPaths(for:node) {
            guard deadline > Date(), !Task.isCancelled else { throw CancellationError() }
            guard let identity = nodesController.identity(forPath:path),
                  let client = clients.deviceClient(for:identity,vault:vault) else { continue }
            do {
                let answer = try await client.status(nodeID:nodeID,appID:appID,timeout:min(Cadence.requestTimeout,max(0.001,deadline.timeIntervalSinceNow)))
                guard current(identity) else { throw CancellationError() }
                if answer.code == .computerOffline { nodesController.markUnreachable(path:path,nodeID:nodeID); continue }
                nodesController.markReachable(path:path,nodeID:nodeID,latencyMs:path.latencyMs)
                return answer
            } catch is CancellationError { throw CancellationError() }
            catch let error as ClientError { if error.code != .computerOffline { throw error }; lastError = error }
            catch { lastError = error }
        }
        throw lastError
    }

    private func applyApplication(nodeID: String, info: AppInfo) {
        catalogRequests[nodeID, default: 0] += 1
        guard case .ready(var apps) = catalogs[nodeID] else { return }
        if let index = apps.firstIndex(where: { $0.id == info.id }) {
            apps[index] = info
            catalogs[nodeID] = .ready(apps)
        }
    }

    private func updateApplication(nodeID: String, appID: String, transform: (AppInfo) -> AppInfo) {
        catalogRequests[nodeID, default: 0] += 1
        guard case .ready(var apps) = catalogs[nodeID],
              let index = apps.firstIndex(where: { $0.id == appID })
        else { return }
        apps[index] = transform(apps[index])
        catalogs[nodeID] = .ready(apps)
    }

    private static func state(for response: CatalogResponse) -> CatalogState {
        switch CatalogOutcome.forAnswer(response) {
        case .apps(let apps): return .ready(apps)
        case .offline: return .offline
        case .unauthorized: return .unauthorized
        case .gatewayTrouble: return .refused(ClientError(.internalError))
        }
    }

    private static func state(for error: ClientError) -> CatalogState {
        switch CatalogOutcome.forRefusal(error) {
        case .offline: return .offline
        case .unauthorized: return .unauthorized
        case .apps, .gatewayTrouble: return .refused(error)
        }
    }

    private func asClientError(_ error: Error) -> ClientError {
        if let clientError = error as? ClientError { return clientError }
        return ClientError(.internalError)
    }

    // MARK: - Web Target Resolution

    func resolveWebTarget(nodeID: String, appID: String) async throws -> WebTarget {
        guard let node = nodesController.node(withID: nodeID) else { throw ClientError(.nodeNotFound) }
        let deadline = Date().addingTimeInterval(Cadence.controlPollTimeout)
        while true {
            let status = try await readStatus(nodeID:nodeID,appID:appID,deadline:deadline)
            if status.code == .ready { break }
            guard status.code == .starting, Date() < deadline else { throw ClientError(.computerOffline) }
            try await Task.sleep(nanoseconds:Cadence.nanoseconds(seconds:min(1,max(0,deadline.timeIntervalSinceNow))))
        }
        var lastError: Error?
        for path in nodesController.orderedPaths(for: node) {
            guard let identity = nodesController.identity(forPath: path),
                  let credential = vault.prepare(aliasRef: identity.credentialRef),
                  let client = clients.deviceClient(for: identity, vault: vault)
            else {
                nodesController.setCondition(origin: path.origin, condition: .needsPairing)
                lastError = ClientError(.unauthorized)
                continue
            }
            do {
                let url = try await client.open(nodeID: nodeID, appID: appID)
                guard current(identity) else { throw CancellationError() }
                nodesController.markReachable(path: path, nodeID: nodeID, latencyMs: path.latencyMs)
                var target = url
                if case .ready(let apps) = catalogs[nodeID],
                   let app = apps.first(where: { $0.id == appID }),
                   !app.launchFragment.isEmpty,
                   let withFragment = URL(string: url.absoluteString + app.launchFragment) {
                    target = withFragment
                }
                let handler = GatewayChallengeHandler(
                    gatewayOrigin: identity.origin,
                    pin: identity.serverPin,
                    credential: credential
                )
                return WebTarget(gatewayOrigin: identity.origin, url: target, handler: handler, isPrivate: path.isPrivate)
            } catch let error as ClientError {
                guard current(identity) else { throw CancellationError() }
                if error.code == .appNotFound {
                    onNotice?(.appGone)
                    await loadCatalog(nodeID: nodeID)
                    throw error
                }
                lastError = error
            } catch {
                guard current(identity) else { throw CancellationError() }
                lastError = error
            }
            pathSelector.invalidate(nodeID: nodeID)
            nodesController.markUnreachable(path: path, nodeID: nodeID)
        }
        throw lastError ?? ClientError(.computerOffline)
    }
}
