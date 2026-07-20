package com.remoteeverything.app

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

data class RemoteApp(
    val id: String,
    val name: String,
    val description: String,
    val icon: String,
    val accent: String,
    val openUrl: String,
    val code: String,
)

data class CatalogSnapshot(
    val computerConnected: Boolean,
    val code: String,
    val apps: List<RemoteApp>,
)

object RemoteApi {
    private val appId = Regex("^[a-z0-9][a-z0-9._-]{0,63}$")
    private val fingerprint = Regex("^[a-f0-9]{64}$")
    private val accent = Regex("^#[0-9A-Fa-f]{6}$")
    private val catalogKeys = setOf("ok", "computer_connected", "code", "apps")
    private val appKeys = setOf("id", "name", "description", "icon", "accent", "computer_connected", "enabled", "running", "code")
    private val pairingKeys = setOf("ok", "device_name", "certificate_fingerprint", "credential_format", "credential_pkcs12", "pending_expires_at")
    private val actionKeys = setOf("ok", "action", "computer_connected", "enabled", "running", "code")

    private fun JSONObject.keysSet(): Set<String> = keys().asSequence().toSet()
    private fun JSONObject.requiredString(key: String): String {
        require(has(key) && get(key) is String) { "服务响应缺少 $key" }
        return getString(key)
    }
    private fun JSONObject.requiredBoolean(key: String): Boolean {
        require(has(key) && get(key) is Boolean) { "服务响应缺少 $key" }
        return getBoolean(key)
    }
    private fun validMetadata(value: String, maximum: Int, allowEmpty: Boolean): Boolean =
        value.trim() == value && (allowEmpty || value.isNotEmpty()) &&
            value.codePointCount(0, value.length) <= maximum && value.none { it.code < 32 || it.code == 127 }

    fun verifyCatalog(config: ConnectionConfig, identity: ClientIdentity?) {
        catalog(config, identity)
    }

    fun catalog(config: ConnectionConfig, identity: ClientIdentity?): CatalogSnapshot {
        val response = SecureHttp.request(config, config.appsUrl, "GET", identity)
        require(response.status == 200) { "服务返回 ${response.status}" }
        return decodeCatalog(config, response.json())
    }

    fun decodeCatalog(config: ConnectionConfig, payload: JSONObject): CatalogSnapshot {
        require(payload.keysSet() == catalogKeys) { "目录响应字段无效" }
        require(payload.requiredBoolean("ok")) { payload.requiredString("code") }
        val connected = payload.requiredBoolean("computer_connected")
        val code = payload.requiredString("code")
        val rawApps = payload.get("apps")
        require(rawApps is JSONArray) { "目录响应缺少 apps" }
        val array = rawApps
        val ids = mutableSetOf<String>()
        val apps = buildList {
            for (index in 0 until array.length()) {
                val app = decodeApp(config, array.getJSONObject(index))
                require(ids.add(app.id)) { "应用目录 ID 重复" }
                add(app)
            }
        }
        require(if (connected) code == "ready" else code == "computer_offline" && apps.isEmpty()) { "目录连接状态无效" }
        return CatalogSnapshot(connected, code, apps)
    }

    private fun decodeApp(config: ConnectionConfig, value: JSONObject): RemoteApp {
        require(value.keysSet() == appKeys) { "应用目录字段无效" }
        val id = value.requiredString("id")
        val name = value.requiredString("name")
        val description = value.requiredString("description")
        val icon = value.requiredString("icon")
        val color = value.requiredString("accent")
        val connected = value.requiredBoolean("computer_connected")
        val enabled = value.requiredBoolean("enabled")
        val running = value.requiredBoolean("running")
        val code = value.requiredString("code")
        val expectedCode = if (enabled) if (running) "ready" else "starting" else if (running) "stopping" else "stopped"
        require(appId.matches(id) && validMetadata(name, 80, false) && validMetadata(description, 240, true) && validMetadata(icon, 4, true) && accent.matches(color) && connected && code == expectedCode) { "应用目录内容无效" }
        return RemoteApp(id, name, description, icon, color, config.appOpenUrl(id), code)
    }

    fun decodePairingCredential(payload: JSONObject): String {
        require(payload.keysSet() == pairingKeys && payload.requiredBoolean("ok")) { "配对响应字段无效" }
        require(payload.requiredString("device_name").isNotBlank()) { "配对设备名无效" }
        require(fingerprint.matches(payload.requiredString("certificate_fingerprint"))) { "配对证书指纹无效" }
        require(payload.requiredString("credential_format") == "pkcs12") { "配对凭据格式无效" }
        require(runCatching { Instant.parse(payload.requiredString("pending_expires_at")) }.isSuccess) { "配对期限无效" }
        return payload.requiredString("credential_pkcs12").also { require(it.isNotBlank()) { "配对凭据为空" } }
    }

    fun control(config: ConnectionConfig, identity: ClientIdentity?, appId: String, action: String): Boolean {
        require(action == "start" || action == "stop")
        val response = SecureHttp.request(config, config.appActionUrl(appId, action), "POST", identity)
        if (response.status != 200) return false
        return decodeAction(config, action, response.json())
    }

    fun decodeAction(config: ConnectionConfig, expectedAction: String, payload: JSONObject): Boolean {
        val keys = payload.keysSet()
        require(keys == actionKeys || keys == actionKeys + "app" || keys == actionKeys + setOf("app", "error_code")) { "控制响应字段无效" }
        val ok = payload.requiredBoolean("ok")
        require(payload.requiredString("action") == expectedAction) { "控制动作无效" }
        val connected = payload.requiredBoolean("computer_connected")
        val enabled = payload.requiredBoolean("enabled")
        val running = payload.requiredBoolean("running")
        val code = payload.requiredString("code")
        if (!connected) {
            require(!ok && !enabled && !running && code == "computer_offline" && !payload.has("app")) { "离线控制响应无效" }
            return false
        }
        if (!payload.has("app")) {
            require(!ok && !enabled && !running && code in setOf("app_not_found", "state_update_failed")) { "失败控制响应无效" }
            return false
        }
        val app = payload.getJSONObject("app")
        decodeApp(config, app)
        require(enabled == app.requiredBoolean("enabled") && running == app.requiredBoolean("running") && code == app.requiredString("code")) { "控制状态不一致" }
        if (payload.has("error_code")) {
            require(!ok && payload.requiredString("error_code") == "stop_command_failed") { "控制错误无效" }
        } else {
            require(ok) { "控制结果无效" }
        }
        return ok
    }
}
