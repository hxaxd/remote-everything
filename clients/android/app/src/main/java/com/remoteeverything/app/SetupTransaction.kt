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
    fun stageCredential(installationId: String, encoded: String, password: String)
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

class SetupTransaction(
    private val settings: SetupProfileStore,
    private val identity: SetupIdentityStore,
    private val deviceName: String,
    private val transport: SetupTransport = ProductionSetupTransport,
) {
    fun recover() {
        val staged = settings.stagedProfile() ?: return
        if (staged.mode == "public" && identity.hasStagedCredential(staged.installationId)) return
        identity.discardStagedCredential(staged.installationId)
        settings.discardStagedProfile()
    }

    fun connect(setup: SetupPayload): ConnectionConfig {
        val config = setup.profile
        if (config.mode == "lan") {
            transport.verifyCatalog(config)
            return commitProfile(config)
        }
        val password = identity.credentialPassword(config.installationId)
        settings.stageProfile(config)
        val body = JSONObject()
            .put("device_name", codePointPrefix(deviceName, 80))
            .put("credential_password", password)
            .toString()
        val response = transport.request(
            config,
            config.pairUrl,
            "POST",
            headers = mapOf("Authorization" to "Invitation ${setup.invitation}"),
            body = body,
        )
        require(response.status == 200) { if (response.status == 401) "初始化邀请已失效" else "配对失败（${response.status}）" }
        val credential = RemoteApi.decodePairingCredential(response.json())
        identity.stageCredential(config.installationId, credential, password)
        return activate(config)
    }

    fun activate(config: ConnectionConfig): ConnectionConfig {
        val response = transport.request(config, config.activateUrl, "POST", identity.stagedClientIdentity(config.installationId))
        require(response.status == 200) { if (response.status == 503) "节点暂时不可用，稍后可继续激活" else "设备激活失败（${response.status}）" }
        val catalog = RemoteApi.decodeCatalog(config, response.json())
        require(catalog.computerConnected) { catalog.code }
        val committed = settings.commitStagedProfile()
        identity.promoteCredential(config.installationId)
        settings.discardStagedProfile()
        return committed
    }

    private fun commitProfile(config: ConnectionConfig): ConnectionConfig {
        settings.stageProfile(config)
        val committed = settings.commitStagedProfile()
        settings.discardStagedProfile()
        return committed
    }
}
