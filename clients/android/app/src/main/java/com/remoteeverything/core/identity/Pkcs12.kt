package com.remoteeverything.core.identity

import com.remoteeverything.core.model.Digest
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.X509Certificate

/**
 * Reading a credential the gateway issued: a PKCS#12 holding the device's private
 * key and the certificate chain it chains to. Everything here is checked before
 * the material is trusted — a credential that cannot be opened, holds no key, or
 * whose key does not match its certificate is a broken credential, and finding
 * that out at pairing time beats finding it out as a TLS failure later.
 */
object Pkcs12 {

    class InvalidCredential(message: String, cause: Throwable? = null) : Exception(message, cause)

    data class Material(val privateKey: PrivateKey, val chain: List<X509Certificate>) {
        val certificate: X509Certificate get() = chain.first()
    }

    fun load(pkcs12: ByteArray, password: String): Material {
        val store = try {
            KeyStore.getInstance("PKCS12").apply { load(pkcs12.inputStream(), password.toCharArray()) }
        } catch (e: Exception) {
            throw InvalidCredential("the credential could not be opened", e)
        }
        val alias = try {
            store.aliases().toList().firstOrNull { store.isKeyEntry(it) }
        } catch (e: Exception) {
            throw InvalidCredential("the credential could not be read", e)
        } ?: throw InvalidCredential("the credential holds no private key")
        val privateKey = try {
            store.getKey(alias, password.toCharArray()) as? PrivateKey
        } catch (e: Exception) {
            throw InvalidCredential("the private key could not be read", e)
        } ?: throw InvalidCredential("the credential holds no private key")
        val chain = try {
            store.getCertificateChain(alias).orEmpty().mapNotNull { it as? X509Certificate }
        } catch (e: Exception) {
            throw InvalidCredential("the certificate chain could not be read", e)
        }
        if (chain.isEmpty()) {
            throw InvalidCredential("the credential holds no certificate")
        }
        return Material(privateKey, chain)
    }

    /** SHA-256 of the DER leaf certificate, lowercase hex — the fingerprint the wire calls certificate_fingerprint. */
    fun fingerprint(certificate: X509Certificate): String = Digest.fingerprint(certificate)

    /**
     * Proves the private key belongs to the certificate by signing a challenge with
     * one and verifying with the other. The digest follows the key's own type: a
     * hard-coded one would reject the other type rather than a broken credential.
     */
    fun verifyKeyPair(material: Material) {
        val algorithm = when (material.privateKey.algorithm.uppercase()) {
            "EC" -> "SHA256withECDSA"
            "RSA" -> "SHA256withRSA"
            else -> throw InvalidCredential("unsupported key algorithm ${material.privateKey.algorithm}")
        }
        val challenge = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val signature = try {
            Signature.getInstance(algorithm).apply {
                initSign(material.privateKey)
                update(challenge)
            }.sign()
        } catch (e: Exception) {
            throw InvalidCredential("the private key could not sign", e)
        }
        val matches = try {
            Signature.getInstance(algorithm).apply {
                initVerify(material.certificate.publicKey)
                update(challenge)
            }.verify(signature)
        } catch (e: Exception) {
            throw InvalidCredential("the certificate could not verify", e)
        }
        if (!matches) {
            throw InvalidCredential("the private key does not match its certificate")
        }
    }
}
