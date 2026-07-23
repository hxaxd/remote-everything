package com.remoteeverything.app

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ProfileCodecTest {
    private val id = "ab".repeat(32)
    private val fingerprint = "cd".repeat(32)
    private val publicKeyPin = "A".repeat(43) + "="

    @Test
    fun multipleProfilesRoundTripWithoutLosingIdentity() {
        val values = listOf(
            AppConfig.create(id, "LAN", "lan", "https://192.0.2.10:4443", fingerprint, publicKeyPin, "01".repeat(32)),
            AppConfig.create("ef".repeat(32), "Public", "public", "https://remote.example.com", ""),
        )
        assertEquals(values, ProfileCodec.decodeAll(ProfileCodec.encodeAll(values)))
    }

    @Test
    fun unknownOrMissingFieldsAreRejected() {
        val encoded = ProfileCodec.encode(AppConfig.create(id, "LAN", "lan", "https://192.0.2.10:4443", fingerprint, publicKeyPin, "01".repeat(32)))
        encoded.put("legacy", true)
        assertThrows(IllegalArgumentException::class.java) { ProfileCodec.decode(encoded) }
        val missing = JSONObject(encoded.toString()).apply { remove("origin"); remove("legacy") }
        assertThrows(IllegalArgumentException::class.java) { ProfileCodec.decode(missing) }
    }
}
