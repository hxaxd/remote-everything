package com.remoteeverything.app

import com.remoteeverything.core.api.GatewayClient
import com.remoteeverything.core.api.GatewayClients
import com.remoteeverything.core.api.NodesResponse
import com.remoteeverything.core.api.mergeNodes
import com.remoteeverything.core.diag.LinkAttempt
import com.remoteeverything.core.diag.LinkAttemptsKept
import com.remoteeverything.core.diag.LinkFailure
import com.remoteeverything.core.diag.LinkTrouble
import com.remoteeverything.core.diag.classifyFailure
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * The node list as a device sees it: every gateway it paired with is asked what
 * that device may reach, and the answers are merged into one list. Asking is
 * also the probe — the same request that says which nodes there are says which
 * path answered, which is why path selection costs no extra traffic. A gateway
 * that is unreachable now had nodes a moment ago: the in-memory last answers
 * and the on-disk cache are what a cold start shows before the first probe.
 */
class NodesController(
    private val clientFactory: (Identity) -> GatewayClient?,
    private val cache: NodeCacheStore? = null,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Whether this phone has any network to send on at all, asked when a probe fails. */
    private val offline: () -> Boolean = { false },
) {

    private val selector = PathSelector.Cache()

    private val lock = Any()

    /** Per gateway, the last answer that arrived; also what is written to the cache. */
    private val lastGoodAnswers = mutableMapOf<String, NodesResponse>()

    /** Per gateway, when it last answered — what "last answer" means in a report. */
    private val lastAnswerAt = mutableMapOf<String, Long>()

    /**
     * Per gateway, why it is not answering now. A gateway that answers has no
     * entry: the presence of one is what a screen shows a reason for, and what
     * makes the copy-the-report action appear on that connection.
     */
    private val troubleState = MutableStateFlow<Map<String, LinkTrouble>>(emptyMap())
    val trouble: StateFlow<Map<String, LinkTrouble>> = troubleState

    /** Per gateway, the last few failed probes, newest first. */
    private val failedProbes = mutableMapOf<String, MutableList<LinkAttempt>>()

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
                ?: lastGoodAnswerFor(identity.origin)
                ?: cached(identity.origin)
                ?: NodesResponse(ok = true, nodes = emptyList())
            identity to response
        }
        mergeNodes(answers).map { node ->
            node.copy(paths = node.paths.map { path -> annotated(path, probes[path.origin]) })
        }
    }

    private fun lastGoodAnswerFor(origin: String): NodesResponse? = synchronized(lock) {
        lastGoodAnswers[origin]
    }

    private fun cached(origin: String): NodesResponse? = synchronized(lock) {
        val cold = coldCache ?: cache?.load().also { coldCache = it } ?: emptyMap()
        cold[origin]
    }

    private suspend fun probe(identity: Identity): Probe {
        val client = clientFactory(identity) ?: return Probe(identity.origin, response = null, latencyMs = null)
        val started = clock()
        return try {
            val response = client.nodes()
            recordAnswer(identity.origin, response)
            Probe(identity.origin, response, clock() - started)
        } catch (e: Exception) {
            recordFailure(identity.origin, classifyFailure(e, offline()))
            Probe(identity.origin, response = null, latencyMs = null)
        }
    }

    /**
     * A gateway that answers again has nothing to report: the run of failures ends
     * here, and with it the reason it was failing — the screen that offered to copy
     * a report stops offering, which is the point of keeping this at all.
     */
    private fun recordAnswer(origin: String, response: NodesResponse) {
        val snapshot: Map<String, NodesResponse>
        synchronized(lock) {
            lastGoodAnswers[origin] = response
            lastAnswerAt[origin] = clock()
            failedProbes.remove(origin)
            snapshot = HashMap(lastGoodAnswers)
        }
        troubleState.update { current ->
            if (current.containsKey(origin)) current - origin else current
        }
        cache?.save(snapshot)
    }

    /**
     * One more failure on the same run: counted, dated from where the run began,
     * and described by the latest failure rather than the first — a phone that
     * walked out of its Wi-Fi is still failing, but it is failing differently.
     */
    private fun recordFailure(origin: String, failure: LinkFailure) {
        val now = clock()
        val lastGood: Long?
        synchronized(lock) {
            val log = failedProbes.getOrPut(origin) { mutableListOf() }
            log.add(0, LinkAttempt(now, failure.kind))
            while (log.size > LinkAttemptsKept) log.removeAt(log.lastIndex)
            lastGood = lastAnswerAt[origin]
        }
        troubleState.update { current ->
            val previous = current[origin]
            current + (
                origin to LinkTrouble(
                    kind = failure.kind,
                    at = now,
                    since = previous?.since ?: now,
                    attempts = (previous?.attempts ?: 0) + 1,
                    code = failure.code,
                    httpStatus = failure.httpStatus,
                    detail = failure.detail,
                    lastGoodAt = lastGood,
                )
            )
        }
    }

    /** The failed probes of one gateway, newest first: the run a report shows. */
    fun failedProbesFor(origin: String): List<LinkAttempt> = synchronized(lock) {
        failedProbes[origin]?.toList().orEmpty()
    }

    /** When this gateway last answered, as far as this run of the app remembers. */
    fun lastAnswerFor(origin: String): Long? = synchronized(lock) {
        lastAnswerAt[origin]
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
    fun clientFor(identity: Identity): GatewayClient? = clientFactory(identity)

    /**
     * Forgets which path was chosen for one node: the network it was chosen on is
     * not the network this phone is on any more (AppModel.networkChanged).
     */
    fun dropChoice(nodeId: String) {
        selector.invalidate(nodeId)
    }

    /** Drops one origin from memory and on-disk node cache when forgotten. */
    fun drop(origin: String) {
        val snapshot: Map<String, NodesResponse>
        synchronized(lock) {
            lastGoodAnswers.remove(origin)
            lastAnswerAt.remove(origin)
            failedProbes.remove(origin)
            snapshot = HashMap(lastGoodAnswers)
        }
        troubleState.update { current ->
            if (current.containsKey(origin)) current - origin else current
        }
        // The on-disk cache is the cold-start promise for every gateway this device
        // holds; forgetting one removes only its own entry, and a fresh answer from
        // this run is not lost to an older file. An empty cache file is then
        // genuinely empty, which is when the file goes.
        val disk = cache?.load().orEmpty()
        val kept = HashMap(disk)
        kept.remove(origin)
        snapshot.forEach { (o, r) -> if (o != origin) kept[o] = r }
        cache?.save(kept)
    }
}
