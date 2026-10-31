import Foundation

/// Merging every identity's answer into the one list the UI shows. A node is one
/// row however many gateways serve it, and each gateway that serves it is one
/// path on that row.
enum Merge {

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
                    reachable: answer.reachable,
                    latencyMs: answer.latencyMs,
                    isPrivate: isPrivate,
                    // A gateway that declared how it reaches the node is believed; one
                    // that said nothing leaves the client to judge by the address it
                    // dials. Either way a path that leaves the local network reads as a
                    // tunnel, because that is what it costs the person using it.
                    lastCheckedAt: answer.checkedAt,
                    link: (entry.link == "tunnel" || !isPrivate) ? .tunnel : .local
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
        if value == "localhost" { return true }
        if value.contains(":") {
            guard let words = ipv6Words(value) else { return false }
            if words.prefix(5).allSatisfy({ $0 == 0 }), words[5] == 65535 {
                return privateOctets([words[6] >> 8, words[6] & 255, words[7] >> 8, words[7] & 255])
            }
            return words.prefix(7).allSatisfy({ $0 == 0 }) && words[7] == 1 ||
                words[0] & 0xfe00 == 0xfc00 || words[0] & 0xffc0 == 0xfe80
        }
        return ipv4Octets(value).map(privateOctets) ?? false
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  (part.count == 1 || part.first != "0"), let octet = Int(part), (0...255).contains(octet) else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func privateOctets(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (127, _): return true
        default: return false
        }
    }

    private static func ipv6Words(_ input: String) -> [Int]? {
        var value = input
        if value.contains(".") {
            guard let at = value.lastIndex(of: ":"), let octets = ipv4Octets(String(value[value.index(after: at)...])) else { return nil }
            value = String(value[...at]) + String((octets[0] << 8) + octets[1], radix:16) + ":" + String((octets[2] << 8) + octets[3],radix:16)
        }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [Int]? {
            if part.isEmpty { return [] }
            let parts = part.split(separator:":",omittingEmptySubsequences:false)
            guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) }) else { return nil }
            return parts.compactMap { Int($0,radix:16) }
        }
        guard let left = groups(halves[0]), let right = groups(halves.count == 2 ? halves[1] : "") else { return nil }
        let missing = 8 - left.count - right.count
        if halves.count == 1 { return missing == 0 ? left : nil }
        guard missing > 0 else { return nil }
        return left + Array(repeating:0,count:missing) + right
    }
}

typealias NodeMerge = Merge
