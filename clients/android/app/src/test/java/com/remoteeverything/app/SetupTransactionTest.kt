package com.remoteeverything.app

import java.security.PrivateKey
import java.security.cert.X509Certificate
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupTransactionTest {
    private val installationId = "ab".repeat(32)
    private val lanConfig = AppConfig.create(installationId, "LAN", "lan", "https://192.0.2.1:60000", "cd".repeat(32))
    private val publicConfig = AppConfig.create(installationId, "Public", "public", "https://remote.example.com")

    @Test
    fun recoveryKeepsOnlyAnActivatablePublicTransaction() {
        val profileStore = FakeProfileStore(publicConfig)
        val identityStore = FakeIdentityStore(staged = true)
        SetupTransaction(profileStore, identityStore, "device", FakeTransport()).recover()
        assertSame(publicConfig, profileStore.staged)
        assertFalse(identityStore.discarded)

        profileStore.staged = lanConfig
        SetupTransaction(profileStore, identityStore, "device", FakeTransport()).recover()
        assertNull(profileStore.staged)
        assertTrue(identityStore.discarded)
    }

    @Test
    fun lanConnectionVerifiesBeforeCommitting() {
        val profileStore = FakeProfileStore()
        val identityStore = FakeIdentityStore()
        val transport = FakeTransport().apply {
            verify = { config ->
                assertSame(lanConfig, config)
                assertNull(profileStore.staged)
            }
        }
        val result = SetupTransaction(profileStore, identityStore, "device", transport)
            .connect(SetupPayload(lanConfig, ""))
        assertSame(lanConfig, result)
        assertSame(lanConfig, profileStore.committed)
        assertNull(profileStore.staged)
    }

    @Test
    fun publicConnectionStagesThenPairsAndAtomicallyPromotes() {
        val profileStore = FakeProfileStore()
        val identityStore = FakeIdentityStore()
        val transport = FakeTransport().apply {
            respond = { url, headers, body ->
                assertSame(publicConfig, profileStore.staged)
                if (url == publicConfig.pairUrl) {
                    assertEquals("Invitation ${"A".repeat(43)}", headers["Authorization"])
                    val sentName = JSONObject(body!!).getString("device_name")
                    assertEquals(80, sentName.codePointCount(0, sentName.length))
                    HttpResult(200, """{"ok":true,"device_name":"device","certificate_fingerprint":"${"cd".repeat(32)}","credential_format":"pkcs12","credential_pkcs12":"credential","pending_expires_at":"2027-01-01T00:00:00Z"}""")
                } else {
                    assertEquals(publicConfig.activateUrl, url)
                    assertTrue(identityStore.staged)
                    HttpResult(200, """{"ok":true,"computer_connected":true,"code":"ready","apps":[]}""")
                }
            }
        }
        val result = SetupTransaction(profileStore, identityStore, "😀".repeat(81), transport)
            .connect(SetupPayload(publicConfig, "A".repeat(43)))
        assertSame(publicConfig, result)
        assertSame(publicConfig, profileStore.committed)
        assertNull(profileStore.staged)
        assertTrue(identityStore.promoted)
    }

    @Test
    fun malformedActivationCannotCommitProfileOrCredential() {
        val profileStore = FakeProfileStore(publicConfig)
        val identityStore = FakeIdentityStore(staged = true)
        val transport = FakeTransport().apply {
            respond = { _, _, _ -> HttpResult(200, """{"ok":true,"computer_connected":true}""") }
        }
        assertThrows(IllegalArgumentException::class.java) {
            SetupTransaction(profileStore, identityStore, "device", transport).activate(publicConfig)
        }
        assertNull(profileStore.committed)
        assertSame(publicConfig, profileStore.staged)
        assertFalse(identityStore.promoted)
    }

    private class FakeProfileStore(var staged: ConnectionConfig? = null) : SetupProfileStore {
        var committed: ConnectionConfig? = null
        override fun stagedProfile(): ConnectionConfig? = staged
        override fun stageProfile(value: ConnectionConfig) { staged = value }
        override fun commitStagedProfile(): ConnectionConfig = requireNotNull(staged).also { committed = it }
        override fun discardStagedProfile() { staged = null }
    }

    private class FakeIdentityStore(var staged: Boolean = false) : SetupIdentityStore {
        var discarded = false
        var promoted = false
        override fun credentialPassword(installationId: String): String = "password"
        override fun stageCredential(installationId: String, encoded: String, password: String) { staged = true }
        override fun stagedClientIdentity(installationId: String): ClientIdentity = ClientIdentity(FakePrivateKey, emptyArray<X509Certificate>())
        override fun promoteCredential(installationId: String) { require(staged); promoted = true; staged = false }
        override fun hasStagedCredential(installationId: String): Boolean = staged
        override fun discardStagedCredential(installationId: String) { discarded = true; staged = false }
    }

    private class FakeTransport : SetupTransport {
        var verify: (ConnectionConfig) -> Unit = {}
        var respond: (String, Map<String, String>, String?) -> HttpResult = { _, _, _ -> error("unexpected request") }
        override fun verifyCatalog(config: ConnectionConfig) = verify(config)
        override fun request(
            config: ConnectionConfig,
            url: String,
            method: String,
            identity: ClientIdentity?,
            headers: Map<String, String>,
            body: String?,
        ): HttpResult = respond(url, headers, body)
    }

    private object FakePrivateKey : PrivateKey {
        override fun getAlgorithm(): String = "EC"
        override fun getFormat(): String? = null
        override fun getEncoded(): ByteArray? = null
    }
}
