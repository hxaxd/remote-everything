package com.remoteeverything.app

import android.net.Uri
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

data class ConnectionConfig(
    val installationId: String,
    val name: String,
    val mode: String,
    val gatewayOrigin: String,
    val gatewayFingerprint: String,
    val gatewayPublicKeyPin: String,
) {
    private val originUri: URI = URI(gatewayOrigin)
    val gatewayHost: String = requireNotNull(originUri.host)
    val gatewayPort: Int = if (originUri.port == -1) 443 else originUri.port

    val pairUrl: String get() = "$gatewayOrigin/__remote_everything_pair"
    val activateUrl: String get() = "$gatewayOrigin/__remote_everything_activate"
    val appsUrl: String get() = "$gatewayOrigin/__remote_everything/apps"

    fun appActionUrl(id: String, action: String): String = "$appsUrl/$id/$action"
    fun appOpenUrl(id: String): String = "$gatewayOrigin/__remote_everything/open/$id"

    fun isGatewayEndpoint(host: String?, port: Int): Boolean =
        host.equals(gatewayHost, ignoreCase = true) && port == gatewayPort

    fun isGatewayUri(uri: Uri): Boolean {
        return isGatewayUrl(uri.toString())
    }

    fun isGatewayUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        val port = if (uri.port == -1) 443 else uri.port
        uri.scheme == "https" && uri.rawUserInfo == null && isGatewayEndpoint(uri.host, port)
    }.getOrDefault(false)
}

data class SetupPayload(
    val profile: ConnectionConfig,
    val invitation: String,
)

object AppConfig {
    private val installationIdPattern = Regex("^[a-f0-9]{64}$")
    private val fingerprintPattern = Regex("^[a-f0-9]{64}$")
    private val invitationPattern = Regex("^[A-Za-z0-9_-]{43}$")
    private val publicKeyPinPattern = Regex("^[A-Za-z0-9+/]{43}=$")

    fun create(
        installationId: String,
        name: String,
        mode: String,
        originInput: String,
        fingerprintInput: String = "",
        publicKeyPinInput: String = "",
    ): ConnectionConfig {
        require(installationIdPattern.matches(installationId)) { "安装实例标识无效" }
        val normalizedName = name.trim()
        require(normalizedName.isNotEmpty() && normalizedName.codePointCount(0, normalizedName.length) <= 80 && normalizedName.none { it.code < 32 || it.code == 127 }) { "安装实例名称无效" }
        require(mode == "lan" || mode == "public") { "连接模式无效" }
        val parsed = URI(originInput.trim())
        require(
            parsed.scheme == "https" &&
                parsed.host != null &&
                parsed.rawUserInfo == null &&
                parsed.rawQuery == null &&
                parsed.rawFragment == null &&
                (parsed.port == -1 || parsed.port in 1..65535) &&
                (parsed.rawPath.isNullOrEmpty() || parsed.rawPath == "/"),
        ) { "服务地址必须是 HTTPS 源站" }
        val host = requireNotNull(parsed.host).lowercase()
        val authorityHost = if (host.contains(':')) "[$host]" else host
        val port = if (parsed.port == -1) "" else ":${parsed.port}"
        val origin = "https://$authorityHost$port"
        val fingerprint = fingerprintInput.lowercase().replace(":", "").replace(Regex("\\s"), "")
        val publicKeyPin = publicKeyPinInput.trim()
        if (mode == "lan") {
            require(fingerprintPattern.matches(fingerprint)) { "局域网服务证书指纹无效" }
            require(publicKeyPinPattern.matches(publicKeyPin)) { "局域网服务公钥摘要无效" }
        }
        return ConnectionConfig(
            installationId,
            normalizedName,
            mode,
            origin,
            if (mode == "lan") fingerprint else "",
            if (mode == "lan") publicKeyPin else "",
        )
    }

    fun parseSetup(value: String): SetupPayload {
        val uri = URI(value.trim())
        require(uri.scheme == "remote-everything" && uri.host == "setup" && (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/") && uri.rawFragment == null) { "初始化链接无效" }
        val values = linkedMapOf<String, String>()
        uri.rawQuery?.split("&")?.filter(String::isNotEmpty)?.forEach { item ->
            val parts = item.split("=", limit = 2)
            require(parts.size == 2) { "初始化链接参数无效" }
            val key = decode(parts[0])
            require(key !in values) { "初始化链接包含重复参数" }
            values[key] = decode(parts[1])
        }
        require(values["v"] == "2") { "初始化链接版本不受支持" }
        val mode = requireNotNull(values["mode"]) { "初始化链接缺少连接模式" }
        val expected = if (mode == "lan") {
            setOf("v", "id", "name", "mode", "origin", "fingerprint", "public_key_pin")
        } else {
            setOf("v", "id", "name", "mode", "origin", "invitation")
        }
        require(values.keys == expected) { "初始化链接参数不完整" }
        val profile = create(
            requireNotNull(values["id"]),
            requireNotNull(values["name"]),
            mode,
            requireNotNull(values["origin"]),
            values["fingerprint"].orEmpty(),
            values["public_key_pin"].orEmpty(),
        )
        val invitation = values["invitation"].orEmpty()
        if (mode == "public") require(invitationPattern.matches(invitation)) { "公网邀请无效" }
        return SetupPayload(profile, invitation)
    }

    private fun decode(value: String): String = URLDecoder.decode(value, StandardCharsets.UTF_8.name())
}
