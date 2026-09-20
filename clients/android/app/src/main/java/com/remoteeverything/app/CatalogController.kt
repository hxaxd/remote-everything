package com.remoteeverything.app

import com.remoteeverything.core.api.GatewayClient
import com.remoteeverything.core.api.CatalogOutcome
import com.remoteeverything.core.api.ControlCode
import com.remoteeverything.core.api.toAppInfo
import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.AppState
import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.Node
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Manages the live catalog of one node: periodic background refresh, application
 * start/stop control, and settle polling until the app reaches a steady state.
 */
class CatalogController(
    private val scope: CoroutineScope,
    private val nodesController: NodesController,
    private val currentNetworkKey: () -> String,
    private val currentIdentities: suspend () -> List<Identity>,
    private val currentNode: (String) -> Node?,
    private val onNotice: (Int) -> Unit,
) {
    private val _catalog = MutableStateFlow<CatalogUiState>(CatalogUiState.Loading)
    val catalog: StateFlow<CatalogUiState> = _catalog.asStateFlow()

    private var catalogJob: Job? = null
    private var watchingNodeId: String? = null

    /**
     * Watches one node's catalog.
     *
     * The node is read again on every tick, and that is not a detail: a catalog is
     * fetched *through* one of the node's paths, and which paths are reachable is a
     * fact about this minute. A screen that held on to the node object it was
     * opened with would be a screen that stays offline for as long as it is open —
     * without asking anything, because a path it believes dead is a request it
     * never makes — while the list behind it refreshes every minute and says
     * otherwise.
     *
     * [force] is what a person's Retry means: ask again, now. Without it this is
     * the idempotent version a screen asks for on entry, and a second call while
     * the loop is already running is nothing to do — which is exactly why Retry
     * has to say what it wants, or the button is a button that does not exist.
     */
    fun watchNode(node: Node, force: Boolean = false) {
        if (!force && watchingNodeId == node.id && catalogJob?.isActive == true) return
        val nodeId = node.id
        watchingNodeId = nodeId
        catalogJob?.cancel()
        _catalog.value = CatalogUiState.Loading
        catalogJob = scope.launch {
            while (true) {
                _catalog.value = fetchCatalog(currentNode(nodeId) ?: node)
                delay(Cadence.catalogRefreshMs)
            }
        }
    }

    fun stopWatching() {
        catalogJob?.cancel()
        catalogJob = null
        watchingNodeId = null
    }

    /**
     * One node's applications, asked for down every road that answers.
     *
     * The chosen path goes first, and a path that stopped answering is a reason to
     * try the one behind it — a phone that still holds a tunnel must not be told
     * its machine is gone because the Wi-Fi it was on is gone. A refusal is
     * different: it is the gateway's answer, and another road would answer the same.
     */
    suspend fun fetchCatalog(node: Node): CatalogUiState {
        val best = nodesController.choosePath(node, currentNetworkKey())
        val roads = (listOfNotNull(best) + node.paths.filter { it.reachable == true && it.origin != best?.origin })
        if (roads.isEmpty()) return CatalogUiState.Offline
        var answer: CatalogUiState = CatalogUiState.Offline
        for (path in roads) {
            val identity = currentIdentities().firstOrNull { it.origin == path.origin } ?: continue
            val client = nodesController.clientFor(identity) ?: continue
            try {
                return CatalogOutcome.forAnswer(client.catalog(node.id)).toUiState()
            } catch (e: ClientError) {
                answer = CatalogOutcome.forRefusal(e).toUiState()
                // An answer that is not "the machine is off" is the gateway talking:
                // asking it again by another road would say the same thing.
                if (answer !is CatalogUiState.Offline) return answer
            } catch (e: Exception) {
                answer = CatalogUiState.Offline
            }
            // This road is not answering: the next one gets the turn, and the
            // remembered choice stops pointing here.
            nodesController.dropChoice(node.id)
        }
        return answer
    }

    /**
     * Asks the node being watched again, now: the phone's network changed, so the
     * road in use is a question rather than an answer.
     */
    fun recheckNow() {
        val nodeId = watchingNodeId ?: return
        val node = currentNode(nodeId) ?: return
        watchNode(node, force = true)
    }

    /**
     * Starting and stopping are asked for, then waited on. The row says what was
     * asked for at once — `starting` or `stopping` — because the alternative is a
     * button that keeps offering a start that has already been sent, which is both
     * a puzzle and a way to send it twice. What follows is the node's own answer:
     * every poll writes the state the node reports, and the catalog is read again
     * when the application settles.
     */
    fun control(node: Node, appId: String, start: Boolean) {
        applyState(appId, if (start) AppState.STARTING else AppState.STOPPING)
        scope.launch {
            val path = nodesController.choosePath(node, currentNetworkKey())
            if (path == null) {
                _catalog.value = CatalogUiState.Offline
                return@launch
            }
            val identity = currentIdentities().firstOrNull { it.origin == path.origin }
            val client = identity?.let { nodesController.clientFor(it) }
            if (client == null) {
                _catalog.value = fetchCatalog(node)
                return@launch
            }
            val answer = try {
                if (start) client.start(node.id, appId) else client.stop(node.id, appId)
            } catch (e: Exception) {
                onNotice(R.string.error_control_failed)
                _catalog.value = fetchCatalog(node)
                return@launch
            }
            if (!answer.ok && answer.code == ControlCode.STATE_UPDATE_FAILED) {
                onNotice(R.string.error_stop_failed)
            }
            if (answer.code == ControlCode.COMPUTER_OFFLINE) {
                _catalog.value = CatalogUiState.Offline
                return@launch
            }
            if (answer.code == ControlCode.APP_NOT_FOUND) {
                onNotice(R.string.error_app_gone)
                _catalog.value = fetchCatalog(node)
                return@launch
            }
            // Starting and stopping are not instant: the screen keeps asking until
            // the application settles, so the row never shows a state it left.
            pollUntilSettled(client, node.id, appId)
            _catalog.value = fetchCatalog(currentNode(node.id) ?: node)
        }
    }

    private suspend fun pollUntilSettled(
        client: GatewayClient,
        nodeId: String,
        appId: String,
    ) {
        var waited = 0L
        var interval = Cadence.controlPollMs
        while (waited < Cadence.controlPollTimeoutMs) {
            delay(interval)
            waited += interval
            val status = try {
                client.status(nodeId, appId)
            } catch (e: Exception) {
                return
            }
            if (status.code == ControlCode.COMPUTER_OFFLINE) {
                _catalog.value = CatalogUiState.Offline
                return
            }
            if (status.code == ControlCode.APP_NOT_FOUND) {
                onNotice(R.string.error_app_gone)
                return
            }
            // The node's answer is the row's state, not the client's guess.
            status.app?.let { applyState(appId, it.toAppInfo().code) }
            if (status.code == ControlCode.READY || status.code == ControlCode.STOPPED) return
            interval = (interval * Cadence.controlPollFactor).toLong().coerceAtMost(Cadence.controlPollCeilingMs)
        }
    }

    /** Writes one application's state into the catalog that is on screen. */
    private fun applyState(appId: String, code: AppState) {
        val current = _catalog.value
        if (current !is CatalogUiState.Ready) return
        _catalog.value = CatalogUiState.Ready(
            current.apps.map { app -> if (app.id == appId) app.copy(code = code) else app },
        )
    }
}

private fun CatalogOutcome.toUiState(): CatalogUiState = when (this) {
    is CatalogOutcome.Apps -> CatalogUiState.Ready(apps)
    CatalogOutcome.Offline -> CatalogUiState.Offline
    CatalogOutcome.Unauthorized -> CatalogUiState.Unauthorized
    CatalogOutcome.GatewayTrouble -> CatalogUiState.Failed(null)
}
