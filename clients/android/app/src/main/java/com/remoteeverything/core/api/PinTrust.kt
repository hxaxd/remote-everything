package com.remoteeverything.core.api

import com.remoteeverything.core.model.Digest
import com.remoteeverything.core.model.ServerPin
import java.net.Socket
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager

/**
 * How a gateway whose certificate nothing signed is trusted: by the pin its
 * invitation carried. The public key pin is the primary one — it survives a
 * renewal that keeps the key — and the certificate fingerprint is the fallback
 * for a gateway that generated its key and certificate together. Expiry and the
 * certificate covering the host still have to hold: a pin is not a licence.
 */
class PinnedTrustManager(private val pin: ServerPin) : X509ExtendedTrustManager() {

    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) =
        verify(chain, host = null)

    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine) =
        verify(chain, engine.peerHost)

    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket) =
        verify(chain, (socket as? SSLSocket)?.inetAddress?.hostAddress)

    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
        throw CertificateException("this trust is for a gateway, not for clients")

    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine) =
        throw CertificateException("this trust is for a gateway, not for clients")

    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket) =
        throw CertificateException("this trust is for a gateway, not for clients")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    private fun verify(chain: Array<X509Certificate>, host: String?) {
        if (chain.isEmpty()) {
            throw CertificateException("the gateway presented no certificate")
        }
        val leaf = chain[0]
        try {
            leaf.checkValidity()
        } catch (e: Exception) {
            throw CertificateException("the gateway's certificate is not valid now")
        }
        if (host != null && !coversHost(leaf, host)) {
            throw CertificateException("the gateway's certificate does not cover $host")
        }
        val publicKeyPin = Digest.publicKeyPin(leaf)
        val certificateFingerprint = Digest.fingerprint(leaf)
        if (publicKeyPin != pin.publicKeyPin && certificateFingerprint != pin.certFingerprint) {
            throw CertificateException("the gateway's certificate is not the pinned one")
        }
    }
}

/**
 * Whether a certificate speaks for a host: an exact match, or a wildcard that
 * covers exactly one label — never a suffix match, which is how `evil-example.com`
 * would pass for `example.com`.
 */
internal fun coversHost(certificate: X509Certificate, host: String): Boolean {
    val wanted = host.trim().lowercase()
    val names: Collection<List<*>> = try {
        certificate.subjectAlternativeNames ?: emptyList()
    } catch (e: Exception) {
        emptyList()
    }
    for (name in names) {
        if (name.size < 2) continue
        val type = (name[0] as? Number)?.toInt() ?: continue
        val value = name[1]?.toString()?.trim()?.lowercase() ?: continue
        when (type) {
            // 2 is dNSName, 7 is iPAddress; other kinds say nothing about a host.
            2 -> if (dnsNameMatches(value, wanted)) return true
            7 -> if (value == wanted) return true
        }
    }
    return false
}

/**
 * A name pattern against a host: a wildcard covers exactly one label, so
 * `*.example.com` speaks for `a.example.com` and never for `example.com` or
 * `a.b.example.com`; and a plain name is an exact match, never a suffix.
 */
internal fun dnsNameMatches(pattern: String, host: String): Boolean {
    if (!pattern.startsWith("*.")) return pattern == host
    val suffix = pattern.removePrefix("*.")
    if (!host.endsWith("." + suffix)) return false
    return !host.removeSuffix("." + suffix).contains('.')
}

/** The trust the platform itself has: what a gateway signed by an authority is verified with. */
fun systemTrustManager(): X509ExtendedTrustManager {
    val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
    factory.init(null as KeyStore?)
    return factory.trustManagers.filterIsInstance<X509ExtendedTrustManager>().first()
}
