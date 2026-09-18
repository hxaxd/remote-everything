import Foundation

@MainActor
final class NodesController: ObservableObject {

    @Published private(set) var identities: [Identity] = []
    @Published private(set) var nodes: [Node] = []
    @Published private(set) var stagedSetups: [StagedSetup] = []
    @Published private(set) var identityConditions: [String: IdentityCondition] = [:]
    @Published private(set) var isRefreshing = false

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

    func orderedPaths(for node: Node) -> [Path] {
        let chosen = pathSelector.preferred(node: node, networkKey: network.key)
        let rest = node.paths.filter { $0.origin != chosen?.origin }
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
        nodes = nodes.compactMap { node in
            let remaining = node.paths.filter { $0.origin != origin }
            return remaining.isEmpty ? nil : Node(id: node.id, name: node.name, paths: remaining)
        }
    }

    private func replace(_ node: Node) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node
    }

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
}
