package com.remoteeverything.app

import android.annotation.SuppressLint
import android.net.http.SslCertificate
import android.net.http.SslError
import androidx.core.net.toUri
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URL
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager

data class HttpResult(val status: Int, val body: String) {
    fun json(): JSONObject = JSONObject(body)
}

data class ClientIdentity(
    val privateKey: PrivateKey,
    val chain: Array<X509Certificate>,
) {
    val keyManager: X509ExtendedKeyManager = StaticIdentityKeyManager(privateKey, chain)
}

object SecureHttp {
    fun request(
        config: ConnectionConfig,
        url: String,
        method: String,
        identity: ClientIdentity? = null,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
    ): HttpResult {
        require(config.isGatewayUri(url.toUri())) { "请求地址不属于配置的服务" }
        val connection = URL(url).openConnection() as HttpsURLConnection
        connection.sslSocketFactory = sslContext(config, identity).socketFactory
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

    fun acceptsPinnedWebViewError(config: ConnectionConfig, error: SslError?): Boolean {
        if (config.mode != "lan" || error == null || error.primaryError != SslError.SSL_UNTRUSTED || !config.isGatewayUri(error.url.toUri())) return false
        val bytes = SslCertificate.saveState(error.certificate).getByteArray("x509-certificate") ?: return false
        val parsed = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(bytes)) as X509Certificate
        parsed.checkValidity()
        return GatewaySecurityPolicy.fingerprint(parsed.encoded) == config.gatewayFingerprint && GatewaySecurityPolicy.certificateCoversHost(parsed, config.gatewayHost)
    }

    private fun sslContext(config: ConnectionConfig, identity: ClientIdentity?): SSLContext =
        SSLContext.getInstance("TLS").apply {
            val trustManagers = if (config.mode == "lan") {
                arrayOf(PinnedTrustManager(config.gatewayFingerprint))
            } else {
                val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
                factory.init(null as KeyStore?)
                factory.trustManagers
            }
            val keyManagers = identity?.let { arrayOf(it.keyManager) }
            init(keyManagers, trustManagers, null)
        }

    @SuppressLint("CustomX509TrustManager")
    private class PinnedTrustManager(private val expected: String) : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            throw CertificateException("客户端信任检查不可用")
        }

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val certificate = chain?.firstOrNull() ?: throw CertificateException("服务器未提供证书")
            certificate.checkValidity()
            if (GatewaySecurityPolicy.fingerprint(certificate.encoded) != expected) throw CertificateException("服务器证书指纹不匹配")
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
