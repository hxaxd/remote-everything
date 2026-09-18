package com.remoteeverything.core.model

import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.Base64

/**
 * The few bytes every layer hashes: fingerprints, pins, origin aliases. One home
 * for the encoding, so two implementations never drift — the pin trust used to
 * carry a copy and the p12 reader another.
 */
object Digest {

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    /** Lowercase hex, the only form fingerprints travel in. */
    fun toHex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    /** The fingerprint the wire calls certificate_fingerprint: SHA-256 of the DER leaf. */
    fun fingerprint(certificate: X509Certificate): String = toHex(sha256(certificate.encoded))

    /** The public-key pin an invitation may carry: base64 SHA-256 of the SPKI bytes. */
    fun publicKeyPin(certificate: X509Certificate): String =
        Base64.getEncoder().encodeToString(sha256(certificate.publicKey.encoded))
}
