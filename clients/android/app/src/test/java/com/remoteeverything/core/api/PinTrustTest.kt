package com.remoteeverything.core.api

import com.remoteeverything.core.model.Digest
import com.remoteeverything.core.model.ServerPin
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Date

class PinTrustTest {

    private fun generateCert(
        keyPair: KeyPair,
        validityOffsetStart: Long = -60_000,
        validityOffsetEnd: Long = 86_400_000,
        dnsNames: List<String> = emptyList(),
        ipAddresses: List<String> = emptyList(),
    ): X509Certificate {
        val now = System.currentTimeMillis()
        val name = X500Name("CN=test-gw")
        val builder = JcaX509v3CertificateBuilder(
            name,
            BigInteger.valueOf(now),
            Date(now + validityOffsetStart),
            Date(now + validityOffsetEnd),
            name,
            keyPair.public,
        )
        val sanList = mutableListOf<GeneralName>()
        for (dns in dnsNames) {
            sanList.add(GeneralName(GeneralName.dNSName, dns))
        }
        for (ip in ipAddresses) {
            sanList.add(GeneralName(GeneralName.iPAddress, ip))
        }
        if (sanList.isNotEmpty()) {
            builder.addExtension(
                Extension.subjectAlternativeName,
                false,
                GeneralNames(sanList.toTypedArray()),
            )
        }
        val signer = JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private)
        return JcaX509CertificateConverter().getCertificate(builder.build(signer))
    }

    @Test
    fun `dnsNameMatches enforces exact and single label wildcards`() {
        assertTrue(dnsNameMatches("example.com", "example.com"))
        assertFalse(dnsNameMatches("example.com", "evil-example.com"))
        assertFalse(dnsNameMatches("example.com", "sub.example.com"))

        assertTrue(dnsNameMatches("*.example.com", "api.example.com"))
        assertFalse(dnsNameMatches("*.example.com", "example.com"))
        assertFalse(dnsNameMatches("*.example.com", "a.b.example.com"))
        assertFalse(dnsNameMatches("*.example.com", "evil.com"))
    }

    @Test
    fun `coversHost checks SAN for DNS and IP addresses`() {
        val keyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val cert = generateCert(
            keyPair,
            dnsNames = listOf("gw.example.com", "*.nodes.example.com"),
            ipAddresses = listOf("192.168.1.100"),
        )

        assertTrue(coversHost(cert, "gw.example.com"))
        assertTrue(coversHost(cert, "node1.nodes.example.com"))
        assertTrue(coversHost(cert, "192.168.1.100"))

        assertFalse(coversHost(cert, "evil.example.com"))
        assertFalse(coversHost(cert, "sub.node1.nodes.example.com"))
        assertFalse(coversHost(cert, "192.168.1.101"))
    }

    @Test
    fun `PinnedTrustManager accepts certificate with matching public key pin or fingerprint`() {
        val keyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val cert = generateCert(keyPair, dnsNames = listOf("gw.example.com"))
        val spkiPin = Digest.publicKeyPin(cert)
        val certFp = Digest.fingerprint(cert)

        // Matching public key pin
        val trustManagerBySpki = PinnedTrustManager(ServerPin(publicKeyPin = spkiPin, certFingerprint = "00".repeat(32)))
        trustManagerBySpki.checkServerTrusted(arrayOf(cert), "ECDHE_ECDSA")

        // Matching fingerprint
        val trustManagerByFp = PinnedTrustManager(ServerPin(publicKeyPin = "wrongPin=".padEnd(44, 'A'), certFingerprint = certFp))
        trustManagerByFp.checkServerTrusted(arrayOf(cert), "ECDHE_ECDSA")
    }

    @Test
    fun `PinnedTrustManager rejects expired certificate, empty chain, or pin mismatch`() {
        val keyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val validCert = generateCert(keyPair, dnsNames = listOf("gw.example.com"))
        val expiredCert = generateCert(keyPair, validityOffsetStart = -100_000, validityOffsetEnd = -50_000, dnsNames = listOf("gw.example.com"))

        val pin = ServerPin(publicKeyPin = Digest.publicKeyPin(validCert), certFingerprint = Digest.fingerprint(validCert))
        val trustManager = PinnedTrustManager(pin)

        // Empty chain
        assertThrows(CertificateException::class.java) {
            trustManager.checkServerTrusted(emptyArray(), "ECDHE_ECDSA")
        }

        // Expired cert
        assertThrows(CertificateException::class.java) {
            trustManager.checkServerTrusted(arrayOf(expiredCert), "ECDHE_ECDSA")
        }

        // Mismatched pin
        val mismatchPin = ServerPin(publicKeyPin = "wrongPin=".padEnd(44, 'A'), certFingerprint = "ff".repeat(32))
        val mismatchTrustManager = PinnedTrustManager(mismatchPin)
        assertThrows(CertificateException::class.java) {
            mismatchTrustManager.checkServerTrusted(arrayOf(validCert), "ECDHE_ECDSA")
        }
    }
}
