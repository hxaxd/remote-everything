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

        fun resolve(node: Node, currentNetworkKey: String): Path? {
            if (networkKey != currentNetworkKey) {
                networkKey = currentNetworkKey
                choices.clear()
            }
            val cached = choices[node.id]
            if (cached != null && node.paths.any { it.origin == cached.origin && it.reachable == true }) {
                return cached
            }
            val chosen = choose(node.paths) ?: return null
            choices[node.id] = chosen
            return chosen
        }

        fun invalidate(nodeId: String) {
            choices.remove(nodeId)
        }
    }
}
