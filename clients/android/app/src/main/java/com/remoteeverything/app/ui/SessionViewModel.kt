package com.remoteeverything.app.ui

import android.app.Application
import android.content.Context
import android.os.Build
import android.os.SystemClock
import com.remoteeverything.app.AppUpdater
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.remoteeverything.app.AppConfig
import com.remoteeverything.app.BuildConfig
import com.remoteeverything.app.CatalogSnapshot
import com.remoteeverything.app.ClientIdentity
import com.remoteeverything.app.ConnectionConfig
import com.remoteeverything.app.DeviceAuthorizationException
import com.remoteeverything.app.DeviceIdentity
import com.remoteeverything.app.RemoteApi
import com.remoteeverything.app.RemoteApp
import com.remoteeverything.app.SettingsStore
import com.remoteeverything.app.SetupPayload
import com.remoteeverything.app.SetupState
import com.remoteeverything.app.SetupTransaction
import com.remoteeverything.app.InstallLaunchResult
import com.remoteeverything.app.UpdateProtocol
import com.remoteeverything.app.UpdateUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** 启动决策:决定首次进入哪个界面。 */
sealed interface StartState {
    data object Loading : StartState
    data object NoProfile : StartState
    data class PendingActivation(val config: ConnectionConfig) : StartState
    data class Ready(val config: ConnectionConfig) : StartState
}

/** 应用目录状态。 */
sealed interface CatalogUiState {
    data object Loading : CatalogUiState
    data class Ready(val snapshot: CatalogSnapshot) : CatalogUiState
    data class Error(val detail: String) : CatalogUiState
}

/**
 * 会话级状态:活动连接、目录轮询、初始化向导。
 * 取代旧 MainActivity 的 screenGeneration/Handler 状态机。
 */
class SessionViewModel(application: Application) : AndroidViewModel(application) {
    val settings = SettingsStore(application)
    val identity = DeviceIdentity(application)
    private val setupTransaction = SetupTransaction(settings, identity, "${Build.MANUFACTURER} ${Build.MODEL} · Android")
    private val appUpdater = AppUpdater(application)

    private val _startState = MutableStateFlow<StartState>(StartState.Loading)
    val startState = _startState.asStateFlow()

    private val _activeProfile = MutableStateFlow<ConnectionConfig?>(null)
    val activeProfile = _activeProfile.asStateFlow()

    private val _profiles = MutableStateFlow<List<ConnectionConfig>>(emptyList())
    val profiles = _profiles.asStateFlow()

    private val _catalog = MutableStateFlow<CatalogUiState>(CatalogUiState.Loading)
    val catalog = _catalog.asStateFlow()

    private val _catalogRefreshing = MutableStateFlow(false)
    val catalogRefreshing = _catalogRefreshing.asStateFlow()

    /** 向导当前状态;null 表示不在向导中。 */
    private val _setupState = MutableStateFlow<SetupState?>(null)
    val setupState = _setupState.asStateFlow()

    /** 一次性提示(授权失效、操作失败等),由界面以 Snackbar 展示。 */
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages = _messages.asSharedFlow()

    private val _themeMode = MutableStateFlow(settings.themeMode())
    val themeMode = _themeMode.asStateFlow()

    private val _updateState = MutableStateFlow<UpdateUiState>(UpdateUiState.Idle)
    val updateState = _updateState.asStateFlow()

    private var catalogJob: Job? = null
    private var setupJob: Job? = null
    private var updateJob: Job? = null
    private var setupPayload: SetupPayload? = null
    private var bootstrapped = false
    private var lastErrorNotifyAt = 0L
    private var catalogOfflineSince = 0L

    fun bootstrap() {
        if (bootstrapped) return
        bootstrapped = true
        // bootstrap 在每个应用进程中只执行一次，因此自动检查不会因界面重组或导航重复触发。
        checkForUpdate()
        _profiles.value = settings.profiles()
        val pending = setupTransaction.recover()
        val active = settings.activeProfile()?.takeIf { it.mode != "public" || identity.hasCredential(it.installationId) }
        when {
            pending != null -> _startState.value = StartState.PendingActivation(pending)
            active == null -> _startState.value = StartState.NoProfile
            else -> {
                _activeProfile.value = active
                _startState.value = StartState.Ready(active)
                startCatalogPolling()
            }
        }
    }

    fun clientIdentityOf(config: ConnectionConfig): ClientIdentity? =
        if (config.mode == "public") identity.clientIdentity(config.installationId) else null

    // ---- 目录 ----

    private fun startCatalogPolling() {
        catalogJob?.cancel()
        _catalogRefreshing.value = false
        catalogOfflineSince = 0L
        val config = _activeProfile.value ?: return
        _catalog.value = CatalogUiState.Loading
        catalogJob = viewModelScope.launch {
            while (isActive) {
                val result = withContext(Dispatchers.IO) {
                    runCatching { RemoteApi.catalog(config, clientIdentityOf(config)) }
                }
                result.onSuccess { snapshot ->
                    publishCatalog(snapshot)
                }.onFailure { error ->
                    val cause = generateSequence(error) { it.cause }.last()
                    if (cause is DeviceAuthorizationException) {
                        handleAuthorizationRevoked(config)
                        return@launch
                    }
                    // 瞬时失败不清屏:已有数据保留展示,提示后由下一轮轮询恢复
                    if (_catalog.value is CatalogUiState.Ready) {
                        notifyTransientError()
                    } else {
                        val detail = cause.message?.takeIf(String::isNotBlank) ?: cause.javaClass.simpleName
                        _catalog.value = CatalogUiState.Error(detail)
                    }
                }
                delay(5_000)
            }
        }
    }

    fun refreshCatalog() {
        val config = _activeProfile.value ?: return
        if (_catalogRefreshing.value) return
        _catalogRefreshing.value = true
        viewModelScope.launch {
            try {
                val result = withTimeoutOrNull(15_000) {
                    withContext(Dispatchers.IO) {
                        runCatching { RemoteApi.catalog(config, clientIdentityOf(config)) }
                    }
                }
                if (result == null) {
                    notifyTransientError()
                    return@launch
                }
                result.onSuccess {
                    if (_activeProfile.value?.installationId == config.installationId) {
                        publishCatalog(it)
                    }
                }.onFailure { error ->
                    val cause = generateSequence(error) { it.cause }.last()
                    if (cause is DeviceAuthorizationException) handleAuthorizationRevoked(config)
                    else if (_catalog.value is CatalogUiState.Ready) notifyTransientError()
                }
            } finally {
                _catalogRefreshing.value = false
            }
        }
    }

    private fun notifyTransientError() {
        val now = System.currentTimeMillis()
        if (now - lastErrorNotifyAt < 30_000) return
        lastErrorNotifyAt = now
        _messages.tryEmit("连接失败,稍后自动重试")
    }

    /** 已经拿到目录后，短暂的隧道拥塞不清空界面；持续离线 30 秒后才切换为离线状态。 */
    private fun publishCatalog(snapshot: CatalogSnapshot) {
        if (snapshot.computerConnected) {
            catalogOfflineSince = 0L
            _catalog.value = CatalogUiState.Ready(snapshot)
            return
        }
        val current = (_catalog.value as? CatalogUiState.Ready)?.snapshot
        if (current?.computerConnected == true) {
            val now = SystemClock.elapsedRealtime()
            if (catalogOfflineSince == 0L) catalogOfflineSince = now
            if (now - catalogOfflineSince < CATALOG_OFFLINE_GRACE_MS) {
                notifyTransientError()
                return
            }
        }
        _catalog.value = CatalogUiState.Ready(snapshot)
    }

    fun controlApp(app: RemoteApp, action: String) {
        val config = _activeProfile.value ?: return
        viewModelScope.launch {
            val success = withContext(Dispatchers.IO) {
                runCatching { RemoteApi.control(config, clientIdentityOf(config), app.id, action) }.getOrDefault(false)
            }
            if (!success) _messages.tryEmit("操作失败,请稍后重试")
            refreshCatalog()
        }
    }

    private fun handleAuthorizationRevoked(config: ConnectionConfig) {
        identity.removeCredential(config.installationId)
        settings.removeProfile(config.installationId)
        _profiles.value = settings.profiles()
        if (_activeProfile.value?.installationId == config.installationId) {
            catalogJob?.cancel()
            _catalogRefreshing.value = false
            catalogOfflineSince = 0L
            _activeProfile.value = null
        }
        _messages.tryEmit("设备授权已失效,请重新初始化")
    }

    // ---- 连接管理 ----

    fun selectProfile(config: ConnectionConfig) {
        settings.setActiveProfile(config.installationId)
        _activeProfile.value = config
        startCatalogPolling()
    }

    fun deleteProfile(config: ConnectionConfig) {
        identity.removeCredential(config.installationId)
        settings.removeProfile(config.installationId)
        _profiles.value = settings.profiles()
        if (_activeProfile.value?.installationId == config.installationId) {
            catalogJob?.cancel()
            _catalogRefreshing.value = false
            catalogOfflineSince = 0L
            _activeProfile.value = null
        }
    }

    // ---- 初始化向导 ----

    /** 解析初始化链接/二维码内容并开始向导;解析失败返回错误文案。 */
    fun beginSetup(value: String): String? {
        val payload = runCatching { AppConfig.parseSetup(value) }.getOrElse {
            return it.message ?: "初始化链接无效"
        }
        setupPayload = payload
        runSetup(payload.profile) { callback -> setupTransaction.begin(payload, callback) }
        return null
    }

    /** 恢复待激活(启动时发现有 staged profile)。 */
    fun resumeActivation(config: ConnectionConfig) {
        setupPayload = null
        runSetup(config, SetupState.Activating(config)) { callback -> setupTransaction.retryActivation(config, callback) }
    }

    fun retrySetup() {
        val state = _setupState.value as? SetupState.Failed ?: return
        when (state.action) {
            com.remoteeverything.app.SetupAction.RETRY_PAIRING -> {
                val payload = setupPayload ?: return cancelSetup()
                runSetup(state.config, SetupState.Pairing(state.config)) { callback -> setupTransaction.retryPairing(payload, callback) }
            }
            com.remoteeverything.app.SetupAction.RETRY_ACTIVATION ->
                runSetup(state.config, SetupState.Activating(state.config)) { callback -> setupTransaction.retryActivation(state.config, callback) }
            com.remoteeverything.app.SetupAction.RESTART_SETUP -> cancelSetup()
        }
    }

    fun setThemeMode(value: String) {
        settings.setThemeMode(value)
        _themeMode.value = value
    }

    // ---- 应用更新 ----

    fun checkForUpdate() {
        if (updateJob?.isActive == true) return
        _updateState.value = UpdateUiState.Checking
        updateJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { appUpdater.checkLatest() } }
            result.onSuccess { release ->
                val comparison = UpdateProtocol.compareVersions(release.versionName, BuildConfig.VERSION_NAME)
                _updateState.value = if (comparison > 0) {
                    UpdateUiState.Available(release, appUpdater.isOfficialInstall())
                } else {
                    UpdateUiState.Current(release.versionName, currentIsNewer = comparison < 0)
                }
            }.onFailure { error ->
                _updateState.value = UpdateUiState.Error(error.message?.takeIf(String::isNotBlank) ?: "检查更新失败")
            }
        }
    }

    fun downloadUpdate() {
        val available = _updateState.value as? UpdateUiState.Available ?: return
        if (!available.installable || updateJob?.isActive == true) return
        val release = available.release
        _updateState.value = UpdateUiState.Downloading(release, 0f)
        updateJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    appUpdater.downloadAndVerify(release) { progress ->
                        _updateState.value = UpdateUiState.Downloading(release, progress)
                    }
                }
            }
            result.onSuccess { path ->
                _updateState.value = UpdateUiState.Ready(release, path)
            }.onFailure { error ->
                _updateState.value = UpdateUiState.Error(error.message?.takeIf(String::isNotBlank) ?: "更新下载失败")
            }
        }
    }

    fun installUpdate(context: Context) {
        val ready = _updateState.value as? UpdateUiState.Ready ?: return
        runCatching { appUpdater.launchInstaller(context, ready.release, ready.filePath) }
            .onSuccess { result ->
                if (result == InstallLaunchResult.PERMISSION_SETTINGS_OPENED) {
                    _messages.tryEmit("请允许此应用安装更新，返回后再次点击安装")
                }
            }
            .onFailure { error ->
                _updateState.value = UpdateUiState.Error(error.message?.takeIf(String::isNotBlank) ?: "无法打开安装界面")
            }
    }

    fun cancelSetup() {
        setupJob?.cancel()
        setupJob = null
        setupPayload = null
        setupTransaction.discardPending()
        _setupState.value = null
    }

    /** 向导完成:先广播 Ready 让界面收尾,再提交为活动连接并开始目录轮询。 */
    private fun completeSetup(config: ConnectionConfig) {
        setupJob = null
        setupPayload = null
        _setupState.value = SetupState.Ready(config)
        _profiles.value = settings.profiles()
        _activeProfile.value = config
        _startState.value = StartState.Ready(config)
        startCatalogPolling()
    }

    private fun runSetup(
        config: ConnectionConfig,
        initial: SetupState = if (setupPayload == null) SetupState.Activating(config) else SetupState.Pairing(config),
        operation: ((SetupState) -> Unit) -> SetupState,
    ) {
        setupJob?.cancel()
        _setupState.value = initial
        setupJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    operation { state -> _setupState.value = state }
                }.getOrElse { error ->
                    val cause = generateSequence(error) { it.cause }.last()
                    SetupState.Failed(config, cause.message ?: "初始化失败", com.remoteeverything.app.SetupAction.RESTART_SETUP)
                }
            }
            if (!isActive) return@launch
            when (result) {
                is SetupState.Ready -> completeSetup(result.config)
                is SetupState.AwaitingApproval -> {
                    _setupState.value = result
                    // 与旧行为一致:等待批准期间每 2 秒自动重试激活
                    delay(2_000)
                    if (isActive && _setupState.value === result) {
                        runSetup(result.config, SetupState.Activating(result.config, result.pendingExpiresAt)) { callback ->
                            setupTransaction.retryActivation(result.config, callback)
                        }
                    }
                }
                else -> _setupState.value = result
            }
        }
    }

    private companion object {
        const val CATALOG_OFFLINE_GRACE_MS = 30_000L
    }
}
