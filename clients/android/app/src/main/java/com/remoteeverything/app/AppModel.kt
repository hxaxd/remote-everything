package com.remoteeverything.app

import com.remoteeverything.app.i18n.LocaleHelper
import com.remoteeverything.app.i18n.l10n
import android.app.Application
import android.net.Network
import android.net.ConnectivityManager
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.remoteeverything.core.api.GatewayClientPool
import com.remoteeverything.core.diag.LinkReportInput
import com.remoteeverything.core.diag.LinkTrouble
import com.remoteeverything.core.diag.buildLinkReport
import com.remoteeverything.core.identity.AndroidKeyStoreIdentityVault
import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.model.AppInfo
import com.remoteeverything.core.model.Cadence
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.LinkKind
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.Node
import com.remoteeverything.core.model.NodeStatus
import com.remoteeverything.core.model.Path
import com.remoteeverything.core.pairing.PairingService
import com.remoteeverything.core.pairing.SetupTransaction
import com.remoteeverything.core.pathselect.AndroidNetworkEnvironment
import com.remoteeverything.core.pathselect.NetworkEnvironment
import com.remoteeverything.core.setup.SetupUri
import com.remoteeverything.core.store.Appearance
import com.remoteeverything.core.store.Language
import com.remoteeverything.core.store.NodeCacheStore
import com.remoteeverything.core.store.Settings
import com.remoteeverything.core.store.SettingsStore
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
    data class Failed(val code: ErrorCode?, val key: String? = null) : PairingUiState
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
    /** Per connection origin, why it is not answering — empty for one that answers. */
    val trouble: Map<String, LinkTrouble> = emptyMap(),
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
class AppModel(application: Application) : AndroidViewModel(application) {

    private val repository = SettingsStore(application)
    private val vault: IdentityVault = AndroidKeyStoreIdentityVault()
    private val pool = GatewayClientPool()
    private val updateChecker = UpdateChecker()

    private val nodesController = NodesController(
        clientFactory = { identity -> pool.deviceClient(identity, vault) },
        cache = NodeCacheStore(File(application.filesDir, "nodes/cache.json")),
        // A phone with nothing to send on fails every connection the same way, and
        // saying so is more use than naming the first exception that came out.
        offline = { networkEnv.offline() },
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
        // What one node looks like *now*: its paths carry the reachability of the
        // last probe, and a screen holding yesterday's answer would hold a dead
        // path (NodesController.refresh).
        currentNode = { id -> nodes.value.firstOrNull { node -> node.id == id } },
        onNotice = { notice.value = it },
    )

    private val nodes = MutableStateFlow<List<Node>>(emptyList())
    private val refreshing = MutableStateFlow(false)
    private var refreshJob: Job? = null
    private var refreshInFlight: Job? = null

    val state: StateFlow<AppUiState> = combine(
        repository.settings,
        repository.identities,
        nodes,
        refreshing,
        nodesController.trouble,
    ) { settings, identities, nodeList, isRefreshing, trouble ->
        AppUiState(
            settings = settings,
            identities = identities,
            nodes = nodeList,
            refreshing = isRefreshing,
            trouble = trouble,
        )
    }.combine(pairingSession.pairing) { current, pairingState -> current.copy(pairing = pairingState) }
        .combine(catalogController.catalog) { current, catalogState -> current.copy(catalog = catalogState) }
        .combine(notice) { current, message -> current.copy(notice = message) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), AppUiState())

    val updateState = MutableStateFlow<UpdateUiState>(UpdateUiState.Idle)

    init {
        viewModelScope.launch { refreshNodes() }
        watchTheNetwork()
    }

    fun consumeNotice() {
        notice.value = null
    }

    /**
     * The phone changing networks is the phone asking a new question.
     *
     * A device that walks out of its Wi-Fi has not lost its machines: it has lost
     * one way to them, and the other way is a tunnel it is still holding. Waiting
     * for the next tick would leave the screen saying "offline" for a minute on a
     * phone that is on the internet the whole time, so a change of network is
     * answered at once: the list is read again and whatever node is on screen is
     * asked again, which is also how the choice of path gets recomputed.
     */
    private fun watchTheNetwork() {
        val manager = getApplication<Application>().getSystemService(ConnectivityManager::class.java)
            ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = networkChanged()
            override fun onLost(network: Network) = networkChanged()
            private fun networkChanged() = this@AppModel.networkChanged()
        }
        runCatching { manager.registerDefaultNetworkCallback(callback) }
            .onSuccess { networkCallback = callback }
    }

    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    fun networkChanged() {
        // The chosen path belongs to the network that is gone: it is retired here so
        // the next look re-decides between what is left.
        nodes.value.forEach { node -> nodesController.dropChoice(node.id) }
        refreshNodes(force = true)
        catalogController.recheckNow()
    }

    override fun onCleared() {
        networkCallback?.let { callback ->
            getApplication<Application>().getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(callback)
        }
        super.onCleared()
    }

    fun refreshNodes(force: Boolean = false) {
        if (refreshing.value && !force) return
        // A forced refresh preempts the refresh in flight, not the foreground
        // loop: refreshJob is the periodic cadence, and canceling it would
        // leave the phone without its tick until it next comes to the front.
        if (force) refreshInFlight?.cancel()
        refreshing.value = true
        refreshInFlight = viewModelScope.launch {
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
            // Fresh on arrival, then on the cadence: the person who just came back
            // did not wait a minute to see what changed while they were away.
            refreshNodes()
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

    /**
     * An invitation link waiting for the pair screen, as a one-shot event: the
     * deep link stages it, the navigation observes it, and the pair screen
     * consumes it. A plain field here was what re-opened the pair screen after
     * every recreation — language switches included — with the last link
     * filled in.
     */
    private val mutablePendingInvitation = MutableStateFlow<String?>(null)
    val pendingInvitation: StateFlow<String?> = mutablePendingInvitation

    fun stageInvitation(invitation: String) {
        mutablePendingInvitation.value = invitation
    }

    fun consumeInvitation() {
        mutablePendingInvitation.value = null
    }

    fun parseInvitation(text: String): SetupUri.Invitation? = pairingSession.parseInvitation(text)

    fun pair(invitation: SetupUri.Invitation, deviceName: String) = pairingSession.pair(invitation, deviceName)

    fun cancelPairing() = pairingSession.cancelPairing()

    fun resetPairing() = pairingSession.resetPairing()

    /** A waiting device, asked about now rather than at the next poll. */
    fun resumePendingPairing() = pairingSession.resumePendingPairing()

    // --- one node's applications --------------------------------------------

    fun watchNode(node: Node) = catalogController.watchNode(node)

    /**
     * A person asking again, from a screen that says something is unreachable: the
     * node list is read again — the paths it carries are what a catalog is fetched
     * through — and this node's catalog with it, now rather than at the next tick.
     */
    fun retryNode(node: Node) {
        refreshNodes()
        catalogController.watchNode(node, force = true)
    }

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

    /**
     * The report a person copies out of a connection that will not answer.
     *
     * It is built here rather than on the screen because most of it is not on the
     * screen: what the last few probes failed with, when this connection last
     * answered, and which road each machine was reachable by. The strings come from
     * the app's own locale (`LocaleHelper.wrap`), so the report reads the way the
     * rest of the app does.
     */
    fun troubleReport(identity: Identity): String {
        val trouble = nodesController.trouble.value[identity.origin] ?: return ""
        val context = LocaleHelper.wrap(getApplication())
        val say: (String, String?) -> String = { key, arg ->
            if (arg == null) l10n(context, key) else l10n(context, key, arg)
        }
        val machines = nodes.value
            .filter { node -> node.paths.any { it.origin == identity.origin } }
            .map { node ->
                val roads = node.paths
                    .filter { it.origin == identity.origin }
                    .joinToString(" ") { path ->
                        val label = say(
                            if (path.link == LinkKind.LOCAL) MessageKeys.NODE_LAN else MessageKeys.NODE_TUNNEL,
                            null,
                        )
                        val mark = if (path.reachable == true) "✓" else "✗"
                        val latency = path.latencyMs?.takeIf { path.reachable == true }?.let { " ${it}ms" }.orEmpty()
                        "$label $mark$latency"
                    }
                "${node.name} $roads"
            }
        return buildLinkReport(
            LinkReportInput(
                appName = say(MessageKeys.APP_NAME, null),
                client = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                protocol = "${BuildConfig.PROTOCOL_VERSION}",
                system = "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · ${Build.MODEL}",
                origin = identity.origin,
                deviceName = identity.deviceName,
                network = networkEnv.describe(),
                machines = machines,
                trouble = trouble,
                attempts = nodesController.failedProbesFor(identity.origin),
                time = ::formatStamp,
            ),
            say,
        )
    }

    private fun formatStamp(at: Long): String =
        java.text.SimpleDateFormat("MM-dd HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date(at))

    fun forget(identity: Identity) {
        // The pairing still staged for this gateway is part of what is being
        // forgotten — its resume file and its approval polling go with the
        // identity (behavior README: forgetting leaves no half-pairing).
        pairingSession.forget(identity.origin)
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
