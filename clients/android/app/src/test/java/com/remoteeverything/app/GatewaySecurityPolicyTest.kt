package com.remoteeverything.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewaySecurityPolicyTest {
    private val id = "ab".repeat(32)
    private val publicConfig = AppConfig.create(id, "Public", "public", "https://gateway.example:5443")
    private val lanConfig = AppConfig.create(id, "LAN", "lan", "https://192.0.2.4:5443", "cd".repeat(32), "A".repeat(43) + "=")

    @Test
    fun webViewKeepsOnlyExactGatewayOriginInside() {
        assertTrue(GatewaySecurityPolicy.opensInsideWebView(publicConfig, "https://gateway.example:5443/app/path?x=1"))
        assertFalse(GatewaySecurityPolicy.opensInsideWebView(publicConfig, "https://gateway.example/app/path"))
        assertFalse(GatewaySecurityPolicy.opensInsideWebView(publicConfig, "http://gateway.example:5443/app/path"))
        assertFalse(GatewaySecurityPolicy.opensInsideWebView(publicConfig, "https://gateway.example.evil:5443/app/path"))
        assertFalse(GatewaySecurityPolicy.opensInsideWebView(publicConfig, "https://user@gateway.example:5443/app/path"))
    }

    // Every paired device presents the certificate it was issued, so the client
    // certificate is limited to the gateway endpoint rather than to one mode.
    @Test
    fun clientCertificateIsLimitedToTheGatewayEndpointInEveryMode() {
        assertTrue(GatewaySecurityPolicy.allowsClientCertificate(publicConfig, true, "gateway.example", 5443))
        assertFalse(GatewaySecurityPolicy.allowsClientCertificate(publicConfig, false, "gateway.example", 5443))
        assertFalse(GatewaySecurityPolicy.allowsClientCertificate(publicConfig, true, "gateway.example", 443))
        assertTrue(GatewaySecurityPolicy.allowsClientCertificate(lanConfig, true, "192.0.2.4", 5443))
        assertFalse(GatewaySecurityPolicy.allowsClientCertificate(lanConfig, false, "192.0.2.4", 5443))
        assertFalse(GatewaySecurityPolicy.allowsClientCertificate(lanConfig, true, "192.0.2.4", 443))
    }

    @Test
    fun fingerprintAndSubjectAlternativeNameChecksAreExact() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            GatewaySecurityPolicy.fingerprint("abc".toByteArray()),
        )
        assertTrue(GatewaySecurityPolicy.subjectAlternativeNamesCoverHost(listOf(listOf(2, "Gateway.Example")), "gateway.example"))
        assertFalse(GatewaySecurityPolicy.subjectAlternativeNamesCoverHost(listOf(listOf(2, "other.example")), "gateway.example"))
        assertTrue(GatewaySecurityPolicy.subjectAlternativeNamesCoverHost(listOf(listOf(7, "192.0.2.4")), "192.0.2.4"))
        assertFalse(GatewaySecurityPolicy.subjectAlternativeNamesCoverHost(listOf(listOf(7, "192.0.2.5")), "192.0.2.4"))
    }
}
