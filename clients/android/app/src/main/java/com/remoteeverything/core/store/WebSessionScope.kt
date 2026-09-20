package com.remoteeverything.core.store

import java.security.MessageDigest

/** Persistent browser data belongs to one gateway binding and one node application. */
object WebSessionScope {
    fun profileName(gatewayOrigin: String, appKey: String): String {
        require(gatewayOrigin.isNotBlank() && appKey.isNotBlank())
        require('\n' !in gatewayOrigin && '\n' !in appKey)
        val input = "remote-everything:web-session\n$gatewayOrigin\n$appKey"
        val hash = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return "app-" + hash.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
