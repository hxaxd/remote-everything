package com.remoteeverything.core.pathselect

import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.Path

/**
 * Silent path choice, ui-contract §4: among reachable paths a private address
 * wins; within the same class, lower latency wins. The cache is scoped to the
 * current network — a network change invalidates every choice.
 */
object PathSelector {

    fun choose(paths: List<Path>): Path? =
        paths.filter { it.reachable == true }
            .minWithOrNull(compareBy({ !it.isPrivate }, { it.latencyMs ?: Long.MAX_VALUE }))

    class Cache {
        private var networkKey: String? = null
        private val choices = LinkedHashMap<String, Path>()

        /**
         * The path to use now.
         *
         * A remembered path is kept while it still answers *and* it is still in
         * the best class there is: remembering is what keeps a poll from flapping
         * between two tunnels, but a remembered tunnel is not a reason to keep
         * going out to the internet after the phone has walked into the same room
         * as the gateway. The moment a private path answers, the phone takes it —
         * and goes back to the tunnel when the private one stops answering.
         */
        fun resolve(node: Node, currentNetworkKey: String): Path? {
            if (networkKey != currentNetworkKey) {
                networkKey = currentNetworkKey
                choices.clear()
            }
            val best = choose(node.paths)
            val remembered = choices[node.id]
                ?.takeIf { cached -> node.paths.any { it.origin == cached.origin && it.reachable == true } }
            val chosen = when {
                best == null -> null
                remembered == null -> best
                remembered.isPrivate == best.isPrivate -> remembered
                else -> best
            }
            if (chosen != null) choices[node.id] = chosen else choices.remove(node.id)
            return chosen
        }

        fun invalidate(nodeId: String) {
            choices.remove(nodeId)
        }
    }
}
