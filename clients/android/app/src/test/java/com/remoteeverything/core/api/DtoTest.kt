package com.remoteeverything.core.api

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Strict decoding is the trust boundary (contracts README): unknown keys,
 * missing keys and unknown enum values are all rejected.
 */
class DtoTest {

    private val json = Json { ignoreUnknownKeys = false }

    @Test
    fun `a nodes response decodes`() {
        val response = json.decodeFromString<NodesResponse>(
            """{"ok":true,"nodes":[{"id":"${"a".repeat(64)}","name":"客厅电脑"}]}""",
        )
        assertEquals(1, response.nodes.size)
        assertEquals("客厅电脑", response.nodes[0].name)
    }

    @Test
    fun `an unknown key is rejected`() {
        assertThrows(SerializationException::class.java) {
            json.decodeFromString<NodesResponse>("""{"ok":true,"nodes":[],"surprise":1}""")
        }
    }

    @Test
    fun `a missing key is rejected`() {
        assertThrows(SerializationException::class.java) {
            json.decodeFromString<NodesResponse>("""{"ok":true}""")
        }
    }

    @Test
    fun `an unknown error code is rejected`() {
        assertThrows(SerializationException::class.java) {
            json.decodeFromString<ErrorResponse>("""{"ok":false,"code":"made_up"}""")
        }
    }

    @Test
    fun `every refusal code decodes`() {
        for (code in listOf(
            "node_required", "unauthorized", "invitation_denied", "invitation_expired",
            "approval_pending", "node_not_found", "app_not_found", "not_found", "forbidden",
            "computer_offline", "activation_failed", "invalid_device_name",
            "invalid_credential_password", "invalid_body", "invalid_json", "rate_limited",
            "server_busy", "pairing_failed", "internal_error",
        )) {
            val decoded = json.decodeFromString<ErrorResponse>("""{"ok":false,"code":"$code"}""")
            assertEquals(code, decoded.code.name.lowercase())
        }
    }

    @Test
    fun `an offline catalog decodes with empty apps`() {
        val catalog = json.decodeFromString<CatalogResponse>(
            """{"ok":true,"computer_connected":false,"code":"computer_offline","apps":[]}""",
        )
        assertEquals(CatalogCode.COMPUTER_OFFLINE, catalog.code)
        assertEquals(0, catalog.apps.size)
    }

    @Test
    fun `a full app entry decodes`() {
        val catalog = json.decodeFromString<CatalogResponse>(
            """{"ok":true,"computer_connected":true,"code":"ready","apps":[{
                "id":"jellyfin","name":"Jellyfin","description":"媒体","icon":"🎬",
                "accent":"#2563eb","launch_fragment":"#/home","computer_connected":true,
                "enabled":true,"running":true,"code":"ready"
            }]}""".trimIndent(),
        )
        val app = catalog.apps[0]
        assertEquals(AppCode.READY, app.code)
        assertEquals("🎬", app.icon)
        assertEquals("#/home", app.launch_fragment)
    }

    @Test
    fun `a pairing response decodes`() {
        val pairing = json.decodeFromString<PairingResponse>(
            """{"ok":true,"device_name":"phone","certificate_fingerprint":"${"a".repeat(64)}",
                "credential_format":"pkcs12","credential_pkcs12":"MII",
                "pending_expires_at":"2026-09-17T12:00:00Z"}""".trimIndent(),
        )
        assertEquals("pkcs12", pairing.credential_format)
    }
}
