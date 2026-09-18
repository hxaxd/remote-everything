import Foundation

/// Choosing a road without asking anybody (ui-contract §4). Among the paths that
/// answered, a private address wins — it is the LAN, and it is faster by
/// construction. Among equals, the one that answered fastest wins. The choice is
/// remembered per network and never shown as a control: the only thing the UI
/// says is "LAN" or "Tunnel".
enum PathSelector {

    static func choose(_ paths: [Path]) -> Path? {
        let reachable = paths.filter { $0.reachable == true }
        return reachable.min { left, right in
            if left.isPrivate != right.isPrivate { return left.isPrivate }
            let leftLatency = left.latencyMs ?? Int.max
            let rightLatency = right.latencyMs ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            return left.origin < right.origin
        }
    }

    /// The remembered choice, retired when the network changes or when the path
    /// it names is no longer reachable.
    final class Cache {

        private var networkKey: String?
        private var choices: [String: Path] = [:]

        func resolve(node: Node, networkKey: String) -> Path? {
            if self.networkKey != networkKey {
                self.networkKey = networkKey
                _ = choices.removeAll()
            }
            if let cached = choices[node.id],
               node.paths.contains(where: { $0.origin == cached.origin && $0.reachable == true }) {
                return cached
            }
            guard let chosen = PathSelector.choose(node.paths) else { return nil }
            choices[node.id] = chosen
            return chosen
        }

        /// The path a request should go down now: the remembered one, or the
        /// best one there is.
        func preferred(node: Node, networkKey: String) -> Path? {
            resolve(node: node, networkKey: networkKey)
        }

        /// Retires one node's choice: used when a request failed on the path it
        /// chose, so the next attempt tries the next best.
        func invalidate(nodeID: String) {
            _ = choices.removeValue(forKey: nodeID)
        }

        func reset() {
            _ = choices.removeAll()
        }
    }
}
