package com.remoteeverything.app

import android.content.Context
import org.json.JSONObject
import java.net.URL
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedKeyManager

data class HttpResult(val status: Int, val body: String) {
    fun json(): JSONObject = JSONObject(body)
}

object SecureHttp {
    fun bootstrapKeyManager(context: Context): X509ExtendedKeyManager {
        val password = AppConfig.BOOTSTRAP_PASSWORD.toCharArray()
        val store = KeyStore.getInstance("PKCS12")
        context.resources.openRawResource(R.raw.bootstrap_client).use { store.load(it, password) }
        val names = store.aliases()
        var alias: String? = null
        while (names.hasMoreElements()) {
            val candidate = names.nextElement()
            if (store.isKeyEntry(candidate)) {
                alias = candidate
                break
            }
        }
        val selected = requireNotNull(alias) { "注册凭证中没有客户端身份" }
        val privateKey = store.getKey(selected, password) as PrivateKey
        val chain = store.getCertificateChain(selected).map { it as X509Certificate }.toTypedArray()
        return StaticIdentityKeyManager(privateKey, chain)
    }

    fun request(
        url: String,
        method: String,
        keyManager: X509ExtendedKeyManager,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
    ): HttpResult {
        val connection = URL(url).openConnection() as HttpsURLConnection
        connection.sslSocketFactory = sslContext(keyManager).socketFactory
        connection.requestMethod = method
        connection.connectTimeout = 8_000
        connection.readTimeout = 12_000
        connection.instanceFollowRedirects = false
        connection.useCaches = false
        connection.setRequestProperty("Accept", "application/json")
        headers.forEach(connection::setRequestProperty)
        if (body != null) {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        val status = connection.responseCode
        val source = if (status in 200..399) connection.inputStream else connection.errorStream
        val response = source?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        connection.disconnect()
        return HttpResult(status, response)
    }

    private fun sslContext(keyManager: KeyManager): SSLContext {
        val trustFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        trustFactory.init(null as KeyStore?)
        return SSLContext.getInstance("TLS").apply {
            init(arrayOf(keyManager), trustFactory.trustManagers, null)
        }
    }
}
