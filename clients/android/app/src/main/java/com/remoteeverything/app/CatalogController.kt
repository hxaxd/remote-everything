package com.remoteeverything.app

import com.remoteeverything.core.api.ApiClient
import com.remoteeverything.core.api.CatalogOutcome
import com.remoteeverything.core.api.ControlCode
import com.remoteeverything.core.model.AppInfo
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
    private val onNotice: (Int) -> Unit,
) {
    private val _catalog = MutableStateFlow<CatalogUiState>(CatalogUiState.Loading)
    val catalog: StateFlow<CatalogUiState> = _catalog.asStateFlow()

    private var catalogJob: Job? = null
    private var watchingNodeId: String? = null

    fun watchNode(node: Node) {
        if (watchingNodeId == node.id && catalogJob?.isActive == true) return
        watchingNodeId = node.id
        catalogJob?.cancel()
        _catalog.value = CatalogUiState.Loading
        catalogJob = scope.launch {
            while (true) {
                _catalog.value = fetchCatalog(node)
                delay(Cadence.catalogRefreshMs)
            }
        }
    }

    fun stopWatching() {
        catalogJob?.cancel()
        catalogJob = null
        watchingNodeId = null
    }

    suspend fun fetchCatalog(node: Node): CatalogUiState {
        val path = nodesController.choosePath(node, currentNetworkKey()) ?: return CatalogUiState.Offline
        val identity = currentIdentities().firstOrNull { it.origin == path.origin }
            ?: return CatalogUiState.Unauthorized
        val client = nodesController.clientFor(identity) ?: return CatalogUiState.Unauthorized
        return try {
            CatalogOutcome.forAnswer(client.catalog(node.id)).toUiState()
        } catch (e: ClientError) {
            CatalogOutcome.forRefusal(e).toUiState()
        } catch (e: Exception) {
            CatalogUiState.Offline
        }
    }

    fun control(node: Node, appId: String, start: Boolean) {
        scope.launch {
            val path = nodesController.choosePath(node, currentNetworkKey()) ?: return@launch
            val identity = currentIdentities().firstOrNull { it.origin == path.origin } ?: return@launch
            val client = nodesController.clientFor(identity) ?: return@launch
            val answer = try {
                if (start) client.start(node.id, appId) else client.stop(node.id, appId)
            } catch (e: Exception) {
                onNotice(R.string.error_control_failed)
                return@launch
            }
            if (!answer.ok && answer.code == ControlCode.STATE_UPDATE_FAILED) {
                onNotice(R.string.error_stop_failed)
            }
            // Starting and stopping are not instant: the screen keeps asking until
            // the application settles, so the row never shows a state it left.
            pollUntilSettled(client, node.id, appId)
            _catalog.value = fetchCatalog(node)
        }
    }

    private suspend fun pollUntilSettled(
        client: ApiClient,
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
            if (status.code == ControlCode.READY || status.code == ControlCode.STOPPED) return
            interval = (interval * Cadence.controlPollFactor).toLong().coerceAtMost(Cadence.controlPollCeilingMs)
        }
    }
}

private fun CatalogOutcome.toUiState(): CatalogUiState = when (this) {
    is CatalogOutcome.Apps -> CatalogUiState.Ready(apps)
    CatalogOutcome.Offline -> CatalogUiState.Offline
    CatalogOutcome.Unauthorized -> CatalogUiState.Unauthorized
    CatalogOutcome.GatewayTrouble -> CatalogUiState.Failed(null)
}
