package com.remoteeverything.core.json

import java.time.Instant
import java.util.Base64

/**
 * The value rules of the wire, one home across the three client languages so a
 * rule lives once instead of drifting per platform. The structure rules — which
 * fields, which enum values — belong to each language's strict decoder; these
 * are the rules a decoder cannot express by shape: lengths, patterns, formats,
 * and the cross-field consistency the schemas describe in words.
 */
object Strict {

    /** A node id or a certificate fingerprint: ^[a-f0-9]{64}$. */
    fun isHex64(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    /** An application id: ^[a-z0-9][a-z0-9._-]{0,63}$. */
    fun isApplicationId(value: String): Boolean {
        if (value.isEmpty() || value.length > 64) return false
        if (value[0] !in 'a'..'z' && value[0] !in '0'..'9') return false
        return value.drop(1).all { it in 'a'..'z' || it in '0'..'9' || it == '.' || it == '-' || it == '_' }
    }

    /** Length in code points, the unit the contract counts names in. */
    fun codePoints(value: String): Int = value.codePointCount(0, value.length)

    /** No C0 or DEL control characters; the wire refuses them in prose fields. */
    fun hasNoControlCharacters(value: String): Boolean =
        value.none { it.code < 0x20 || it.code == 0x7f }

    /** An accent is #RRGGBB, uppercase or lowercase hex. */
    fun isAccent(value: String): Boolean =
        value.length == 7 && value[0] == '#' && value.drop(1).all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }

    /** A launch fragment is empty or starts with #, at most 2048 code points. */
    fun isLaunchFragment(value: String): Boolean =
        value.isEmpty() || (value.startsWith("#") && codePoints(value) <= 2048)

    /** A credential is base64, because it has to be installed as bytes. */
    fun isBase64(value: String): Boolean =
        value.isNotEmpty() && runCatching { Base64.getDecoder().decode(value) }.isSuccess

    /** An expiry is an RFC 3339 UTC instant, because the pending window is computed from it. */
    fun isRfc3339(value: String): Boolean = runCatching { Instant.parse(value) }.isSuccess

    /** A release version name is three dot-separated numbers. */
    fun isVersionName(value: String): Boolean {
        val parts = value.split('.')
        return parts.size == 3 && parts.all { it.isNotEmpty() && it.all(Char::isDigit) }
    }

    /** The release manifest's shape: schema 1, semver, monotone numbers, exactly the three platforms. */
    fun validateRelease(
        schema: Int,
        versionName: String,
        buildNumber: Int,
        protocolVersion: Int,
        platformFields: Set<String>,
    ) {
        require(schema == 1) { "release schema is not 1" }
        require(isVersionName(versionName)) { "release versionName is not semver" }
        require(buildNumber >= 1) { "release buildNumber is not positive" }
        require(protocolVersion >= 1) { "release protocolVersion is not positive" }
        require(platformFields == setOf("androidSdk", "ios", "harmonyApi")) { "release minimumPlatforms names the wrong platforms" }
    }
}
