import Foundation

@MainActor
final class NodesController: ObservableObject {

    @Published private(set) var identities: [Identity] = []
    @Published private(set) var nodes: [Node] = []
    @Published private(set) var stagedSetups: [StagedSetup] = []
    @Published private(set) var identityConditions: [String: IdentityCondition] = [:]
    @Published private(set) var trouble: [String: LinkTrouble] = [:]
    @Published private(set) var isRefreshing = false

    private var failedProbes: [String: [LinkAttempt]] = [:]
    private var lastAnswerAt: [String: Date] = [:]

    private let store: ClientStore
    private let vault: IdentityVault
    private let clients: GatewayClientPool
    private let pathSelector: PathSelector.Cache
    private let network: NetworkMonitor

    init(
        store: ClientStore,
        vault: IdentityVault,
        clients: GatewayClientPool,
        pathSelector: PathSelector.Cache,
        network: NetworkMonitor
    ) {
        self.store = store
        self.vault = vault
        self.clients = clients
        self.pathSelector = pathSelector
        self.network = network
    }

    /// Reconciles identities and staged setups against the secure vault and disk.
    func reconcile(pairing: PairingCoordinator) -> (kept: [Identity], lost: [String]) {
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
        return (kept, lost)
    }

    /// Asks every gateway what it serves, in parallel, and rebuilds the merged list.
    func refreshNodes() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Re-read identities from store so newly added or modified identities are picked up.
        let liveIdentities = store.loadIdentities()
        var currentIdentities: [Identity] = []
        for identity in liveIdentities {
            if vault.hasCredential(origin: identity.origin) {
                currentIdentities.append(identity)
            }
        }
        if !currentIdentities.isEmpty || identities.isEmpty {
            identities = currentIdentities
        }

        let started = Date()
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
                        await NodesController.probe(identity: entry.identity, client: entry.client)
                    }
                }
                var collected: [NodeProbe] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for result in results {
                let origin = result.identity.origin
                switch result.outcome {
                case .answered(let response, let latency):
                    identityConditions[origin] = .ok
                    recordAnswer(origin: origin, response: response)
                    store.saveCachedNodes(response, origin: origin)
                    answers.append(
                        NodeMerge.Answer(
                            identity: result.identity,
                            response: response,
                            reachable: true,
                            latencyMs: latency,
                            checkedAt: Date()
                        )
                    )
                case .failed(let error):
                    let failure = classifyFailure(error, offline: network.isOffline)
                    recordFailure(origin: origin, failure: failure)
                    if let clientError = error as? ClientError,
                       (clientError.code == .unauthorized || clientError.code == .nodeRequired) {
                        identityConditions[origin] = .unauthorized
                    } else {
                        identityConditions[origin] = .unreachable
                    }
                    fallback(&answers, identity: result.identity)
                }
            }
        }

        nodes = NodeMerge.merge(answers)
        refreshPendingRows()

        // A refresh that finishes before the eye can read it is a refresh nobody
        // saw: hold the working line just long enough for the tap or the pull to
        // be the thing it is, even when every gateway answered from its cache.
        // The hold lives here, while `isRefreshing` is still true, so the line
        // it drives actually shows.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 0.4 {
            try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000))
        }
    }

    func status(of node: Node) -> NodeStatus {
        // Only a stage whose pending window is still open says "waiting for
        // approval"; an expired one is dropped by the approval poll and is not
        // a pending row in the meantime.
        if stagedSetups.contains(where: { $0.nodeID == node.id && !$0.isExpired }) { return .pendingApproval }
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

    /// The path a request for this node would take right now — the one the row
    /// names, and the one the screen's own hint names.
    func preferredPath(for node: Node) -> Path? {
        pathSelector.preferred(node: node, networkKey: network.key)
    }

    func orderedPaths(for node: Node) -> [Path] {
        // The chosen path goes first, then the other roads that answered — the
        // same "roads" a catalog or an open is fetched down (Android: roads =
        // chosen + paths whose reachable == true). A path that did not answer is
        // not a road worth trying twice in one minute.
        let chosen = pathSelector.preferred(node: node, networkKey: network.key)
        let rest = node.paths.filter { path in
            path.origin != chosen?.origin && path.reachable == true
        }
        return (chosen.map { [$0] } ?? []) + rest
    }

    func markReachable(path: Path, nodeID: String, latencyMs: Int?) {
        guard var node = node(withID: nodeID),
              let index = node.paths.firstIndex(where: { $0.origin == path.origin })
        else { return }
        node.paths[index].reachable = true
        node.paths[index].latencyMs = latencyMs
        node.paths[index].lastCheckedAt = Date()
        replace(node)
    }

    func markUnreachable(path: Path, nodeID: String) {
        guard var node = node(withID: nodeID),
              let index = node.paths.firstIndex(where: { $0.origin == path.origin })
        else { return }
        node.paths[index].reachable = false
        node.paths[index].latencyMs = nil
        node.paths[index].lastCheckedAt = Date()
        replace(node)
    }

    func setCondition(origin: String, condition: IdentityCondition) {
        identityConditions[origin] = condition
    }

    func record(_ identity: Identity) {
        var updated = identities.filter { $0.origin != identity.origin }
        updated.append(identity)
        identities = updated
        store.saveIdentities(updated)
    }

    func setStaged(_ staged: StagedSetup) {
        stagedSetups = stagedSetups.filter { $0.origin != staged.origin } + [staged]
        refreshPendingRows()
    }

    func removeStaged(origin: String) {
        stagedSetups = stagedSetups.filter { $0.origin != origin }
        refreshPendingRows()
    }

    func forget(origin: String) {
        clients.drop(origin: origin)
        vault.forget(origin: origin)
        pathSelector.reset()
        store.clearCachedNodes(origin: origin)
        identities = identities.filter { $0.origin != origin }
        store.saveIdentities(identities)
        _ = identityConditions.removeValue(forKey: origin)
        _ = trouble.removeValue(forKey: origin)
        _ = failedProbes.removeValue(forKey: origin)
        _ = lastAnswerAt.removeValue(forKey: origin)
        nodes = nodes.compactMap { node in
            let remaining = node.paths.filter { $0.origin != origin }
            return remaining.isEmpty ? nil : Node(id: node.id, name: node.name, paths: remaining)
        }
    }

    func troubleFor(_ origin: String) -> LinkTrouble? {
        trouble[origin]
    }

    func failedProbesFor(_ origin: String) -> [LinkAttempt] {
        failedProbes[origin] ?? []
    }

    func lastAnswerFor(_ origin: String) -> Date? {
        lastAnswerAt[origin]
    }

    private func recordAnswer(origin: String, response: NodesResponse) {
        lastAnswerAt[origin] = Date()
        failedProbes.removeValue(forKey: origin)
        trouble.removeValue(forKey: origin)
    }

    private func recordFailure(origin: String, failure: LinkFailure) {
        let now = Date()
        var log = failedProbes[origin] ?? []
        log.insert(LinkAttempt(at: now, kind: failure.kind), at: 0)
        while log.count > LinkAttemptsKept {
            log.removeLast()
        }
        failedProbes[origin] = log

        let previous = trouble[origin]
        trouble[origin] = LinkTrouble(
            kind: failure.kind,
            at: now,
            since: previous?.since ?? now,
            attempts: (previous?.attempts ?? 0) + 1,
            code: failure.code,
            httpStatus: failure.httpStatus,
            detail: failure.detail,
            lastGoodAt: lastAnswerAt[origin]
        )
    }

    private func replace(_ node: Node) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node
    }

    /// A stage whose pending window has closed is not a pending row any more:
    /// it leaves the list here and leaves `stagedSetups` when the approval poll
    /// runs into it (`resumeStagedSetups` discards it with a notice) — an
    /// expired invitation is not a node worth waiting on.
    private func refreshPendingRows() {
        let waiting = stagedSetups.filter { !$0.isExpired }
        let known = Set(nodes.map(\.id))
        for staged in waiting where !known.contains(staged.nodeID) {
            nodes.append(NodeMerge.pendingNode(staged: staged))
        }
        let stagedNodeIDs = Set(waiting.map(\.nodeID))
        nodes = nodes.filter { node in
            !node.paths.isEmpty || stagedNodeIDs.contains(node.id)
        }
    }

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
            case failed(Error)
        }
    }

    private static func probe(identity: Identity, client: GatewayClient) async -> NodeProbe {
        let started = Date()
        do {
            let response = try await client.nodes(timeout: Cadence.probeTimeout)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return NodeProbe(identity: identity, outcome: .answered(response, latency))
        } catch {
            return NodeProbe(identity: identity, outcome: .failed(error))
        }
    }
}
