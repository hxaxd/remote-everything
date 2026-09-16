package com.remoteeverything.app

import java.net.InetAddress
import java.security.MessageDigest
import java.security.cert.X509Certificate

object GatewaySecurityPolicy {
    // A device is admitted by the certificate it was issued, in every mode: what
    // differs between them is who signs the entrance, not who the client is.
    fun allowsClientCertificate(config: ConnectionConfig, identityPresent: Boolean, host: String?, port: Int): Boolean =
        identityPresent && config.isGatewayEndpoint(host, port)

    fun opensInsideWebView(config: ConnectionConfig, url: String): Boolean = config.isGatewayUrl(url)

    fun fingerprint(encodedCertificate: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(encodedCertificate)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun certificateCoversHost(certificate: X509Certificate, host: String): Boolean =
        subjectAlternativeNamesCoverHost(certificate.subjectAlternativeNames.orEmpty(), host)

    internal fun subjectAlternativeNamesCoverHost(entries: Collection<List<*>>, host: String): Boolean {
        val numericHost = host.contains(':') || Regex("^\\d{1,3}(?:\\.\\d{1,3}){3}$").matches(host)
        val expectedAddress = if (numericHost) runCatching { InetAddress.getByName(host) }.getOrNull() else null
        return entries.any { entry ->
            when (entry.getOrNull(0) as? Int) {
                2 -> expectedAddress == null && (entry.getOrNull(1) as? String).equals(host, ignoreCase = true)
                7 -> expectedAddress != null && runCatching { InetAddress.getByName(entry.getOrNull(1).toString()) == expectedAddress }.getOrDefault(false)
                else -> false
            }
        }
    }
}
