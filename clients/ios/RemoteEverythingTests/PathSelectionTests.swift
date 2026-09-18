import XCTest
@testable import RemoteEverything

/// Path choice is silent and network-scoped (ui-contract §4), and the merged
/// node list is the only place a node exists on this side.
final class PathSelectionTests: XCTestCase {

    private func path(origin: String, reachable: Bool?, latency: Int?, isPrivate: Bool) -> Path {
        Path(origin: origin, identityRef: "re-x", reachable: reachable, latencyMs: latency, isPrivate: isPrivate, lastCheckedAt: nil)
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

    func testInvalidatingRetiresOnlyOneNode() {
        let cache = PathSelector.Cache()
        let node = Node(id: "n", name: "Desk", paths: [
            path(origin: "https://gw.example.com", reachable: true, latency: 10, isPrivate: false),
        ])
        XCTAssertNotNil(cache.resolve(node: node, networkKey: "wifi"))
        cache.invalidate(nodeID: "n")
        XCTAssertNotNil(cache.resolve(node: node, networkKey: "wifi"))
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
