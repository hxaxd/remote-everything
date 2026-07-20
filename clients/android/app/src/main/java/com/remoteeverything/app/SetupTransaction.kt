package com.remoteeverything.app

import org.json.JSONObject

interface SetupProfileStore {
    fun stagedProfile(): ConnectionConfig?
    fun stageProfile(value: ConnectionConfig)
    fun commitStagedProfile(): ConnectionConfig
    fun discardStagedProfile()
}

interface SetupIdentityStore {
    fun credentialPassword(installationId: String): String
    fun stageCredential(installationId: String, encoded: String, password: String, expectedFingerprint: String)
    fun stagedClientIdentity(installationId: String): ClientIdentity
    fun promoteCredential(installationId: String)
    fun hasStagedCredential(installationId: String): Boolean
    fun discardStagedCredential(installationId: String)
}

interface SetupTransport {
    fun verifyCatalog(config: ConnectionConfig)
    fun request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity? = null,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
    ): HttpResult
}

enum class SetupAction {
    RETRY_PAIRING,
    RETRY_ACTIVATION,
    RESTART_SETUP,
}

sealed interface SetupState {
    val config: ConnectionConfig

    data class Pairing(override val config: ConnectionConfig) : SetupState
    data class Activating(
        override val config: ConnectionConfig,
        val pendingExpiresAt: String? = null,
    ) : SetupState
    data class AwaitingApproval(
        override val config: ConnectionConfig,
        val pendingExpiresAt: String? = null,
    ) : SetupState
    data class Ready(override val config: ConnectionConfig) : SetupState
    data class Failed(
        override val config: ConnectionConfig,
        val message: String,
        val action: SetupAction,
    ) : SetupState
}

private object ProductionSetupTransport : SetupTransport {
    override fun verifyCatalog(config: ConnectionConfig) = RemoteApi.verifyCatalog(config, null)

    override fun request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity?,
        headers: Map<String, String>,
        body: String?,
    ): HttpResult = SecureHttp.request(config, url, method, identity, headers, body)
}

private fun codePointPrefix(value: String, maximum: Int): String {
    if (value.codePointCount(0, value.length) <= maximum) return value
    return value.substring(0, value.offsetByCodePoints(0, maximum))
}

private fun failureDetail(error: Throwable, fallback: String): String {
    val cause = generateSequence(error) { it.cause }.last()
    return cause.message?.takeIf(String::isNotBlank) ?: fallback
}

class SetupTransaction(
    private val settings: SetupProfileStore,
    private val identity: SetupIdentityStore,
    private val deviceName: String,
    private val transport: SetupTransport = ProductionSetupTransport,
) {
    fun recover(): ConnectionConfig? {
        val staged = settings.stagedProfile() ?: return null
        if (staged.mode == "public" && identity.hasStagedCredential(staged.installationId)) return staged
        identity.discardStagedCredential(staged.installationId)
        settings.discardStagedProfile()
        return null
    }

    fun begin(setup: SetupPayload, onState: (SetupState) -> Unit = {}): SetupState {
        discardPending()
        return if (setup.profile.mode == "lan") connectLan(setup.profile, onState) else pair(setup, onState)
    }

    fun retryPairing(setup: SetupPayload, onState: (SetupState) -> Unit = {}): SetupState = pair(setup, onState)

    fun retryActivation(config: ConnectionConfig, onState: (SetupState) -> Unit = {}): SetupState = activate(config, null, onState)

    fun discardPending() {
        val staged = settings.stagedProfile() ?: return
        identity.discardStagedCredential(staged.installationId)
        settings.discardStagedProfile()
    }

    private fun connectLan(config: ConnectionConfig, onState: (SetupState) -> Unit): SetupState {
        onState(SetupState.Pairing(config))
        return runCatching {
            transport.verifyCatalog(config)
            settings.stageProfile(config)
            val committed = settings.commitStagedProfile()
            settings.discardStagedProfile()
            SetupState.Ready(committed)
        }.getOrElse {
            discardPending()
            SetupState.Failed(config, failureDetail(it, "局域网连接验证失败"), SetupAction.RESTART_SETUP)
        }
    }

    private fun pair(setup: SetupPayload, onState: (SetupState) -> Unit): SetupState {
        val config = setup.profile
        onState(SetupState.Pairing(config))
        settings.stageProfile(config)
        val password = runCatching { identity.credentialPassword(config.installationId) }.getOrElse {
            discardPending()
            return SetupState.Failed(config, failureDetail(it, "无法创建设备身份"), SetupAction.RESTART_SETUP)
        }
        val body = JSONObject()
            .put("device_name", codePointPrefix(deviceName, 80))
            .put("credential_password", password)
            .toString()
        val response = runCatching {
            transport.request(
                config,
                config.pairUrl,
                "POST",
                headers = mapOf("Authorization" to "Invitation ${setup.invitation}"),
                body = body,
            )
        }.getOrElse {
            return SetupState.Failed(config, failureDetail(it, "无法连接配对服务"), SetupAction.RETRY_PAIRING)
        }
        if (response.status == 401) {
            discardPending()
            return SetupState.Failed(config, "邀请不可用、已过期或已被使用", SetupAction.RESTART_SETUP)
        }
        if (response.status != 200) {
            return SetupState.Failed(config, "配对服务返回 ${response.status}", SetupAction.RETRY_PAIRING)
        }
        val credential = runCatching { RemoteApi.decodePairingCredential(response.json()) }.getOrElse {
            return SetupState.Failed(config, failureDetail(it, "配对响应无效"), SetupAction.RETRY_PAIRING)
        }
        runCatching {
            identity.stageCredential(
                config.installationId,
                credential.encoded,
                password,
                credential.fingerprint,
            )
        }.onFailure {
            discardPending()
            return SetupState.Failed(config, failureDetail(it, "设备身份保存失败"), SetupAction.RESTART_SETUP)
        }
        return activate(config, credential.pendingExpiresAt, onState)
    }

    private fun activate(
        config: ConnectionConfig,
        pendingExpiresAt: String?,
        onState: (SetupState) -> Unit,
    ): SetupState {
        onState(SetupState.Activating(config, pendingExpiresAt))
        val clientIdentity = runCatching { identity.stagedClientIdentity(config.installationId) }.getOrElse {
            discardPending()
            return SetupState.Failed(config, "待激活设备身份已丢失", SetupAction.RESTART_SETUP)
        }
        val response = runCatching {
            transport.request(config, config.activateUrl, "POST", clientIdentity)
        }.getOrElse {
            return SetupState.Failed(config, failureDetail(it, "无法连接激活服务"), SetupAction.RETRY_ACTIVATION)
        }
        if (response.status == 401) {
            discardPending()
            return SetupState.Failed(config, "待激活设备身份已被服务器拒绝", SetupAction.RESTART_SETUP)
        }
        if (response.status == 202) {
            val code = runCatching { response.json().getString("code") }.getOrNull()
            if (code == "approval_pending") {
                return SetupState.AwaitingApproval(config, pendingExpiresAt)
            }
            return SetupState.Failed(config, "审批响应无效", SetupAction.RETRY_ACTIVATION)
        }
        if (response.status == 503) {
            return SetupState.Failed(config, "节点暂时不可用，设备身份已保留", SetupAction.RETRY_ACTIVATION)
        }
        if (response.status != 200) {
            return SetupState.Failed(config, "激活服务返回 ${response.status}", SetupAction.RETRY_ACTIVATION)
        }
        val catalog = runCatching { RemoteApi.decodeCatalog(config, response.json()) }.getOrElse {
            return SetupState.Failed(config, failureDetail(it, "激活响应无效"), SetupAction.RETRY_ACTIVATION)
        }
        if (!catalog.computerConnected) {
            return SetupState.Failed(config, "节点暂时不可用，设备身份已保留", SetupAction.RETRY_ACTIVATION)
        }
        val committed = runCatching {
            identity.promoteCredential(config.installationId)
            settings.commitStagedProfile()
        }.getOrElse {
            return SetupState.Failed(config, failureDetail(it, "连接保存失败"), SetupAction.RETRY_ACTIVATION)
        }
        runCatching { identity.discardStagedCredential(config.installationId) }
        runCatching { settings.discardStagedProfile() }
        return SetupState.Ready(committed)
    }
}
