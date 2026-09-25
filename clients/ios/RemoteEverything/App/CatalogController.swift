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
        catalogLoop?.cancel()
        catalogLoop = nil
        for task in controlTasks.values { task.cancel() }
        controlTasks.removeAll()
    }

    func clear() {
        catalogs.removeAll()
    }

    func setCatalog(_ state: CatalogState, forNodeID nodeID: String) {
        catalogs[nodeID] = state
    }

    // MARK: - Polling & Catalog Loading

    func beginCatalogPolling(nodeID: String) {
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

    func endCatalogPolling() {
        catalogLoop?.cancel()
        catalogLoop = nil
        catalogNodeID = nil
    }

    /// Asks the node being watched again, now: the phone's network changed, so
    /// the road in use is a question rather than an answer (Android recheckNow).
    func recheckNow() {
        guard let nodeID = catalogNodeID else { return }
        Task { await loadCatalog(nodeID: nodeID) }
    }

    func loadCatalog(nodeID: String) async {
        guard let node = nodesController.node(withID: nodeID) else {
            catalogs[nodeID] = .offline
            return
        }
        if catalogs[nodeID] == nil { catalogs[nodeID] = .loading }

        // The chosen path goes first, then the other roads that answered; a
        // gateway that says this device may not reach the node says so once,
        // and the next road does not get asked the same question twice.
        var lastState: CatalogState = .offline
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
                nodesController.markReachable(path: path, nodeID: nodeID, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
                nodesController.setCondition(origin: identity.origin, condition: .ok)
                catalogs[nodeID] = CatalogController.state(for: response)
                return
            } catch let error as ClientError {
                let state = CatalogController.state(for: error)
                // A refusal that is not "the machine is off" is the gateway
                // talking: asking it again by another road would say the same.
                if state != .offline {
                    if case .unauthorized = state {
                        nodesController.setCondition(origin: identity.origin, condition: .unauthorized)
                    }
                    catalogs[nodeID] = state
                    return
                }
                lastState = state
            } catch {
                // Could not be reached at all — the network, not the node: read
                // as an offline machine, the way the other two clients do.
                lastState = .offline
            }
            nodesController.markUnreachable(path: path, nodeID: nodeID)
            pathSelector.invalidate(nodeID: nodeID)
        }
        catalogs[nodeID] = lastState
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
        controlTasks[key]?.cancel()
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
        }
    }

    private func performControl(nodeID: String, appID: String, action: ControlAction) async {
        guard let node = nodesController.node(withID: nodeID) else { return }
        // A start or a stop goes down the one road the phone would take; asking
        // again by another road is what the catalog refresh does next.
        guard let path = nodesController.preferredPath(for: node),
              let identity = nodesController.identity(forPath: path),
              let client = clients.deviceClient(for: identity, vault: vault)
        else {
            await loadCatalog(nodeID: nodeID)
            return
        }
        do {
            let response: ControlResponse
            switch action {
            case .start: response = try await client.start(nodeID: nodeID, appID: appID)
            case .stop: response = try await client.stop(nodeID: nodeID, appID: appID)
            }
            if response.code == .computerOffline {
                catalogs[nodeID] = .offline
                return
            }
            if response.code == .appNotFound {
                onNotice?(.appGone)
                await loadCatalog(nodeID: nodeID)
                return
            }
            // The gateway says the state would not change — a stop that cannot
            // stop, a start that cannot start — the same two spellings the wire
            // has for it, caught the way Android catches the first.
            if response.code == .stateUpdateFailed || response.errorCode == "stop_command_failed" {
                onNotice?(.stopFailed)
            }
            if let app = response.app {
                applyApplication(nodeID: nodeID, info: app.appInfo)
            } else {
                updateApplication(nodeID: nodeID, appID: appID) { app in
                    var updated = app
                    updated.enabled = response.enabled
                    updated.running = response.running
                    updated.code = state(enabled: response.enabled, running: response.running)
                    return updated
                }
            }
            await pollStatus(nodeID: nodeID, appID: appID, client: client, path: path)
            return
        } catch {
            // A start or a stop that did not go through is one sentence, whatever
            // the road it failed on: the catalog is read again, which is what
            // says whether the node went offline or the device was refused.
            onNotice?(.controlFailed)
        }
        await loadCatalog(nodeID: nodeID)
    }

    private func pollStatus(nodeID: String, appID: String, client: GatewayClient, path: Path) async {
        let deadline = Date().addingTimeInterval(Cadence.controlPollTimeout)
        var interval = Cadence.controlPoll
        while !Task.isCancelled, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: Cadence.nanoseconds(seconds: interval))
            } catch {
                return
            }
            do {
                let response = try await client.status(nodeID: nodeID, appID: appID)
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
                        updated.code = state(enabled: response.enabled, running: response.running)
                        return updated
                    }
                    if state(enabled: response.enabled, running: response.running).isSteady { return }
                }
            } catch let error as ClientError {
                if error.code == .unauthorized {
                    catalogs[nodeID] = .unauthorized
                    nodesController.setCondition(origin: path.origin, condition: .unauthorized)
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    onNotice?(.busy)
                }
            } catch {
            }
            interval = min(interval * Cadence.controlPollFactor, Cadence.controlPollCeiling)
        }
    }

    private func state(enabled: Bool, running: Bool) -> AppState {
        switch (enabled, running) {
        case (true, true): return .ready
        case (true, false): return .starting
        case (false, true): return .stopping
        case (false, false): return .stopped
        }
    }

    private func applyApplication(nodeID: String, info: AppInfo) {
        guard case .ready(var apps) = catalogs[nodeID] else { return }
        if let index = apps.firstIndex(where: { $0.id == info.id }) {
            apps[index] = info
            catalogs[nodeID] = .ready(apps)
        }
    }

    private func updateApplication(nodeID: String, appID: String, transform: (AppInfo) -> AppInfo) {
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
        case .gatewayTrouble: return .gatewayTrouble
        }
    }

    private static func state(for error: ClientError) -> CatalogState {
        switch CatalogOutcome.forRefusal(error) {
        case .offline: return .offline
        case .unauthorized: return .unauthorized
        case .apps, .gatewayTrouble: return .gatewayTrouble
        }
    }

    // MARK: - Web Target Resolution

    /// Where one application lives, asked down the one road the phone would take
    /// — the same single road Android's `open` uses. A road that stops answering
    /// is the catalog refresh's question, not this one's.
    func resolveWebTarget(nodeID: String, appID: String) async throws -> WebTarget {
        guard let node = nodesController.node(withID: nodeID) else { throw ClientError(.nodeNotFound) }
        guard let path = nodesController.preferredPath(for: node),
              let identity = nodesController.identity(forPath: path),
              let credential = vault.prepare(origin: identity.origin),
              let client = clients.deviceClient(for: identity, vault: vault)
        else {
            throw ClientError(.unauthorized)
        }
        let url = try await client.open(nodeID: nodeID, appID: appID)
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
    }
}
