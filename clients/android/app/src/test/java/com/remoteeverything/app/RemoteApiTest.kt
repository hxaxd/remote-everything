package com.remoteeverything.app

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class RemoteApiTest {
    private val config = AppConfig.create(
        "ab".repeat(32),
        "Public",
        "public",
        "https://remote.example.com",
    )

    @Test
    fun catalogRequiresExactSchemaAndConsistentApplicationState() {
        val valid = """{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","launch_fragment":"#workspace=main","computer_connected":true,"enabled":false,"running":false,"code":"stopped"}]}"""
        val snapshot = RemoteApi.decodeCatalog(config, JSONObject(valid))
        assertEquals("stopped", snapshot.apps.single().code)
        assertEquals("https://remote.example.com/__remote_everything/open/editor#workspace=main", snapshot.apps.single().openUrl)

        val unknownTopLevel = JSONObject(valid).put("legacy", true)
        assertThrows(IllegalArgumentException::class.java) {
            RemoteApi.decodeCatalog(config, unknownTopLevel)
        }

        val inconsistentState = JSONObject(valid)
        inconsistentState.getJSONArray("apps").getJSONObject(0).put("code", "ready")
        assertThrows(IllegalArgumentException::class.java) {
            RemoteApi.decodeCatalog(config, inconsistentState)
        }
    }

    @Test
    fun offlineCatalogMustBeEmptyAndPairingDeadlineMustBeAnInstant() {
        val invalidOffline = JSONObject("""{"ok":true,"computer_connected":false,"code":"computer_offline","apps":[{}]}""")
        assertThrows(RuntimeException::class.java) {
            RemoteApi.decodeCatalog(config, invalidOffline)
        }

        val invalidPairing = JSONObject("""{"ok":true,"device_name":"phone","certificate_fingerprint":"${"cd".repeat(32)}","credential_format":"pkcs12","credential_pkcs12":"credential","pending_expires_at":"later"}""")
        assertThrows(IllegalArgumentException::class.java) {
            RemoteApi.decodePairingCredential(invalidPairing)
        }
    }

    @Test
    fun actionCannotSucceedWithMissingOrInconsistentState() {
        val valid = JSONObject("""{"ok":true,"action":"start","computer_connected":true,"enabled":true,"running":false,"code":"starting","app":{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","launch_fragment":"","computer_connected":true,"enabled":true,"running":false,"code":"starting"}}""")
        assertEquals(true, RemoteApi.decodeAction(config, "start", valid))

        assertThrows(IllegalArgumentException::class.java) {
            RemoteApi.decodeAction(config, "start", JSONObject("""{"ok":true}"""))
        }
        valid.put("running", true)
        assertThrows(IllegalArgumentException::class.java) {
            RemoteApi.decodeAction(config, "start", valid)
        }
    }
}
