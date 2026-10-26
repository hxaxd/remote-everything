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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import com.remoteeverything.core.api.ControlResponse

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
    /** One visit to a node, including a later visit to the same node. */
    private var catalogGeneration = 0L
    private val controls = mutableMapOf<String, Long>()
    private var controlSerial = 0L

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
        val generation = ++catalogGeneration
        controls.clear()
        watchingNodeId = nodeId
        catalogJob?.cancel()
        _catalog.value = CatalogUiState.Loading
        catalogJob = scope.launch {
            while (isCurrent(nodeId, generation)) {
                refreshCatalog(currentNode(nodeId) ?: node, generation)
                delay(Cadence.catalogRefreshMs)
            }
        }
    }

    fun stopWatching() {
        catalogGeneration++
        watchingNodeId = null
        catalogJob?.cancel()
        catalogJob = null
        controls.clear()
    }

    private fun isCurrent(nodeId: String, generation: Long): Boolean =
        watchingNodeId == nodeId && catalogGeneration == generation

    private suspend fun refreshCatalog(node: Node, generation: Long) {
        if (!isCurrent(node.id, generation)) return
        val answer = fetchCatalog(node)
        if (isCurrent(node.id, generation)) {
            val previous = _catalog.value as? CatalogUiState.Ready
            _catalog.value = if (answer is CatalogUiState.Ready && previous != null) {
                CatalogUiState.Ready(answer.apps.map { app ->
                    if (controls.containsKey(app.id)) previous.apps.firstOrNull { it.id == app.id } ?: app else app
                })
            } else answer
        }
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
        val roads = nodesController.pathsFor(node, currentNetworkKey())
        if (roads.isEmpty()) return CatalogUiState.Offline
        var answer: CatalogUiState = CatalogUiState.Offline
        for (path in roads) {
            val identity = currentIdentities().firstOrNull { it.origin == path.origin } ?: continue
            val client = nodesController.clientFor(identity) ?: continue
            try {
                val outcome = CatalogOutcome.forAnswer(client.catalog(node.id)).toUiState()
                if (currentIdentities().none { it == identity }) continue
                if (outcome is CatalogUiState.Ready) {
                    nodesController.markPath(node.id, path.origin, true)
                    return outcome
                }
                answer = outcome
            } catch (e: CancellationException) {
                throw e
            } catch (e: ClientError) {
                if (currentIdentities().none { it == identity }) continue
                answer = CatalogOutcome.forRefusal(e).toUiState()
                // An answer that is not "the machine is off" is the gateway talking:
                // asking it again by another road would say the same thing.
                if (answer !is CatalogUiState.Offline) return answer
            } catch (e: Exception) {
                if (currentIdentities().none { it == identity }) continue
                answer = CatalogUiState.Offline
            }
            // This road is not answering: the next one gets the turn, and the
            // remembered choice stops pointing here.
            nodesController.markPath(node.id, path.origin, false)
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
        val generation = catalogGeneration
        if (!isCurrent(node.id, generation) || controls.containsKey(appId)) return
        val serial = ++controlSerial
        controls[appId] = serial
        applyState(node.id, generation, appId, if (start) AppState.STARTING else AppState.STOPPING)
        scope.launch {
          try {
            if (!isCurrent(node.id, generation)) return@launch
            var chosen: Pair<GatewayClient, Identity>? = null
            for (path in nodesController.pathsFor(currentNode(node.id) ?: node, currentNetworkKey())) {
                val identity = currentIdentities().firstOrNull { it.origin == path.origin } ?: continue
                val client = nodesController.clientFor(identity) ?: continue
                try {
                    val status = client.status(node.id, appId)
                    if (!isCurrent(node.id, generation) || currentIdentities().none { it == identity }) return@launch
                    if (status.code == ControlCode.COMPUTER_OFFLINE) {
                        nodesController.markPath(node.id, path.origin, false)
                        continue
                    }
                    if (status.code == ControlCode.APP_NOT_FOUND) { onNotice(R.string.error_app_gone); return@launch }
                    chosen = client to identity
                    break
                } catch (e: CancellationException) { throw e
                } catch (e: ClientError) {
                    if (!isCurrent(node.id,generation) || currentIdentities().none { it == identity }) return@launch
                    if (e.code != com.remoteeverything.core.model.ErrorCode.COMPUTER_OFFLINE) { onNotice(R.string.error_control_failed); return@launch }
                } catch (e: Exception) { }
                nodesController.markPath(node.id, path.origin, false)
            }
            if (chosen == null) {
                if (isCurrent(node.id,generation)) _catalog.value = CatalogUiState.Offline
                return@launch
            }
            val (client, identity) = chosen
            val answer = try {
                if (start) client.start(node.id, appId) else client.stop(node.id, appId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!isCurrent(node.id, generation) || currentIdentities().none { it == identity }) return@launch
                onNotice(R.string.error_control_failed)
                // A lost response is not permission to repeat a command on another route.
                pollUntilSettled(node, appId, generation)
                return@launch
            }
            if (!isCurrent(node.id, generation) || currentIdentities().none { it == identity }) return@launch
            if (!answer.ok && answer.code == ControlCode.STATE_UPDATE_FAILED) {
                onNotice(R.string.error_stop_failed)
            }
            if (answer.code == ControlCode.COMPUTER_OFFLINE) {
                _catalog.value = CatalogUiState.Offline
                return@launch
            }
            if (answer.code == ControlCode.APP_NOT_FOUND) {
                onNotice(R.string.error_app_gone)
                refreshCatalog(node, generation)
                return@launch
            }
            // Starting and stopping are not instant: the screen keeps asking until
            // the application settles, so the row never shows a state it left.
            pollUntilSettled(node, appId, generation)
          } finally {
            if (isCurrent(node.id, generation) && controls[appId] == serial) {
                controls.remove(appId)
                refreshCatalog(currentNode(node.id) ?: node, generation)
            }
          }
        }
    }

    private suspend fun pollUntilSettled(
        node: Node,
        appId: String,
        generation: Long,
    ) {
        val nodeId = node.id
        var interval = Cadence.controlPollMs
        val settled = withTimeoutOrNull(Cadence.controlPollTimeoutMs) {
          while (isCurrent(nodeId, generation)) {
            delay(interval)
            if (!isCurrent(nodeId, generation)) return@withTimeoutOrNull true
            for (path in nodesController.pathsFor(currentNode(nodeId) ?: node, currentNetworkKey())) {
              val identity = currentIdentities().firstOrNull { it.origin == path.origin } ?: continue
              val client = nodesController.clientFor(identity) ?: continue
              val status = try { client.status(nodeId, appId) } catch (e: CancellationException) { throw e
              } catch (e: Exception) { nodesController.markPath(nodeId, path.origin, false); continue }
              if (!isCurrent(nodeId, generation) || currentIdentities().none { it == identity }) return@withTimeoutOrNull true
              if (status.code == ControlCode.COMPUTER_OFFLINE) { nodesController.markPath(nodeId, path.origin, false); continue }
              if (status.code == ControlCode.APP_NOT_FOUND) { onNotice(R.string.error_app_gone); return@withTimeoutOrNull true }
              nodesController.markPath(nodeId, path.origin, true)
              stateOf(status)?.let { applyState(nodeId, generation, appId, it) }
              if (status.code == ControlCode.READY || status.code == ControlCode.STOPPED) return@withTimeoutOrNull true
              break
            }
            interval = (interval * Cadence.controlPollFactor).toLong().coerceAtMost(Cadence.controlPollCeilingMs)
          }
          true
        }
        if (settled == null && isCurrent(nodeId, generation)) onNotice(R.string.error_control_failed)
    }

    private fun stateOf(status: ControlResponse): AppState? = when (status.code) {
        ControlCode.READY -> AppState.READY
        ControlCode.STARTING -> AppState.STARTING
        ControlCode.STOPPING -> AppState.STOPPING
        ControlCode.STOPPED -> AppState.STOPPED
        else -> status.app?.toAppInfo()?.code
    }

    /** Writes one application's state into the catalog that is on screen. */
    private fun applyState(nodeId: String, generation: Long, appId: String, code: AppState) {
        if (!isCurrent(nodeId, generation)) return
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
