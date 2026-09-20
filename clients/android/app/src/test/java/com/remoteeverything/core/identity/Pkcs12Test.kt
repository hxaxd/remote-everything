package com.remoteeverything.core.identity

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Date

/**
 * What the client must prove about a credential before trusting it: that it
 * opens, that the key belongs to the certificate, and that the fingerprint is
 * one the client computed itself.
 *
 * The JWK's own PKCS#12 writer produces the modern profile — AES-256 with
 * PBKDF2 and a SHA-256 MAC, which is what the gateway's go-pkcs12 emits — so
 * these cases exercise the format that actually travels. The Android platform
 * parses PKCS#12 with Conscrypt rather than the JDK, which is why a real device
 * remains the last word on it.
 */
class Pkcs12Test {

    private class Credential(val bytes: ByteArray, val password: String, val certificate: X509Certificate)

    private fun credential(): Credential {
        val keyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val certificate = certificateFor(keyPair)
        val password = "correct-horse-battery-staple"
        val store = KeyStore.getInstance("PKCS12").apply { load(null, null) }
        store.setKeyEntry("device", keyPair.private, password.toCharArray(), arrayOf(certificate))
        val bytes = ByteArrayOutputStream().also { store.store(it, password.toCharArray()) }.toByteArray()
        return Credential(bytes, password, certificate)
    }

    private fun certificateFor(keyPair: KeyPair): X509Certificate {
        val now = System.currentTimeMillis()
        val name = X500Name("CN=device")
        val builder = JcaX509v3CertificateBuilder(
            name,
            BigInteger.valueOf(now),
            Date(now - 60_000),
            Date(now + 86_400_000),
            name,
            keyPair.public,
        )
        val signer = JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private)
        return JcaX509CertificateConverter().getCertificate(builder.build(signer))
    }

    @Test
    fun `a credential opens and its key matches its certificate`() {
        val credential = credential()
        val material = Pkcs12.load(credential.bytes, credential.password)
        assertEquals("EC", material.privateKey.algorithm)
        Pkcs12.verifyKeyPair(material)
        assertTrue(Pkcs12.fingerprint(material.certificate).matches(Regex("^[a-f0-9]{64}$")))
    }

    @Test
    fun `the fingerprint is the one the client computes, not one it was told`() {
        val credential = credential()
        val material = Pkcs12.load(credential.bytes, credential.password)
        assertEquals(Pkcs12.fingerprint(credential.certificate), Pkcs12.fingerprint(material.certificate))
    }

    @Test
    fun `a wrong password is a broken credential, not a crash`() {
        val credential = credential()
        assertThrows(Pkcs12.InvalidCredential::class.java) {
            Pkcs12.load(credential.bytes, "not-the-password")
        }
    }

    @Test
    fun `a key that does not match its certificate is refused`() {
        // Signing with one key pair and verifying with another's certificate is
        // exactly the broken credential this check exists to catch.
        val first = credential().let { Pkcs12.load(it.bytes, it.password) }
        val second = credential().let { Pkcs12.load(it.bytes, it.password) }
        assertThrows(Pkcs12.InvalidCredential::class.java) {
            Pkcs12.verifyKeyPair(Pkcs12.Material(first.privateKey, second.chain))
        }
    }

    @Test
    fun `garbage is not a credential`() {
        assertThrows(Pkcs12.InvalidCredential::class.java) {
            Pkcs12.load(ByteArray(64) { it.toByte() }, "password")
        }
    }
}
