package com.remoteeverything.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.remoteeverything.core.api.CatalogOutcome
import com.remoteeverything.core.api.ControlCode
import com.remoteeverything.core.api.GatewayClients
import com.remoteeverything.core.identity.AndroidKeyStoreIdentityVault
import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.NodeStatus
import com.remoteeverything.core.model.Path
import com.remoteeverything.core.pairing.PairingService
import com.remoteeverything.core.pairing.SetupTransaction
import com.remoteeverything.core.pathselect.NetworkEnvironment
import com.remoteeverything.core.setup.SetupUri
import com.remoteeverything.core.store.Appearance
import com.remoteeverything.core.store.Language
import com.remoteeverything.core.store.NodeCacheStore
import com.remoteeverything.core.store.Settings
import com.remoteeverything.core.store.SettingsRepository
import com.remoteeverything.core.update.UpdateChecker
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

sealed interface PairingUiState {
    data object Idle : PairingUiState
    data class Working(val nodeName: String) : PairingUiState
    data class Pending(val nodeName: String) : PairingUiState
    data class Failed(val code: ErrorCode?) : PairingUiState
}

sealed interface CatalogUiState {
    data object Loading : CatalogUiState
    data class Ready(val apps: List<AppInfo>) : CatalogUiState
    data object Offline : CatalogUiState
    data object Unauthorized : CatalogUiState
    data class Failed(val code: ErrorCode?) : CatalogUiState
}

/** What a WebView needs to open one application: the origin, and what to pin it by. */
data class OpenTarget(val url: String, val serverPin: com.remoteeverything.core.model.ServerPin?)

data class AppUiState(
    val settings: Settings = Settings(),
    val identities: List<Identity> = emptyList(),
    val nodes: List<Node> = emptyList(),
    val refreshing: Boolean = false,
    val pairing: PairingUiState = PairingUiState.Idle,
    val catalog: CatalogUiState = CatalogUiState.Loading,
    val notice: Int? = null,
)

sealed interface UpdateUiState {
    data object Idle : UpdateUiState
    data object Checking : UpdateUiState
    data object UpToDate : UpdateUiState
    data class Available(val versionName: String, val buildNumber: Int) : UpdateUiState
    data object ProtocolChanged : UpdateUiState
    data object Unreachable : UpdateUiState
}

class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = SettingsRepository(application)
    private val vault: IdentityVault = AndroidKeyStoreIdentityVault()
    private val pairingService = PairingService(
        vault = vault,
        transaction = SetupTransaction(File(application.filesDir, "pairing/staged.json")),
        repository = repository,
    )
    private val nodesController = NodesController(
        clientFactory = { identity -> GatewayClients.device(identity.origin, vault, identity.serverPin) },
        cache = NodeCacheStore(File(application.filesDir, "nodes/cache.json")),
    )
    private val updateChecker = UpdateChecker()

    private val nodes = MutableStateFlow<List<Node>>(emptyList())
    private val refreshing = MutableStateFlow(false)
    private val pairing = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    private val catalog = MutableStateFlow<CatalogUiState>(CatalogUiState.Loading)
    private val notice = MutableStateFlow<Int?>(null)

    private var catalogJob: Job? = null
    private var refreshJob: Job? = null
    private var approvalJob: Job? = null
    private var watchingNodeId: String? = null

    val state: StateFlow<AppUiState> = combine(
        repository.settings,
        repository.identities,
        nodes,
        refreshing,
    ) { settings, identities, nodeList, isRefreshing ->
        AppUiState(settings = settings, identities = identities, nodes = nodeList, refreshing = isRefreshing)
    }.combine(pairing) { current, pairingState -> current.copy(pairing = pairingState) }
        .combine(catalog) { current, catalogState -> current.copy(catalog = catalogState) }
        .combine(notice) { current, message -> current.copy(notice = message) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), AppUiState())

    val updateState = MutableStateFlow<UpdateUiState>(UpdateUiState.Idle)

    init {
        viewModelScope.launch {
            // A pairing that was interrupted is finished before anything else: the
            // invitation behind it is spent, and this is the only way it is not wasted.
            val state = askAboutPendingDevice()
            if (state != null) {
                pairing.value = state
                if (state is PairingUiState.Pending) {
                    startApprovalPolling()
                }
            }
        }
        viewModelScope.launch { refreshNodes() }
    }

    fun consumeNotice() {
        notice.value = null
    }

    fun refreshNodes() {
        if (refreshing.value) return
        refreshing.value = true
        viewModelScope.launch {
            try {
                nodes.value = nodesController.refresh(repository.currentIdentities(), NetworkEnvironment.key(getApplication()))
            } finally {
                refreshing.value = false
            }
        }
    }

    /** Started when the app comes to the front and stopped when it leaves. */
    fun startForegroundRefresh() {
        if (refreshJob?.isActive == true) return
        refreshJob = viewModelScope.launch {
            while (true) {
                delay(Cadence.nodeRefreshMs)
                refreshNodes()
            }
        }
    }

    fun stopForegroundRefresh() {
        refreshJob?.cancel()
        refreshJob = null
    }

    fun currentNetworkKey(): String = NetworkEnvironment.key(getApplication())

    /** The path a node is reached by right now, which is also what the row shows. */
    fun pathFor(node: Node): Path? = nodesController.pathFor(node, currentNetworkKey())

    /** Which gateway a node is reached through right now; null when none answers. */
    fun originFor(node: Node): String? = nodesController.originFor(node, currentNetworkKey())

    fun statusOf(node: Node): NodeStatus = nodesController.statusOf(node, currentNetworkKey())

    // --- pairing -------------------------------------------------------------

    fun parseInvitation(text: String): SetupUri.Invitation? =
        try {
            SetupUri.parse(text)
        } catch (e: Exception) {
            null
        }

    fun pair(invitation: SetupUri.Invitation, deviceName: String) {
        if (pairing.value is PairingUiState.Working) return
        pairing.value = PairingUiState.Working(invitation.nodeName)
        viewModelScope.launch {
            when (val outcome = pairingService.run(invitation, deviceName.trim())) {
                is PairingService.Outcome.Activated -> {
                    pairing.value = PairingUiState.Idle
                    refreshNodes()
                }
                is PairingService.Outcome.ApprovalPending -> {
                    pairing.value = PairingUiState.Pending(outcome.nodeName)
                    refreshNodes()
                    startApprovalPolling()
                }
                is PairingService.Outcome.Failed -> pairing.value = PairingUiState.Failed(outcome.code)
            }
        }
    }

    /**
     * One question about a device that paired and is waiting for its operator. A
     * waiting device is asked about on its own every [Cadence.approvalPollMs] for
     * [Cadence.approvalPollTimeoutMs], because waiting for somebody to tap retry is
     * not the same product as being admitted a moment after they approve.
     */
    private suspend fun askAboutPendingDevice(): PairingUiState? =
        when (val outcome = pairingService.resume()) {
            null -> null
            is PairingService.Outcome.Activated -> {
                refreshNodes()
                PairingUiState.Idle
            }
            is PairingService.Outcome.ApprovalPending -> PairingUiState.Pending(outcome.nodeName)
            is PairingService.Outcome.Failed -> PairingUiState.Failed(outcome.code)
        }

    private fun startApprovalPolling() {
        if (approvalJob?.isActive == true) return
        approvalJob = viewModelScope.launch {
            val deadline = System.currentTimeMillis() + Cadence.approvalPollTimeoutMs
            while (System.currentTimeMillis() < deadline) {
                delay(Cadence.approvalPollMs)
                when (val state = askAboutPendingDevice()) {
                    null -> return@launch
                    is PairingUiState.Pending -> pairing.value = state
                    else -> {
                        pairing.value = state
                        return@launch
                    }
                }
            }
        }
    }

    fun resetPairing() {
        if (pairing.value !is PairingUiState.Working) {
            pairing.value = PairingUiState.Idle
        }
    }

    /** A waiting device, asked about now rather than at the next poll. */
    fun resumePendingPairing() {
        viewModelScope.launch {
            val state = askAboutPendingDevice()
            if (state != null) {
                pairing.value = state
                if (state !is PairingUiState.Pending) {
                    approvalJob?.cancel()
                }
            }
        }
    }

    // --- one node's applications --------------------------------------------

    fun watchNode(node: Node) {
        if (watchingNodeId == node.id && catalogJob?.isActive == true) return
        watchingNodeId = node.id
        catalogJob?.cancel()
        catalog.value = CatalogUiState.Loading
        catalogJob = viewModelScope.launch {
            while (true) {
                catalog.value = fetchCatalog(node)
                delay(Cadence.catalogRefreshMs)
            }
        }
    }

    fun stopWatching() {
        catalogJob?.cancel()
        catalogJob = null
        watchingNodeId = null
    }

    private suspend fun fetchCatalog(node: Node): CatalogUiState {
        val path = nodesController.choosePath(node, currentNetworkKey()) ?: return CatalogUiState.Offline
        val identity = repository.currentIdentities().firstOrNull { it.origin == path.origin }
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
        viewModelScope.launch {
            val path = nodesController.choosePath(node, currentNetworkKey()) ?: return@launch
            val identity = repository.currentIdentities().firstOrNull { it.origin == path.origin } ?: return@launch
            val client = nodesController.clientFor(identity) ?: return@launch
            val answer = try {
                if (start) client.start(node.id, appId) else client.stop(node.id, appId)
            } catch (e: Exception) {
                notice.value = R.string.error_control_failed
                return@launch
            }
            if (!answer.ok && answer.code == ControlCode.STATE_UPDATE_FAILED) {
                notice.value = R.string.error_stop_failed
            }
            // Starting and stopping are not instant: the screen keeps asking until
            // the application settles, so the row never shows a state it left.
            pollUntilSettled(client, node.id, appId)
            catalog.value = fetchCatalog(node)
        }
    }

    private suspend fun pollUntilSettled(
        client: com.remoteeverything.core.api.ApiClient,
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

    /** Where the WebView is sent: the application's own origin, with the pin that origin must satisfy. */
    suspend fun open(node: Node, appId: String): OpenTarget? {
        val path = nodesController.choosePath(node, currentNetworkKey()) ?: return null
        val identity = repository.currentIdentities().firstOrNull { it.origin == path.origin } ?: return null
        val client = nodesController.clientFor(identity) ?: return null
        return try {
            val url = client.open(node.id, appId)
            OpenTarget(url = url, serverPin = identity.serverPin)
        } catch (e: Exception) {
            null
        }
    }

    // --- connections ---------------------------------------------------------

    fun forget(identity: Identity) {
        viewModelScope.launch {
            vault.delete(identity.origin)
            repository.saveIdentities(repository.currentIdentities().filterNot { it.origin == identity.origin })
            refreshNodes()
        }
    }

    // --- settings and updates ------------------------------------------------

    fun setLanguage(language: Language) {
        LocaleHelper.persistOverride(getApplication(), language)
        viewModelScope.launch { repository.setLanguage(language) }
    }

    fun setAppearance(appearance: Appearance) {
        viewModelScope.launch { repository.setAppearance(appearance) }
    }

    fun checkUpdates() {
        if (updateState.value == UpdateUiState.Checking) return
        updateState.value = UpdateUiState.Checking
        viewModelScope.launch {
            updateState.value = when (
                val result = updateChecker.check(BuildConfig.VERSION_CODE, BuildConfig.PROTOCOL_VERSION)
            ) {
                is UpdateChecker.Result.UpToDate -> UpdateUiState.UpToDate
                is UpdateChecker.Result.Available -> UpdateUiState.Available(result.versionName, result.buildNumber)
                is UpdateChecker.Result.ProtocolChanged -> UpdateUiState.ProtocolChanged
                is UpdateChecker.Result.Unreachable -> UpdateUiState.Unreachable
            }
        }
    }
}

private fun CatalogOutcome.toUiState(): CatalogUiState = when (this) {
    is CatalogOutcome.Apps -> CatalogUiState.Ready(apps)
    CatalogOutcome.Offline -> CatalogUiState.Offline
    CatalogOutcome.Unauthorized -> CatalogUiState.Unauthorized
    CatalogOutcome.GatewayTrouble -> CatalogUiState.Failed(null)
}
