package com.remoteeverything.app.web

import android.net.Uri
import android.net.http.SslCertificate
import android.net.http.SslError
import android.webkit.SslErrorHandler
import com.remoteeverything.core.model.Digest
import com.remoteeverything.core.model.ServerPin
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/**
 * Validates SSL certificates against pinned self-signed public keys for LAN gateways.
 */
class WebPinningClient(
    private val pinProvider: () -> ServerPin?,
    private val isAllowedHost: (String) -> Boolean,
) {
    fun handleSslError(
        handler: SslErrorHandler,
        error: SslError,
        onSuccess: () -> Unit,
        onFailure: () -> Unit,
    ) {
        val pin = pinProvider()
        val host = error.url?.let { runCatching { Uri.parse(it).host }.getOrNull() }.orEmpty()
        val certificate = certificateOf(error)
        if (pin != null && certificate != null && isAllowedHost(host) && matchesPin(certificate, pin)) {
            handler.proceed()
            onSuccess()
            return
        }
        handler.cancel()
        onFailure()
    }

    private fun certificateOf(error: SslError): X509Certificate? = try {
        val state = SslCertificate.saveState(error.certificate)
        val bytes = state.getByteArray("x509-certificate") ?: return null
        CertificateFactory.getInstance("X.509").generateCertificate(bytes.inputStream()) as? X509Certificate
    } catch (e: Exception) {
        null
    }

    private fun matchesPin(certificate: X509Certificate, pin: ServerPin): Boolean {
        try {
            certificate.checkValidity()
        } catch (e: Exception) {
            return false
        }
        val publicKeyPin = Digest.publicKeyPin(certificate)
        val fingerprint = Digest.fingerprint(certificate)
        return publicKeyPin == pin.publicKeyPin || fingerprint == pin.certFingerprint
    }
}
