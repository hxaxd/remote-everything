package com.remoteeverything.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.remoteeverything.core.api.GatewayClientPool
import com.remoteeverything.core.identity.AndroidKeyStoreIdentityVault
import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.Cadence
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
    data class Success(val nodeName: String) : PairingUiState
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

/**
 * The app's single dispatcher and view model facade: coordinates the controllers,
 * holds global lifecycle, resolves web targets, and publishes consolidated UI state.
 */
class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = SettingsRepository(application)
    private val vault: IdentityVault = AndroidKeyStoreIdentityVault()
    private val pool = GatewayClientPool()
    private val updateChecker = UpdateChecker()

    private val nodesController = NodesController(
        clientFactory = { identity -> pool.deviceClient(identity, vault) },
        cache = NodeCacheStore(File(application.filesDir, "nodes/cache.json")),
    )

    private val pairingSession = PairingSession(
        scope = viewModelScope,
        pairingService = PairingService(
            vault = vault,
            transaction = SetupTransaction(File(application.filesDir, "pairing/staged.json")),
            repository = repository,
            clientFactory = { origin, pin, material ->
                if (material == null) pool.pairingClient(origin, pin)
                else com.remoteeverything.core.api.GatewayClients.device(origin, material, pin)
            },
        ),
        onNodesChanged = { refreshNodes() },
    )

    private val notice = MutableStateFlow<Int?>(null)

    private val catalogController = CatalogController(
        scope = viewModelScope,
        nodesController = nodesController,
        currentNetworkKey = ::currentNetworkKey,
        currentIdentities = { repository.currentIdentities() },
        onNotice = { notice.value = it },
    )

    private val nodes = MutableStateFlow<List<Node>>(emptyList())
    private val refreshing = MutableStateFlow(false)
    private var refreshJob: Job? = null

    val state: StateFlow<AppUiState> = combine(
        repository.settings,
        repository.identities,
        nodes,
        refreshing,
    ) { settings, identities, nodeList, isRefreshing ->
        AppUiState(settings = settings, identities = identities, nodes = nodeList, refreshing = isRefreshing)
    }.combine(pairingSession.pairing) { current, pairingState -> current.copy(pairing = pairingState) }
        .combine(catalogController.catalog) { current, catalogState -> current.copy(catalog = catalogState) }
        .combine(notice) { current, message -> current.copy(notice = message) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), AppUiState())

    val updateState = MutableStateFlow<UpdateUiState>(UpdateUiState.Idle)

    init {
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
                nodes.value = nodesController.refresh(repository.currentIdentities(), currentNetworkKey())
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

    private val networkEnv = AndroidNetworkEnvironment(application)

    fun currentNetworkKey(): String = networkEnv.currentKey()

    /** The path a node is reached by right now, which is also what the row shows. */
    fun pathFor(node: Node): Path? = nodesController.pathFor(node, currentNetworkKey())

    /** Which gateway a node is reached through right now; null when none answers. */
    fun originFor(node: Node): String? = nodesController.originFor(node, currentNetworkKey())

    fun statusOf(node: Node): NodeStatus = nodesController.statusOf(node, currentNetworkKey())

    // --- pairing -------------------------------------------------------------

    var pendingInvitation: String? = null

    fun parseInvitation(text: String): SetupUri.Invitation? = pairingSession.parseInvitation(text)

    fun pair(invitation: SetupUri.Invitation, deviceName: String) = pairingSession.pair(invitation, deviceName)

    fun cancelPairing() = pairingSession.cancelPairing()

    fun resetPairing() = pairingSession.resetPairing()

    /** A waiting device, asked about now rather than at the next poll. */
    fun resumePendingPairing() = pairingSession.resumePendingPairing()

    // --- one node's applications --------------------------------------------

    fun watchNode(node: Node) = catalogController.watchNode(node)

    fun stopWatching() = catalogController.stopWatching()

    fun control(node: Node, appId: String, start: Boolean) = catalogController.control(node, appId, start)

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
            pool.drop(identity.origin)
            nodesController.drop(identity.origin)
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
