package com.remoteeverything.app

import com.remoteeverything.core.api.ApiClient
import com.remoteeverything.core.api.GatewayClients
import com.remoteeverything.core.api.NodesResponse
import com.remoteeverything.core.api.mergeNodes
import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.NodeStatus
import com.remoteeverything.core.model.Path
import com.remoteeverything.core.pathselect.PathSelector
import com.remoteeverything.core.store.NodeCacheStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * The node list as a device sees it: every gateway it paired with is asked what
 * that device may reach, and the answers are merged into one list. Asking is
 * also the probe — the same request that says which nodes there are says which
 * path answered, which is why path selection costs no extra traffic. A gateway
 * that is unreachable now had nodes a moment ago: the in-memory last answers
 * and the on-disk cache are what a cold start shows before the first probe.
 */
class NodesController(
    private val clientFactory: (Identity) -> ApiClient?,
    private val cache: NodeCacheStore? = null,
    private val clock: () -> Long = System::currentTimeMillis,
) {

    private val selector = PathSelector.Cache()

    /** Per gateway, the last answer that arrived; also what is written to the cache. */
    private val lastGoodAnswers = mutableMapOf<String, NodesResponse>()

    /** The cache, read once: it is the fallback for a cold start, then the wire takes over. */
    private var coldCache: Map<String, NodesResponse>? = null

    private class Probe(val origin: String, val response: NodesResponse?, val latencyMs: Long?)

    suspend fun refresh(identities: List<Identity>, networkKey: String): List<Node> = coroutineScope {
        val probes = identities.map { identity ->
            async(Dispatchers.IO) { probe(identity) }
        }.awaitAll().associateBy { it.origin }
        val answers = identities.map { identity ->
            val probe = probes[identity.origin]
            val response = probe?.response
                ?: lastGoodAnswers[identity.origin]
                ?: cached(identity.origin)
                ?: NodesResponse(ok = true, nodes = emptyList())
            identity to response
        }
        mergeNodes(answers).map { node ->
            node.copy(paths = node.paths.map { path -> annotated(path, probes[path.origin]) })
        }
    }

    private fun cached(origin: String): NodesResponse? {
        val cold = coldCache ?: cache?.load().also { coldCache = it } ?: emptyMap()
        return cold[origin]
    }

    private suspend fun probe(identity: Identity): Probe {
        val client = clientFactory(identity) ?: return Probe(identity.origin, response = null, latencyMs = null)
        val started = clock()
        return try {
            val response = client.nodes()
            lastGoodAnswers[identity.origin] = response
            cache?.save(lastGoodAnswers)
            Probe(identity.origin, response, clock() - started)
        } catch (e: Exception) {
            Probe(identity.origin, response = null, latencyMs = null)
        }
    }

    private fun annotated(path: Path, probe: Probe?): Path = path.copy(
        reachable = probe?.response != null,
        latencyMs = probe?.latencyMs,
    )

    /** Which path a node is reached by right now: private before public, fast before slow. */
    fun choosePath(node: Node, networkKey: String): Path? = selector.resolve(node, networkKey)

    /** The path a node is reached by right now, which is also what the row shows. */
    fun pathFor(node: Node, networkKey: String): Path? = choosePath(node, networkKey)

    /** Which gateway a node is reached through right now; null when none answers. */
    fun originFor(node: Node, networkKey: String): String? = pathFor(node, networkKey)?.origin

    /** What a node's reachability is called, derived from the path chosen right now. */
    fun statusOf(node: Node, networkKey: String): NodeStatus = when (val path = pathFor(node, networkKey)) {
        null -> NodeStatus.OFFLINE
        else -> when {
            path.reachable != true -> NodeStatus.OFFLINE
            path.isPrivate -> NodeStatus.ONLINE_LAN
            else -> NodeStatus.ONLINE_TUNNEL
        }
    }

    /** The client that reaches one origin, for the traffic that is not a node list. */
    fun clientFor(identity: Identity): ApiClient? = clientFactory(identity)

    /** Drops one origin from memory and on-disk node cache when forgotten. */
    fun drop(origin: String) {
        lastGoodAnswers.remove(origin)
        cache?.save(lastGoodAnswers)
    }
}
