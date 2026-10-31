package com.remoteeverything.core.api

import java.io.IOException
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** Redirects select trust, identity and cookies again before opening the next connection. */
class ScopedDownload(
    private val gatewayOrigin: String,
    private val gateway: () -> OkHttpClient?,
    private val plain: OkHttpClient,
    private val cookies: (String) -> String?,
    private val saveCookie: (String, String) -> Unit,
) {
    fun execute(url: String, userAgent: String): Response {
        var address = url.toHttpUrl()
        val visited = mutableSetOf<String>()
        repeat(21) {
            if (!visited.add(address.toString())) throw IOException("download redirect loop")
            val transport = if (belongsToGateway(gatewayOrigin, address.toString())) {
                gateway() ?: throw IOException("gateway identity unavailable")
            } else plain
            val client = transport.newBuilder().followRedirects(false).followSslRedirects(false).build()
            val request = Request.Builder().url(address).header("User-Agent", userAgent).apply {
                cookies(address.toString())?.let { header("Cookie", it) }
            }.build()
            val response = client.newCall(request).execute()
            response.headers("Set-Cookie").forEach { saveCookie(address.toString(), it) }
            if (response.code !in listOf(301, 302, 303, 307, 308)) return response
            val next = response.header("Location")?.let { address.resolve(it) }
            response.close()
            if (next == null || next.username.isNotEmpty() || next.password.isNotEmpty()) {
                throw IOException("invalid download redirect")
            }
            address = next
        }
        throw IOException("too many download redirects")
    }
}
