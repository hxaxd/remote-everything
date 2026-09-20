import XCTest
@testable import RemoteEverything

/// Path choice is silent and network-scoped (ui-contract §4), and the merged
/// node list is the only place a node exists on this side.
final class PathSelectionTests: XCTestCase {

    private func path(origin: String, reachable: Bool?, latency: Int?, isPrivate: Bool) -> Path {
        Path(origin: origin, reachable: reachable, latencyMs: latency, isPrivate: isPrivate, lastCheckedAt: nil)
    }

    func testPrivateWinsOverPublic() {
        let chosen = PathSelector.choose([
            path(origin: "https://gw.example.com", reachable: true, latency: 20, isPrivate: false),
            path(origin: "https://192.168.1.4:8443", reachable: true, latency: 90, isPrivate: true),
        ])
        XCTAssertEqual(chosen?.origin, "https://192.168.1.4:8443")
    }

    func testLatencyBreaksATie() {
        let chosen = PathSelector.choose([
            path(origin: "https://a.example.com", reachable: true, latency: 60, isPrivate: false),
            path(origin: "https://b.example.com", reachable: true, latency: 15, isPrivate: false),
        ])
        XCTAssertEqual(chosen?.origin, "https://b.example.com")
    }

    func testUnreachablePathsAreNeverChosen() {
        let chosen = PathSelector.choose([
            path(origin: "https://192.168.1.4:8443", reachable: false, latency: 5, isPrivate: true),
            path(origin: "https://gw.example.com", reachable: true, latency: 90, isPrivate: false),
        ])
        XCTAssertEqual(chosen?.origin, "https://gw.example.com")
    }

    func testNothingReachableMeansNoChoice() {
        XCTAssertNil(PathSelector.choose([
            path(origin: "https://gw.example.com", reachable: false, latency: nil, isPrivate: false),
            path(origin: "https://other.example.com", reachable: nil, latency: nil, isPrivate: false),
        ]))
    }

    func testTheCacheIsRetiredWhenTheNetworkChanges() {
        let cache = PathSelector.Cache()
        let node = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://192.168.1.4:8443", reachable: true, latency: 90, isPrivate: true),
            path(origin: "https://gw.example.com", reachable: true, latency: 10, isPrivate: false),
        ])
        let first = cache.resolve(node: node, networkKey: "wifi")
        XCTAssertEqual(first?.origin, "https://192.168.1.4:8443")

        let moved = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://192.168.1.4:8443", reachable: false, latency: nil, isPrivate: true),
            path(origin: "https://gw.example.com", reachable: true, latency: 10, isPrivate: false),
        ])
        XCTAssertEqual(cache.resolve(node: moved, networkKey: "cellular")?.origin, "https://gw.example.com")
    }

    // MARK: - The remembered choice

    /// The remembered choice holds while it answers *and* while it is still the
    /// best class there is — the cases clients/behavior/fixtures/paths.json pins,
    /// in the same order.
    func testARememberedTunnelGivesWayToAPrivatePathThatHasBecomeReachable() {
        let cache = PathSelector.Cache()
        let tunnelOnly = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://gw.example.com", reachable: true, latency: 20, isPrivate: false),
            path(origin: "https://192.168.1.10:58627", reachable: false, latency: nil, isPrivate: true),
        ])
        XCTAssertEqual(cache.resolve(node: tunnelOnly, networkKey: "wifi")?.origin, "https://gw.example.com")

        let both = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://gw.example.com", reachable: true, latency: 20, isPrivate: false),
            path(origin: "https://192.168.1.10:58627", reachable: true, latency: 40, isPrivate: true),
        ])
        XCTAssertEqual(cache.resolve(node: both, networkKey: "wifi")?.origin, "https://192.168.1.10:58627")
    }

    func testARememberedPrivatePathIsKeptWhileItAnswers() {
        let cache = PathSelector.Cache()
        let both = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://gw.example.com", reachable: true, latency: 20, isPrivate: false),
            path(origin: "https://192.168.1.10:58627", reachable: true, latency: 40, isPrivate: true),
        ])
        XCTAssertEqual(cache.resolve(node: both, networkKey: "wifi")?.origin, "https://192.168.1.10:58627")
        XCTAssertEqual(cache.resolve(node: both, networkKey: "wifi")?.origin, "https://192.168.1.10:58627")
    }

    func testARememberedPathThatStoppedAnsweringIsReplaced() {
        let cache = PathSelector.Cache()
        let lanOnly = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://192.168.1.10:58627", reachable: true, latency: 40, isPrivate: true),
            path(origin: "https://gw.example.com", reachable: false, latency: nil, isPrivate: false),
        ])
        XCTAssertEqual(cache.resolve(node: lanOnly, networkKey: "wifi")?.origin, "https://192.168.1.10:58627")

        let lanGone = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://192.168.1.10:58627", reachable: false, latency: nil, isPrivate: true),
            path(origin: "https://slow.example.com", reachable: true, latency: 90, isPrivate: false),
            path(origin: "https://gw.example.com", reachable: true, latency: 20, isPrivate: false),
        ])
        XCTAssertEqual(cache.resolve(node: lanGone, networkKey: "wifi")?.origin, "https://gw.example.com")
    }

    func testInsideOneClassTheRememberedChoiceIsTheChoice() {
        let cache = PathSelector.Cache()
        let slowOnly = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://slow.example.com", reachable: true, latency: 90, isPrivate: false),
            path(origin: "https://gw.example.com", reachable: false, latency: nil, isPrivate: false),
        ])
        XCTAssertEqual(cache.resolve(node: slowOnly, networkKey: "wifi")?.origin, "https://slow.example.com")
        let both = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://slow.example.com", reachable: true, latency: 90, isPrivate: false),
            path(origin: "https://gw.example.com", reachable: true, latency: 20, isPrivate: false),
        ])
        // Kept: the choice is remembered inside a class, which is what stops a poll
        // from flapping between two tunnels.
        XCTAssertEqual(cache.resolve(node: both, networkKey: "wifi")?.origin, "https://slow.example.com")
    }

    func testNothingReachableRemembersNothing() {
        let cache = PathSelector.Cache()
        let answerless = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://gw.example.com", reachable: false, latency: nil, isPrivate: false),
            path(origin: "https://192.168.1.10:58627", reachable: nil, latency: nil, isPrivate: true),
        ])
        XCTAssertNil(cache.resolve(node: answerless, networkKey: "wifi"))
    }

    func testInvalidatingRetiresOnlyOneNode() {
        let cache = PathSelector.Cache()
        let node1 = Node(id: "n1", name: "Desk", paths: [
            path(origin: "https://gw1.example.com", reachable: true, latency: 10, isPrivate: false),
        ])
        let node2 = Node(id: "n2", name: "Laptop", paths: [
            path(origin: "https://gw2.example.com", reachable: true, latency: 20, isPrivate: false),
        ])
        XCTAssertEqual(cache.resolve(node: node1, networkKey: "wifi")?.origin, "https://gw1.example.com")
        XCTAssertEqual(cache.resolve(node: node2, networkKey: "wifi")?.origin, "https://gw2.example.com")

        // Invalidate node1 only
        cache.invalidate(nodeID: "n1")

        let node1Updated = Node(id: "n1", name: "Desk", paths: [
            path(origin: "https://gw1.example.com", reachable: true, latency: 50, isPrivate: false),
            path(origin: "https://faster.example.com", reachable: true, latency: 5, isPrivate: false),
        ])
        let node2Updated = Node(id: "n2", name: "Laptop", paths: [
            path(origin: "https://gw2.example.com", reachable: true, latency: 20, isPrivate: false),
            path(origin: "https://faster.example.com", reachable: true, latency: 5, isPrivate: false),
        ])

        // node1 re-evaluates because it was invalidated
        XCTAssertEqual(cache.resolve(node: node1Updated, networkKey: "wifi")?.origin, "https://faster.example.com")
        // node2 keeps its cached choice because its path is still reachable and it was not invalidated
        XCTAssertEqual(cache.resolve(node: node2Updated, networkKey: "wifi")?.origin, "https://gw2.example.com")
    }

    func testPrivateHostsAreRecognised() {
        XCTAssertTrue(NodeMerge.isPrivateHost("10.0.0.7"))
        XCTAssertTrue(NodeMerge.isPrivateHost("172.16.4.1"))
        XCTAssertTrue(NodeMerge.isPrivateHost("172.31.4.1"))
        XCTAssertTrue(NodeMerge.isPrivateHost("192.168.7.7"))
        XCTAssertTrue(NodeMerge.isPrivateHost("169.254.1.1"))
        XCTAssertTrue(NodeMerge.isPrivateHost("127.0.0.1"))
        XCTAssertTrue(NodeMerge.isPrivateHost("fe80::1"))
        XCTAssertTrue(NodeMerge.isPrivateHost("::1"))
        XCTAssertFalse(NodeMerge.isPrivateHost("172.32.4.1"))
        XCTAssertFalse(NodeMerge.isPrivateHost("8.8.8.8"))
        XCTAssertFalse(NodeMerge.isPrivateHost("gw.example.com"))
    }

    func testPrivateOriginsDropTheirPortAndScheme() {
        XCTAssertTrue(NodeMerge.isPrivateOrigin("https://192.168.1.4:8443"))
        XCTAssertFalse(NodeMerge.isPrivateOrigin("https://gw.example.com"))
    }

    // MARK: - Merging

    func testOneNodeSeenThroughTwoGatewaysIsOneRowWithTwoPaths() {
        let lan = Identity(
            origin: "https://192.168.1.4:8443",
            deviceName: "phone",
            certFingerprint: String(repeating: "a", count: 64),
            credentialRef: "re-lan",
            serverPin: nil,
            createdAt: Date()
        )
        let tunnel = Identity(
            origin: "https://gw.example.com",
            deviceName: "phone",
            certFingerprint: String(repeating: "b", count: 64),
            credentialRef: "re-tunnel",
            serverPin: nil,
            createdAt: Date()
        )
        let nodeID = String(repeating: "c", count: 64)
        let otherID = String(repeating: "d", count: 64)
        let answers = [
            NodeMerge.Answer(
                identity: lan,
                response: NodesResponse(ok: true, nodes: [.init(id: nodeID, name: "Desk")]),
                reachable: true,
                latencyMs: 12,
                checkedAt: Date()
            ),
            NodeMerge.Answer(
                identity: tunnel,
                response: NodesResponse(ok: true, nodes: [.init(id: nodeID, name: "Desk"), .init(id: otherID, name: "NAS")]),
                reachable: true,
                latencyMs: 80,
                checkedAt: Date()
            ),
        ]
        let merged = NodeMerge.merge(answers)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.id, nodeID)
        XCTAssertEqual(merged.first?.paths.count, 2)
        XCTAssertEqual(merged.first?.paths.first?.isPrivate, true)
        XCTAssertEqual(merged.last?.paths.count, 1)
    }

    func testAFailedGatewayKeepsItsNodesOnScreen() {
        let identity = Identity(
            origin: "https://gw.example.com",
            deviceName: "phone",
            certFingerprint: String(repeating: "a", count: 64),
            credentialRef: "re-x",
            serverPin: nil,
            createdAt: Date()
        )
        let merged = NodeMerge.merge([
            NodeMerge.Answer(
                identity: identity,
                response: NodesResponse(ok: true, nodes: [.init(id: String(repeating: "c", count: 64), name: "Desk")]),
                reachable: false,
                latencyMs: nil,
                checkedAt: Date()
            ),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.paths.first?.reachable, false)
    }

    func testAPendingSetupIsANodeWithoutAPath() {
        let staged = StagedSetup(
            origin: "https://gw.example.com",
            nodeID: String(repeating: "c", count: 64),
            nodeName: "Desk",
            deviceName: "phone",
            certificateFingerprint: String(repeating: "a", count: 64),
            credentialRef: "re-x",
            serverPin: nil,
            pendingExpiresAt: Date().addingTimeInterval(600),
            createdAt: Date()
        )
        let node = NodeMerge.pendingNode(staged: staged)
        XCTAssertEqual(node.name, "Desk")
        XCTAssertTrue(node.paths.isEmpty)
        XCTAssertFalse(staged.isExpired)
    }
}
