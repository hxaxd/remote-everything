package com.remoteeverything.app.web

import java.security.MessageDigest

/**
 * WebView 隔离策略中不依赖 Android 运行时的部分。
 *
 * Profile 名只由安装实例与应用 ID 决定，因而同一应用重启后仍能恢复自己的登录态，
 * 不同安装实例、不同应用则永远不会共享 Cookie、缓存、存储和 Service Worker。
 */
internal object WebIsolationPolicy {
    fun profileName(installationId: String, appId: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$installationId\u0000$appId".toByteArray(Charsets.UTF_8))
        return buildString(PROFILE_PREFIX.length + digest.size * 2) {
            append(PROFILE_PREFIX)
            digest.forEach { byte ->
                val value = byte.toInt() and 0xff
                append(HEX[value ushr 4])
                append(HEX[value and 0x0f])
            }
        }
    }

    fun routingCookie(appId: String): String =
        "$ROUTING_COOKIE_NAME=$appId; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400"

    private const val PROFILE_PREFIX = "remote-"
    private const val ROUTING_COOKIE_NAME = "RemoteEverythingApp"
    private const val HEX = "0123456789abcdef"
}
