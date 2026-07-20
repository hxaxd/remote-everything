package com.remoteeverything.app

import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AppConfigTest {
    private val id = "ab".repeat(32)

    @Test
    fun parsesStrictLanSetup() {
        val setup = AppConfig.parseSetup(
            setupUri(
                "v" to "1",
                "id" to id,
                "name" to "Home PC",
                "mode" to "lan",
                "origin" to "https://192.168.1.5:60001",
                "fingerprint" to "cd".repeat(32),
            ),
        )
        assertEquals(id, setup.profile.installationId)
        assertEquals("https://192.168.1.5:60001", setup.profile.gatewayOrigin)
        assertEquals("", setup.invitation)
    }

    @Test
    fun parsesStrictPublicSetup() {
        val invitation = "A".repeat(43)
        val setup = AppConfig.parseSetup(
            setupUri(
                "v" to "1",
                "id" to id,
                "name" to "Public PC",
                "mode" to "public",
                "origin" to "https://remote.example.com",
                "invitation" to invitation,
            ),
        )
        assertEquals("public", setup.profile.mode)
        assertEquals(invitation, setup.invitation)
    }

    @Test
    fun rejectsDuplicatesUnknownFieldsAndInsecureOrigins() {
        val base = setupUri(
            "v" to "1",
            "id" to id,
            "name" to "PC",
            "mode" to "lan",
            "origin" to "http://127.0.0.1:58626",
            "fingerprint" to "cd".repeat(32),
        )
        assertThrows(IllegalArgumentException::class.java) { AppConfig.parseSetup(base) }
        assertThrows(IllegalArgumentException::class.java) { AppConfig.parseSetup(base.replace("http%3A", "https%3A") + "&mode=lan") }
        assertThrows(IllegalArgumentException::class.java) { AppConfig.parseSetup(base.replace("http%3A", "https%3A") + "&extra=x") }
        assertThrows(IllegalArgumentException::class.java) { AppConfig.create(id, "PC", "public", "https://remote.example.com:0") }
    }

    @Test
    fun countsNamesByUnicodeCodePoint() {
        val emoji = "😀"
        AppConfig.create(id, emoji.repeat(80), "public", "https://remote.example.com")
        assertThrows(IllegalArgumentException::class.java) {
            AppConfig.create(id, emoji.repeat(81), "public", "https://remote.example.com")
        }
    }

    private fun setupUri(vararg entries: Pair<String, String>): String =
        "remote-everything://setup?" + entries.joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }

    private fun encode(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8.name())
}
