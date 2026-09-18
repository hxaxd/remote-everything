import Foundation

/// Merging every identity's answer into the one list the UI shows. A node is one
/// row however many gateways serve it, and each gateway that serves it is one
/// path on that row.
enum NodeMerge {

    /// One gateway's answer about its nodes, with what was learned by asking it.
    struct Answer {
        let identity: Identity
        let response: NodesResponse
        let reachable: Bool
        let latencyMs: Int?
        let checkedAt: Date
    }

    /// The merged list: one row per node id, first appearance order — the order
    /// the identities are kept in, and inside one answer the gateway's own order.
    static func merge(_ answers: [Answer]) -> [Node] {
        var order: [String] = []
        var byID: [String: Node] = [:]
        for answer in answers {
            let isPrivate = isPrivateOrigin(answer.identity.origin)
            for entry in answer.response.nodes {
                let path = Path(
                    origin: answer.identity.origin,
                    identityRef: answer.identity.credentialRef,
                    reachable: answer.reachable,
                    latencyMs: answer.latencyMs,
                    isPrivate: isPrivate,
                    lastCheckedAt: answer.checkedAt
                )
                if var existing = byID[entry.id] {
                    existing.paths.append(path)
                    byID[entry.id] = existing
                } else {
                    order.append(entry.id)
                    byID[entry.id] = Node(id: entry.id, name: entry.name, paths: [path])
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// A node a staged pairing is waiting on: it is known by its id and the name
    /// the invitation carried, and it has no path yet — the gateway has not
    /// admitted this device, so there is nothing to ask.
    static func pendingNode(staged: StagedSetup) -> Node {
        Node(id: staged.nodeID, name: staged.nodeName, paths: [])
    }

    /// Whether an origin's host is a private address: RFC1918, link-local or
    /// loopback, which is what makes a path a LAN path rather than a tunnel.
    static func isPrivateOrigin(_ origin: String) -> Bool {
        isPrivateHost(GatewayChallengeHandler.host(ofOrigin: origin))
    }

    static func isPrivateHost(_ host: String) -> Bool {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if value.contains(":") {
            // IPv6: loopback, link-local (fe80::/10) and unique-local (fc00::/7).
            if value == "::1" { return true }
            if value.hasPrefix("fe8") || value.hasPrefix("fe9") || value.hasPrefix("fea") || value.hasPrefix("feb") {
                return true
            }
            return value.hasPrefix("fc") || value.hasPrefix("fd")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard let octet = Int(part), (0...255).contains(octet) else { return false }
            octets.append(octet)
        }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (127, _): return true
        default: return false
        }
    }
}
