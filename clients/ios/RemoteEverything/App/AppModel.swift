import Foundation
import SwiftUI
import UIKit

/// Where a detail column can go. S1 → S3 → S4.
enum AppRoute: Hashable {
    case node(String)
    case application(nodeID: String, appID: String)
}

/// S3's whole-page state (ui-contract §2/S3).
enum CatalogState: Equatable {
    case loading
    case ready([AppInfo])
    /// `computer_offline` is an answer, not an error: the machine is off, asleep
    /// or its tunnel is down.
    case offline
    /// The gateway says this device may not reach the node any more.
    case unauthorized
    /// The gateway itself could not be reached: the network, not the node.
    case unreachable
    case refused(ClientError)

    var applications: [AppInfo] {
        if case .ready(let apps) = self { return apps }
        return []
    }
}

/// The light notices (toast/banner) of ui-contract §3 — nothing here is a page.
enum Notice: Equatable, Identifiable {
    case busy
    case appGone
    case stopFailed
    case controlFailed
    case network
    case nodeGone
    case invitationExpired
    case credentialLost(String)

    var id: String {
        switch self {
        case .busy: return "busy"
        case .appGone: return "appGone"
        case .stopFailed: return "stopFailed"
        case .controlFailed: return "controlFailed"
        case .network: return "network"
        case .nodeGone: return "nodeGone"
        case .invitationExpired: return "invitationExpired"
        case .credentialLost(let origin): return "credentialLost-\(origin)"
        }
    }
}

/// S2's state machine.
enum PairingPhase: Equatable {
    case idle
    case pairing
    case failed(PairingFailure)
}

enum PairingFailure: Equatable {
    case refusal(ClientError)
    case network
    /// A client-side failure: malformed values on the way in or out. It is our
    /// bug, and the copy says so rather than blaming the operator.
    case client
}

enum UpdateState: Equatable {
    case idle
    case checking
    case result(UpdateResult)
}

/// What an application's WebView needs: where to go, and who answers for it.
struct WebTarget {
    let url: URL
    let handler: GatewayChallengeHandler
    let isPrivate: Bool
}

/// The app's single dispatcher: every state change happens here, on the main
/// actor, and the views only read what it publishes.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var settings: ClientSettings
    @Published private(set) var identities: [Identity] = []
    @Published private(set) var nodes: [Node] = []
    @Published private(set) var stagedSetups: [StagedSetup] = []
    @Published private(set) var identityConditions: [String: IdentityCondition] = [:]
    @Published private(set) var catalogs: [String: CatalogState] = [:]
    @Published private(set) var isRefreshing = false

    @Published var notice: Notice?
    @Published var isAddingNode = false
    @Published var isShowingSettings = false
    @Published var path: [AppRoute] = []
    @Published var selectedNodeID: String?

    // S2
    @Published var addNodeText = ""
    @Published private(set) var invitation: SetupURI.Invitation?
    @Published private(set) var invitationError: SetupURI.Rejected?
    @Published var deviceNameDraft = ""
    @Published private(set) var pairingPhase: PairingPhase = .idle
    private var pairingAttempt: PairingCoordinator.Attempt?

    // S5
    @Published private(set) var updateState: UpdateState = .idle

    // MARK: - Collaborators

    private let store: ClientStore
    private let vault: IdentityVault
    private let stages: StagedSetupStore
    private let pairing: PairingCoordinator
    private let clients: GatewayClientPool
    private let pathSelector = PathSelector.Cache()
    private let network = NetworkMonitor()
    private let updateChecker: UpdateChecker

    private var refreshLoop: Task<Void, Never>?
    private var catalogLoop: Task<Void, Never>?
    private var pendingLoop: Task<Void, Never>?
    private var controlTasks: [String: Task<Void, Never>] = [:]
    private var catalogNodeID: String?

    init(
        store: ClientStore = ClientStore(),
        vault: IdentityVault = IdentityVault(),
        updateChecker: UpdateChecker = UpdateChecker(),
        clients: GatewayClientPool = GatewayClientPool()
    ) {
        self.store = store
        self.vault = vault
        self.updateChecker = updateChecker
        self.clients = clients
        self.settings = store.loadSettings()
        let stages = StagedSetupStore(directory: store.pairingDirectory)
        self.stages = stages
        self.pairing = PairingCoordinator(vault: vault, stages: stages) { origin, credential, pin in
            if credential == nil {
                return clients.pairingClient(origin: origin, pin: pin)
            }
            return GatewayClient(origin: origin, credential: credential, pin: pin)
        }
    }

    // MARK: - Lifecycle

    func start() {
        Localization.apply(settings.language)
        network.onPathChange = { [weak self] in
            Task { await self?.refreshNodes() }
        }
        network.start()
        reconcile()
        Task { await refreshNodes() }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startForegroundLoops()
            Task { await refreshNodes() }
        case .background:
            stopForegroundLoops()
        default:
            break
        }
    }

    private func startForegroundLoops() {
        startRefreshLoop()
        startPendingLoop()
    }

    private func stopForegroundLoops() {
        refreshLoop?.cancel()
        refreshLoop = nil
        pendingLoop?.cancel()
        pendingLoop = nil
        catalogLoop?.cancel()
        catalogLoop = nil
        for task in controlTasks.values { task.cancel() }
        controlTasks.removeAll()
    }

    private func startRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNodes()
                do {
                    try await Task.sleep(nanoseconds: Cadence.nodeRefreshNanos)
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Startup

    /// What a restart does with what it finds on disk: staged setups that can
    /// still be resumed (credential present, pending window open) are kept, and
    /// an identity whose credential is gone is removed — a profile that cannot
    /// connect is worse than no profile, because it hides why.
    private func reconcile() {
        let (resumable, dropped) = pairing.reconcileStages()
        let liveIdentities = store.loadIdentities()
        for staged in dropped where !liveIdentities.contains(where: { $0.credentialRef == staged.credentialRef }) {
            vault.forget(aliasRef: staged.credentialRef)
        }

        var kept: [Identity] = []
        var lost: [String] = []
        for identity in liveIdentities {
            if vault.hasCredential(origin: identity.origin) {
                kept.append(identity)
            } else {
                lost.append(identity.origin)
                clients.drop(origin: identity.origin)
                store.clearCachedNodes(origin: identity.origin)
            }
        }
        if kept.count != liveIdentities.count {
            store.saveIdentities(kept)
        }
        identities = kept
        stagedSetups = resumable
        if let first = lost.first {
            notice = .credentialLost(first)
        }
    }

    // MARK: - Nodes

    /// Asks every gateway what it serves, in parallel, and rebuilds the merged
    /// list from the answers. This is also the path probe: a gateway that answers
    /// is a reachable path, and how long it took is its latency.
    func refreshNodes() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var prepared: [(identity: Identity, client: GatewayClient)] = []
        for identity in identities {
            if let client = clients.deviceClient(for: identity, vault: vault) {
                prepared.append((identity, client))
            } else {
                identityConditions[identity.origin] = .needsPairing
            }
        }

        var answers: [NodeMerge.Answer] = []
        if !prepared.isEmpty {
            let results = await withTaskGroup(of: NodeProbe.self) { group -> [NodeProbe] in
                for entry in prepared {
                    group.addTask {
                        await AppModel.probe(identity: entry.identity, client: entry.client)
                    }
                }
                var collected: [NodeProbe] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for result in results {
                switch result.outcome {
                case .answered(let response, let latency):
                    identityConditions[result.identity.origin] = .ok
                    store.saveCachedNodes(response, origin: result.identity.origin)
                    answers.append(
                        NodeMerge.Answer(
                            identity: result.identity,
                            response: response,
                            reachable: true,
                            latencyMs: latency,
                            checkedAt: Date()
                        )
                    )
                case .refused(let error):
                    if error.code == .unauthorized || error.code == .nodeRequired {
                        identityConditions[result.identity.origin] = .unauthorized
                    } else {
                        identityConditions[result.identity.origin] = .unreachable
                    }
                    fallback(&answers, identity: result.identity)
                case .unreachable:
                    identityConditions[result.identity.origin] = .unreachable
                    fallback(&answers, identity: result.identity)
                }
            }
        }

        nodes = NodeMerge.merge(answers)
        refreshPendingRows()
    }

    /// A pairing waiting for its operator is a row on S1 even though no gateway
    /// has admitted it yet: the row says "waiting for approval", and the node it
    /// names comes from the staged setup rather than from any answer.
    private func refreshPendingRows() {
        let known = Set(nodes.map(\.id))
        for staged in stagedSetups where !known.contains(staged.nodeID) {
            nodes.append(NodeMerge.pendingNode(staged: staged))
        }
        let stagedNodeIDs = Set(stagedSetups.map(\.nodeID))
        nodes = nodes.filter { node in
            !node.paths.isEmpty || stagedNodeIDs.contains(node.id)
        }
    }

    /// A gateway that did not answer keeps its last known nodes on screen, marked
    /// as not reachable, so the list does not flicker between refreshes.
    private func fallback(_ answers: inout [NodeMerge.Answer], identity: Identity) {
        guard let cached = store.cachedNodes(origin: identity.origin) else { return }
        answers.append(
            NodeMerge.Answer(
                identity: identity,
                response: cached,
                reachable: false,
                latencyMs: nil,
                checkedAt: Date()
            )
        )
    }

    private struct NodeProbe {
        let identity: Identity
        let outcome: Outcome

        enum Outcome {
            case answered(NodesResponse, Int?)
            case refused(ClientError)
            case unreachable
        }
    }

    private static func probe(identity: Identity, client: GatewayClient) async -> NodeProbe {
        let started = Date()
        do {
            let response = try await client.nodes(timeout: Cadence.probeTimeout)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return NodeProbe(identity: identity, outcome: .answered(response, latency))
        } catch let error as ClientError {
            return NodeProbe(identity: identity, outcome: .refused(error))
        } catch {
            return NodeProbe(identity: identity, outcome: .unreachable)
        }
    }

    /// S1's per-row state (ui-contract §2/S1).
    func status(of node: Node) -> NodeStatus {
        if stagedSetups.contains(where: { $0.nodeID == node.id }) { return .pendingApproval }
        if let chosen = pathSelector.preferred(node: node, networkKey: network.key) {
            return chosen.isPrivate ? .onlineLan : .onlineTunnel
        }
        if node.paths.contains(where: { $0.reachable != nil }) { return .offline }
        return .unknown
    }

    func node(withID id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    func identity(forPath path: Path) -> Identity? {
        identities.first { $0.origin == path.origin }
    }

    func nodeCount(forIdentity identity: Identity) -> Int {
        nodes.filter { node in node.paths.contains { $0.origin == identity.origin } }.count
    }

    /// The paths of a node, likeliest first: the remembered choice, then the rest.
    private func orderedPaths(for node: Node) -> [Path] {
        let chosen = pathSelector.preferred(node: node, networkKey: network.key)
        let rest = node.paths.filter { $0.origin != chosen?.origin }
        return (chosen.map { [$0] } ?? []) + rest
    }

    // MARK: - S3: catalog and control

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

    func loadCatalog(nodeID: String) async {
        guard let node = node(withID: nodeID) else {
            catalogs[nodeID] = .offline
            return
        }
        if catalogs[nodeID] == nil { catalogs[nodeID] = .loading }

        var lastError: Error?
        for path in orderedPaths(for: node).prefix(2) {
            guard let identity = identity(forPath: path),
                  let client = clients.deviceClient(for: identity, vault: vault)
            else {
                identityConditions[path.origin] = .needsPairing
                continue
            }
            let started = Date()
            do {
                let response = try await client.catalog(nodeID: nodeID)
                markReachable(path: path, nodeID: nodeID, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
                identityConditions[identity.origin] = .ok
                catalogs[nodeID] = AppModel.state(for: response)
                return
            } catch let error as ClientError {
                if error.code == .unauthorized {
                    identityConditions[identity.origin] = .unauthorized
                    catalogs[nodeID] = .unauthorized
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    notice = .busy
                }
                if error.code == .computerOffline {
                    catalogs[nodeID] = .offline
                    return
                }
                lastError = error
            } catch {
                lastError = error
            }
            // This path did not answer: the next one gets the request.
            markUnreachable(path: path, nodeID: nodeID)
            pathSelector.invalidate(nodeID: nodeID)
        }
        if let failure = lastError {
            catalogs[nodeID] = (failure is NetworkFailure) ? .unreachable : AppModel.state(for: asClientError(failure))
        } else {
            catalogs[nodeID] = .offline
        }
    }

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
        guard let node = node(withID: nodeID) else { return }
        var requestError: Error?
        for path in orderedPaths(for: node).prefix(2) {
            guard let identity = identity(forPath: path),
                  let client = clients.deviceClient(for: identity, vault: vault)
            else { continue }
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
                    notice = .appGone
                    await loadCatalog(nodeID: nodeID)
                    return
                }
                if response.errorCode == "stop_command_failed" {
                    notice = .stopFailed
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
            } catch let error as ClientError {
                if error.code == .appNotFound {
                    notice = .appGone
                    await loadCatalog(nodeID: nodeID)
                    return
                }
                if error.code == .unauthorized {
                    catalogs[nodeID] = .unauthorized
                    identityConditions[path.origin] = .unauthorized
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    notice = .busy
                }
                requestError = error
            } catch {
                requestError = error
            }
        }
        if requestError is NetworkFailure {
            notice = .network
        } else if requestError != nil {
            // The gateway answered something other than a control result: the
            // action did not happen, and saying so beats a silent list.
            notice = .controlFailed
        }
        await loadCatalog(nodeID: nodeID)
    }

    /// Status after a control action: one second at first, then slower, and
    /// never more than sixty seconds of asking — `Cadence`'s numbers, not this
    /// file's.
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
                    notice = .appGone
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
                    identityConditions[path.origin] = .unauthorized
                    return
                }
                if error.code == .rateLimited || error.code == .serverBusy {
                    notice = .busy
                    interval = min(interval * Cadence.controlPollFactor, Cadence.controlPollCeiling)
                    continue
                }
            } catch {
                // A poll that did not answer is not a control that failed: try
                // again until the deadline.
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

    private func markReachable(path: Path, nodeID: String, latencyMs: Int?) {
        guard var node = node(withID: nodeID),
              let index = node.paths.firstIndex(where: { $0.origin == path.origin })
        else { return }
        node.paths[index].reachable = true
        node.paths[index].latencyMs = latencyMs
        node.paths[index].lastCheckedAt = Date()
        replace(node)
    }

    private func markUnreachable(path: Path, nodeID: String) {
        guard var node = node(withID: nodeID),
              let index = node.paths.firstIndex(where: { $0.origin == path.origin })
        else { return }
        node.paths[index].reachable = false
        node.paths[index].latencyMs = nil
        node.paths[index].lastCheckedAt = Date()
        replace(node)
    }

    private func replace(_ node: Node) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node
    }

    /// The screen a catalog answer calls for, and the screen a refusal calls
    /// for: both are the shared mapping, so the three clients name the same page
    /// for the same bytes.
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

    // MARK: - S4: the application's own origin

    /// Asks the gateway where an application lives and prepares everything the
    /// WebView needs to reach it. The credential is resolved before the page is
    /// loaded, because a challenge answered late is a challenge answered as a
    /// failed handshake.
    func resolveWebTarget(nodeID: String, appID: String) async throws -> WebTarget {
        guard let node = node(withID: nodeID) else { throw ClientError(.nodeNotFound) }
        var lastError: Error?
        for path in orderedPaths(for: node).prefix(2) {
            guard let identity = identity(forPath: path),
                  let credential = vault.prepare(origin: identity.origin),
                  let client = clients.deviceClient(for: identity, vault: vault)
            else {
                identityConditions[path.origin] = .needsPairing
                lastError = ClientError(.unauthorized)
                continue
            }
            do {
                let url = try await client.open(nodeID: nodeID, appID: appID)
                var target = url
                // The catalog says where inside the application to land; the other
                // two clients append it, so this one does too.
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
                return WebTarget(url: target, handler: handler, isPrivate: path.isPrivate)
            } catch let error as ClientError {
                if error.code == .appNotFound {
                    notice = .appGone
                    await loadCatalog(nodeID: nodeID)
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
            pathSelector.invalidate(nodeID: nodeID)
        }
        throw lastError ?? ClientError(.computerOffline)
    }

    // MARK: - S2: pairing

    func beginAddNode() {
        addNodeText = ""
        invitation = nil
        invitationError = nil
        pairingPhase = .idle
        pairingAttempt = nil
        deviceNameDraft = AppModel.defaultDeviceName()
        isAddingNode = true
    }

    func cancelAddNode() {
        // Before the pairing request goes out there is nothing to clean up: no
        // credential, no stage, no record.
        if case .pairing = pairingPhase { return }
        isAddingNode = false
        pairingAttempt = nil
        pairingPhase = .idle
        invitation = nil
        invitationError = nil
        addNodeText = ""
    }

    /// Parses whatever the user pasted, strictly.
    func parseInvitation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            invitation = nil
            invitationError = nil
            return
        }
        do {
            let parsed = try SetupURI.parse(trimmed)
            invitation = parsed
            invitationError = nil
        } catch let rejection as SetupURI.Rejected {
            invitation = nil
            invitationError = rejection
        } catch {
            invitation = nil
            invitationError = .notASetupURI
        }
    }

    /// An invitation that arrived by opening a link.
    func handleIncomingURL(_ url: URL) {
        let text = url.absoluteString
        if !isAddingNode {
            beginAddNode()
        }
        addNodeText = text
        parseInvitation(text)
    }

    func confirmPairing() async {
        guard let invitation, case .idle = pairingPhase else { return }
        let attempt = PairingCoordinator.Attempt(
            invitation: invitation,
            deviceName: deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        pairingAttempt = attempt
        await runPairing(attempt)
    }

    func retryPairing() async {
        guard let attempt = pairingAttempt else { return }
        await runPairing(attempt)
    }

    /// After an approval or a pending answer the sheet closes and S1 shows what
    /// happened: a new row, or a row waiting for its operator.
    func finishPairingSheet() {
        isAddingNode = false
        pairingAttempt = nil
        pairingPhase = .idle
        invitation = nil
        invitationError = nil
        addNodeText = ""
    }

    private func runPairing(_ attempt: PairingCoordinator.Attempt) async {
        pairingPhase = .pairing
        do {
            let outcome = try await pairing.run(attempt)
            switch outcome {
            case .approved(let identity, let catalog):
                record(identity)
                clients.drop(origin: identity.origin)
                catalogs[attempt.invitation.node] = .ready(catalog.applicationInfos)
                await refreshNodes()
                finishPairingSheet()
            case .pendingApproval(let staged):
                setStaged(staged)
                startPendingLoop()
                finishPairingSheet()
                await refreshNodes()
            }
        } catch let error as ClientError {
            pairingPhase = .failed(.refusal(error))
        } catch is NetworkFailure {
            pairingPhase = .failed(.network)
        } catch {
            pairingPhase = .failed(.client)
        }
    }

    private func record(_ identity: Identity) {
        var updated = identities.filter { $0.origin != identity.origin }
        updated.append(identity)
        identities = updated
        store.saveIdentities(updated)
    }

    private func setStaged(_ staged: StagedSetup) {
        stagedSetups = stagedSetups.filter { $0.origin != staged.origin } + [staged]
        refreshPendingRows()
    }

    private func removeStaged(origin: String) {
        stagedSetups = stagedSetups.filter { $0.origin != origin }
        refreshPendingRows()
    }

    /// A staged pairing is asked about every `Cadence.approvalPollMs` until
    /// `Cadence.approvalPollTimeoutMs` has passed: waiting for somebody to tap
    /// approve is a wait with an end, not a loop that runs forever.
    private func startPendingLoop() {
        pendingLoop?.cancel()
        guard !stagedSetups.isEmpty else { return }
        pendingLoop = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Cadence.approvalPollTimeout)
            while !Task.isCancelled, Date() < deadline {
                guard let self else { return }
                if self.stagedSetups.isEmpty { return }
                await self.resumeStagedSetups()
                do {
                    try await Task.sleep(nanoseconds: Cadence.approvalPollNanos)
                } catch {
                    return
                }
            }
        }
    }

    /// A staged pairing that is still inside its pending window asks again: the
    /// operator approves on the gateway, and the next ask is answered.
    func resumeStagedSetups() async {
        for staged in stagedSetups {
            if staged.isExpired {
                pairing.discard(staged)
                removeStaged(origin: staged.origin)
                notice = .invitationExpired
                continue
            }
            do {
                switch try await pairing.resume(staged) {
                case .approved(let identity, let catalog):
                    record(identity)
                    clients.drop(origin: identity.origin)
                    catalogs[staged.nodeID] = .ready(catalog.applicationInfos)
                    removeStaged(origin: staged.origin)
                    await refreshNodes()
                case .pendingApproval:
                    break
                }
            } catch let error as ClientError {
                if PairingCoordinator.endsTheAttempt(error.code) {
                    removeStaged(origin: staged.origin)
                    notice = error.code == .invitationExpired ? .invitationExpired : .nodeGone
                }
            } catch {
                // Still unreachable: the pending window decides how long to keep
                // trying, not this loop.
            }
        }
    }

    /// The name this device is called, offered as the pairing default.
    static func defaultDeviceName() -> String {
        let systemName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return systemName.isEmpty ? kind : systemName
    }

    // MARK: - S5: settings

    var preferredColorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func setLanguage(_ language: Language) {
        settings.language = language
        store.saveSettings(settings)
        Localization.apply(language)
        Localization.persistPreferredLanguage(language)
    }

    func setAppearance(_ appearance: Appearance) {
        settings.appearance = appearance
        store.saveSettings(settings)
    }

    /// Forgetting a connection removes the identity, the record, the cached node
    /// list and every path decision made with it. Web data for its application
    /// origins is left in place: the origins are isolated per application, and
    /// without the identity none of them can be opened again (behavior README).
    func forget(origin: String) async {
        guard identities.contains(where: { $0.origin == origin }) else { return }
        clients.drop(origin: origin)
        vault.forget(origin: origin)
        pathSelector.reset()
        store.clearCachedNodes(origin: origin)
        identities = identities.filter { $0.origin != origin }
        store.saveIdentities(identities)
        _ = identityConditions.removeValue(forKey: origin)
        catalogs.removeAll()
        nodes = nodes.compactMap { node in
            let remaining = node.paths.filter { $0.origin != origin }
            return remaining.isEmpty ? nil : Node(id: node.id, name: node.name, paths: remaining)
        }
        await refreshNodes()
    }

    func checkForUpdates() async {
        updateState = .checking
        let result = await updateChecker.check(
            currentBuildNumber: AppVersion.buildNumber,
            currentProtocolVersion: AppVersion.protocolVersion
        )
        updateState = .result(result)
    }

    func dismissNotice(_ notice: Notice) {
        if self.notice == notice { self.notice = nil }
    }
}
