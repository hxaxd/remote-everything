package com.remoteeverything.app

import java.security.PrivateKey
import java.security.cert.X509Certificate
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupTransactionTest {
    private val installationId = "ab".repeat(32)
    private val lanConfig = AppConfig.create(installationId, "LAN", "lan", "https://192.0.2.1:60000", "cd".repeat(32), "A".repeat(43) + "=")
    private val lanSetup = SetupPayload(lanConfig, "B".repeat(43))
    private val publicConfig = AppConfig.create(installationId, "Public", "public", "https://remote.example.com")
    private val setup = SetupPayload(publicConfig, "A".repeat(43))

    @Test
    fun recoveryReturnsAStagedTransactionWhileItsCredentialSurvived() {
        val profileStore = FakeProfileStore(publicConfig)
        val identityStore = FakeIdentityStore(staged = true)
        assertSame(publicConfig, SetupTransaction(profileStore, identityStore, "device", FakeTransport()).recover())
        assertSame(publicConfig, profileStore.staged)

        // Both modes pair for a credential now, so both survive an interruption.
        profileStore.staged = lanConfig
        assertSame(lanConfig, SetupTransaction(profileStore, identityStore, "device", FakeTransport()).recover())

        // A staged profile whose credential is gone cannot be activated.
        val lostCredential = FakeIdentityStore()
        assertNull(SetupTransaction(profileStore, lostCredential, "device", FakeTransport()).recover())
        assertNull(profileStore.staged)
    }

    // A LAN entrance admits devices the way the public one does: the client
    // redeems its invitation for a credential and then activates it. Only the
    // approval differs, and that is the server's answer to make.
    @Test
    fun lanConnectionPairsAndActivatesLikeThePublicOne() {
        val profileStore = FakeProfileStore()
        val identityStore = FakeIdentityStore()
        val states = mutableListOf<SetupState>()
        val result = SetupTransaction(profileStore, identityStore, "device", successfulTransport(identityStore, lanConfig, lanSetup.invitation))
            .begin(lanSetup, states::add)

        assertTrue(result is SetupState.Ready)
        assertEquals(listOf(SetupState.Pairing(lanConfig), SetupState.Activating(lanConfig, "2027-01-01T00:00:00Z")), states)
        assertSame(lanConfig, profileStore.committed)
        assertNull(profileStore.staged)
        assertTrue(identityStore.promoted)
    }

    @Test
    fun publicConnectionExposesPhasesAndCommitsAfterCredentialPromotion() {
        val order = mutableListOf<String>()
        val profileStore = FakeProfileStore(order = order)
        val identityStore = FakeIdentityStore(order = order)
        val states = mutableListOf<SetupState>()
        val transport = successfulTransport(identityStore, sentName = "😀".repeat(80))
        val result = SetupTransaction(profileStore, identityStore, "😀".repeat(81), transport)
            .begin(setup, states::add)

        assertTrue(result is SetupState.Ready)
        assertEquals(listOf(SetupState.Pairing(publicConfig), SetupState.Activating(publicConfig, "2027-01-01T00:00:00Z")), states)
        assertEquals(listOf("promote", "commit"), order)
        assertTrue(identityStore.promoted)
        assertFalse(identityStore.staged)
        assertNull(profileStore.staged)
    }

    @Test
    fun activationFailureRetriesActivationWithoutPairingAgain() {
        val profileStore = FakeProfileStore()
        val identityStore = FakeIdentityStore()
        var pairCalls = 0
        var activationCalls = 0
        val transport = FakeTransport().apply {
            respond = { url, _, _ ->
                if (url == publicConfig.pairUrl) {
                    pairCalls += 1
                    paired()
                } else {
                    activationCalls += 1
                    if (activationCalls == 1) HttpResult(503, "") else ready()
                }
            }
        }
        val transaction = SetupTransaction(profileStore, identityStore, "device", transport)
        val first = transaction.begin(setup)
        assertTrue(first is SetupState.Failed && first.action == SetupAction.RETRY_ACTIVATION)
        assertTrue(identityStore.staged)

        val second = transaction.retryActivation(publicConfig)
        assertTrue(second is SetupState.Ready)
        assertEquals(1, pairCalls)
        assertEquals(2, activationCalls)
        assertEquals(1, identityStore.passwordCalls)
    }

    @Test
    fun approvalPendingKeepsTransactionAndContinuesWithoutPairingAgain() {
        val profileStore = FakeProfileStore()
        val identityStore = FakeIdentityStore()
        var pairCalls = 0
        var activationCalls = 0
        val transport = FakeTransport().apply {
            respond = { url, _, _ ->
                if (url == publicConfig.pairUrl) {
                    pairCalls += 1
                    paired()
                } else {
                    activationCalls += 1
                    if (activationCalls == 1) HttpResult(202, """{"ok":false,"code":"approval_pending"}""") else ready()
                }
            }
        }
        val transaction = SetupTransaction(profileStore, identityStore, "device", transport)
        val first = transaction.begin(setup)
        assertTrue(first is SetupState.AwaitingApproval)
        assertTrue(identityStore.staged)

        val second = transaction.retryActivation(publicConfig)
        assertTrue(second is SetupState.Ready)
        assertEquals(1, pairCalls)
        assertEquals(2, activationCalls)
    }

    @Test
    fun deniedInvitationAndDeniedActivationDiscardLocalTransaction() {
        val deniedPairProfiles = FakeProfileStore()
        val deniedPairIdentity = FakeIdentityStore()
        val deniedPair = SetupTransaction(
            deniedPairProfiles,
            deniedPairIdentity,
            "device",
            FakeTransport().apply { respond = { _, _, _ -> HttpResult(401, "") } },
        ).begin(setup)
        assertTrue(deniedPair is SetupState.Failed && deniedPair.action == SetupAction.RESTART_SETUP)
        assertNull(deniedPairProfiles.staged)
        assertTrue(deniedPairIdentity.discarded)

        val deniedActivationProfiles = FakeProfileStore()
        val deniedActivationIdentity = FakeIdentityStore()
        val deniedActivation = SetupTransaction(
            deniedActivationProfiles,
            deniedActivationIdentity,
            "device",
            FakeTransport().apply {
                respond = { url, _, _ -> if (url == publicConfig.pairUrl) paired() else HttpResult(401, "") }
            },
        ).begin(setup)
        assertTrue(deniedActivation is SetupState.Failed && deniedActivation.action == SetupAction.RESTART_SETUP)
        assertNull(deniedActivationProfiles.staged)
        assertFalse(deniedActivationIdentity.staged)
    }

    @Test
    fun malformedActivationKeepsPendingCredentialForIdempotentRetry() {
        val profileStore = FakeProfileStore()
        val identityStore = FakeIdentityStore()
        val transport = FakeTransport().apply {
            respond = { url, _, _ -> if (url == publicConfig.pairUrl) paired() else HttpResult(200, """{"ok":true,"computer_connected":true}""") }
        }
        val result = SetupTransaction(profileStore, identityStore, "device", transport).begin(setup)
        assertTrue(result is SetupState.Failed && result.action == SetupAction.RETRY_ACTIVATION)
        assertSame(publicConfig, profileStore.staged)
        assertTrue(identityStore.staged)
        assertFalse(identityStore.promoted)
    }

    private fun successfulTransport(
        identityStore: FakeIdentityStore,
        config: ConnectionConfig = publicConfig,
        invitation: String = "A".repeat(43),
        sentName: String = "device",
    ) = FakeTransport().apply {
        respond = { url, headers, body ->
            if (url == config.pairUrl) {
                assertEquals("Invitation $invitation", headers["Authorization"])
                assertEquals(sentName, JSONObject(body!!).getString("device_name"))
                paired()
            } else {
                assertTrue(identityStore.staged)
                ready()
            }
        }
    }

    private fun paired() = HttpResult(
        200,
        """{"ok":true,"device_name":"device","certificate_fingerprint":"${"cd".repeat(32)}","credential_format":"pkcs12","credential_pkcs12":"credential","pending_expires_at":"2027-01-01T00:00:00Z"}""",
    )

    private fun ready() = HttpResult(200, """{"ok":true,"computer_connected":true,"code":"ready","apps":[]}""")

    private class FakeProfileStore(
        var staged: ConnectionConfig? = null,
        private val order: MutableList<String>? = null,
    ) : SetupProfileStore {
        var committed: ConnectionConfig? = null
        override fun stagedProfile(): ConnectionConfig? = staged
        override fun stageProfile(value: ConnectionConfig) { staged = value }
        override fun commitStagedProfile(): ConnectionConfig = requireNotNull(staged).also {
            order?.add("commit")
            committed = it
        }
        override fun discardStagedProfile() { staged = null }
    }

    private class FakeIdentityStore(
        var staged: Boolean = false,
        private val order: MutableList<String>? = null,
    ) : SetupIdentityStore {
        var discarded = false
        var promoted = false
        var passwordCalls = 0
        override fun credentialPassword(installationId: String): String {
            passwordCalls += 1
            return "password"
        }
        override fun stageCredential(installationId: String, encoded: String, password: String, expectedFingerprint: String) {
            assertEquals("cd".repeat(32), expectedFingerprint)
            staged = true
        }
        override fun stagedClientIdentity(installationId: String): ClientIdentity {
            require(staged)
            return ClientIdentity(FakePrivateKey, emptyArray<X509Certificate>())
        }
        override fun promoteCredential(installationId: String) {
            require(staged)
            order?.add("promote")
            promoted = true
        }
        override fun hasStagedCredential(installationId: String): Boolean = staged
        override fun discardStagedCredential(installationId: String) {
            discarded = true
            staged = false
        }
    }

    private class FakeTransport : SetupTransport {
        var respond: (String, Map<String, String>, String?) -> HttpResult = { _, _, _ -> error("unexpected request") }
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
