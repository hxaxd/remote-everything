package com.remoteeverything.core.pairing

import com.remoteeverything.core.api.GatewayClient
import com.remoteeverything.core.api.CatalogCode
import com.remoteeverything.core.api.CatalogResponse
import com.remoteeverything.core.api.ControlResponse
import com.remoteeverything.core.api.NodesResponse
import com.remoteeverything.core.api.PairRequest
import com.remoteeverything.core.api.PairingResponse
import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.identity.Pkcs12
import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.setup.SetupUri
import com.remoteeverything.core.store.IdentityRepository
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.util.Base64
import java.util.Date

class PairingServiceTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private class FakeVault : IdentityVault {
        val stored = mutableMapOf<String, Pkcs12.Material>()
        override fun store(origin: String, material: Pkcs12.Material) { stored[origin] = material }
        override fun load(origin: String): Pkcs12.Material? = stored[origin]
        override fun delete(origin: String) { stored.remove(origin) }
    }

    private class FakeRepo : IdentityRepository {
        override suspend fun updateIdentities(transform: (List<Identity>) -> List<Identity>) {
            saveIdentities(transform(currentIdentities()))
        }
        var list = listOf<Identity>()
        override suspend fun currentIdentities(): List<Identity> = list
        override suspend fun saveIdentities(identities: List<Identity>) { this.list = identities }
    }

    private fun generatePkcs12(password: String): Pair<String, String> {
        val keyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val now = System.currentTimeMillis()
        val name = X500Name("CN=test-device")
        val builder = JcaX509v3CertificateBuilder(
            name,
            BigInteger.valueOf(now),
            Date(now - 60_000),
            Date(now + 86_400_000),
            name,
            keyPair.public,
        )
        val cert = JcaX509CertificateConverter().getCertificate(
            builder.build(JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private)),
        )
        val store = KeyStore.getInstance("PKCS12").apply { load(null, null) }
        store.setKeyEntry("device", keyPair.private, password.toCharArray(), arrayOf(cert))
        val bytes = ByteArrayOutputStream().also { store.store(it, password.toCharArray()) }.toByteArray()
        val p12Base64 = Base64.getEncoder().encodeToString(bytes)
        val fingerprint = Pkcs12.fingerprint(cert)
        return p12Base64 to fingerprint
    }

    private class TestApiClient(
        var pairResponse: PairingResponse? = null,
        var activateResponse: CatalogResponse? = null,
        var activateError: ClientError? = null,
    ) : GatewayClient {
        var pairCalls = 0
        var activateCalls = 0
        var beforeActivate: (suspend () -> Unit)? = null
        var beforePair: (suspend () -> Unit)? = null
        var pairError: Exception? = null
        val requests = mutableListOf<PairRequest>()
        override val origin: String = "https://gw.example.com"
        override suspend fun pair(request: PairRequest): PairingResponse {
            pairCalls += 1
            beforePair?.invoke()
            requests.add(request)
            pairError?.let { throw it }
            return pairResponse ?: error("no pair response")
        }
        override suspend fun activate(nodeId: String): CatalogResponse {
            activateCalls++
            beforeActivate?.invoke()
            activateError?.let { throw it }
            return activateResponse ?: CatalogResponse(ok = true, computer_connected = true, code = CatalogCode.READY, apps = emptyList())
        }
        override suspend fun nodes(): NodesResponse = error("unused")
        override suspend fun catalog(nodeId: String): CatalogResponse = error("unused")
        override suspend fun status(nodeId: String, appId: String): ControlResponse = error("unused")
        override suspend fun start(nodeId: String, appId: String): ControlResponse = error("unused")
        override suspend fun stop(nodeId: String, appId: String): ControlResponse = error("unused")
        override suspend fun open(nodeId: String, appId: String): String = error("unused")
    }

    @Test
    fun `two-round pairing activates and promotes identity when gateway approves immediately`() = runBlocking {
        val vault = FakeVault()
        val repo = FakeRepo()
        val stagedFile = tempFolder.newFile("staged.json")
        val transaction = SetupTransaction(stagedFile)
        val fixedPassword = "test-password-12345"
        val (p12, fp) = generatePkcs12(fixedPassword)

        val client = TestApiClient(
            pairResponse = PairingResponse(
                ok = true,
                device_name = "MyPhone",
                certificate_fingerprint = fp,
                credential_format = "pkcs12",
                credential_pkcs12 = p12,
                pending_expires_at = "2099-01-01T00:00:00Z",
            ),
            activateResponse = CatalogResponse(ok = true, computer_connected = true, code = CatalogCode.READY, apps = emptyList()),
        )

        val service = PairingService(
            vault = vault,
            transaction = transaction,
            repository = repo,
            generatePassword = { fixedPassword },
            clientFactory = { _, _, _ -> client },
        )

        val invitation = SetupUri.Invitation(
            node = "a".repeat(64),
            nodeName = "MacBook",
            origin = "https://gw.example.com",
            invitation = "invitation-token-12345".padEnd(43, 'x'),
            serverPin = null,
        )

        val outcome = service.run(invitation, "MyPhone")
        assertTrue(outcome is PairingService.Outcome.Activated)
        assertEquals("https://gw.example.com", (outcome as PairingService.Outcome.Activated).identity.origin)
        assertEquals("MyPhone", outcome.identity.deviceName)

        // Identity stored in vault and repository
        assertNotNull(vault.load(repo.currentIdentities().single().credentialRef))
        assertEquals(1, repo.currentIdentities().size)
        // Staged setup was cleared on activation
        assertNull(transaction.load())
    }

    @Test
    fun `two-round pairing halts at pending approval and can be resumed`() = runBlocking {
        val vault = FakeVault()
        val repo = FakeRepo()
        val stagedFile = tempFolder.newFile("staged.json")
        val transaction = SetupTransaction(stagedFile)
        val fixedPassword = "test-password-12345"
        val (p12, fp) = generatePkcs12(fixedPassword)

        val client = TestApiClient(
            pairResponse = PairingResponse(
                ok = true,
                device_name = "Pixel",
                certificate_fingerprint = fp,
                credential_format = "pkcs12",
                credential_pkcs12 = p12,
                pending_expires_at = "2099-01-01T00:00:00Z",
            ),
            activateError = ClientError(ErrorCode.APPROVAL_PENDING, 202),
        )

        val service = PairingService(
            vault = vault,
            transaction = transaction,
            repository = repo,
            generatePassword = { fixedPassword },
            clientFactory = { _, _, _ -> client },
        )

        val invitation = SetupUri.Invitation(
            node = "a".repeat(64),
            nodeName = "Studio",
            origin = "https://gw.example.com",
            invitation = "invitation-token-12345".padEnd(43, 'x'),
            serverPin = null,
        )

        val outcome = service.run(invitation, "Pixel")
        assertTrue(outcome is PairingService.Outcome.ApprovalPending)
        assertEquals("Studio", (outcome as PairingService.Outcome.ApprovalPending).nodeName)

        // Staged setup remains on disk
        assertNotNull(transaction.load())
        assertEquals(0, repo.currentIdentities().size)

        // Operator now approves on the gateway: next activate succeeds
        client.activateError = null
        client.activateResponse = CatalogResponse(ok = true, computer_connected = true, code = CatalogCode.READY, apps = emptyList())

        val resumeOutcome = service.resume()
        assertTrue(resumeOutcome is PairingService.Outcome.Activated)
        assertEquals(1, repo.currentIdentities().size)
        assertNull(transaction.load())
    }

    @Test
    fun `joining again after a failed activation resumes the staged pairing instead of re-pairing`() = runBlocking {
        val vault = FakeVault()
        val repo = FakeRepo()
        val stagedFile = tempFolder.newFile("staged.json")
        val transaction = SetupTransaction(stagedFile)
        val fixedPassword = "test-password-12345"
        val (p12, fp) = generatePkcs12(fixedPassword)

        // The redeem succeeds; the activation fails because the node cannot be
        // reached — the outcome is waiting and the staged setup stays.
        val client = TestApiClient(
            pairResponse = PairingResponse(
                ok = true,
                device_name = "Pixel",
                certificate_fingerprint = fp,
                credential_format = "pkcs12",
                credential_pkcs12 = p12,
                pending_expires_at = "2099-01-01T00:00:00Z",
            ),
            activateError = ClientError(ErrorCode.COMPUTER_OFFLINE, 200),
        )
        val service = PairingService(
            vault = vault,
            transaction = transaction,
            repository = repo,
            generatePassword = { fixedPassword },
            clientFactory = { _, _, _ -> client },
        )
        val invitation = SetupUri.Invitation(
            node = "a".repeat(64),
            nodeName = "Studio",
            origin = "https://gw.example.com",
            invitation = "invitation-token-12345".padEnd(43, 'x'),
            serverPin = null,
        )

        val first = service.run(invitation, "Pixel")
        assertTrue(first is PairingService.Outcome.ApprovalPending)
        assertEquals(1, client.pairCalls)
        assertNotNull(transaction.load())

        // The operator taps Join again on the same invitation. The invitation is
        // spent — redeeming it once more would be answered invitation_denied —
        // so the second run finishes what was staged instead of pairing anew.
        client.activateError = null
        val second = service.run(invitation, "Pixel")
        assertTrue(second is PairingService.Outcome.Activated)
        assertEquals("the spent invitation is never redeemed twice", 1, client.pairCalls)
        assertEquals(1, repo.currentIdentities().size)
        assertNull(transaction.load())
    }

    @Test fun `lost redeem reply retries the exact request with its original password and device name`() = runBlocking {
        val password = "test-password-12345"
        val (archive,fingerprint) = generatePkcs12(password)
        val client = TestApiClient(pairResponse = PairingResponse(true,"Pixel",fingerprint,"pkcs12",archive,"2099-01-01T00:00:00Z"))
        client.pairError = java.io.IOException("reply lost")
        var generated = 0
        val service = PairingService(FakeVault(),SetupTransaction(tempFolder.newFile("lost.json")),FakeRepo(),
            generatePassword = { generated++;password },clientFactory = { _,_,_ -> client })
        val invitation = SetupUri.Invitation("a".repeat(64),"Studio",client.origin,"b".repeat(43),null)
        assertTrue(service.run(invitation,"Pixel") is PairingService.Outcome.Failed)
        client.pairError = null
        assertTrue(service.run(invitation,"Edited name") is PairingService.Outcome.Activated)
        assertEquals(1,generated)
        assertEquals(client.requests.first(),client.requests.last())
    }

    @Test fun `approval retries share an in-flight check and cannot restart in background`() = runBlocking {
        val password = "test-password-12345"
        val (archive, fingerprint) = generatePkcs12(password)
        val client = TestApiClient(
            pairResponse = PairingResponse(true, "Pixel", fingerprint, "pkcs12", archive, "2099-01-01T00:00:00Z"),
            activateError = ClientError(ErrorCode.APPROVAL_PENDING, 202),
        )
        val service = PairingService(FakeVault(), SetupTransaction(tempFolder.newFile("polling.json")), FakeRepo(),
            generatePassword = { password }, clientFactory = { _, _, _ -> client })
        val invitation = SetupUri.Invitation("a".repeat(64), "Studio", client.origin, "b".repeat(43), null)
        assertTrue(service.run(invitation, "Pixel") is PairingService.Outcome.ApprovalPending)
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        val reply = kotlinx.coroutines.CompletableDeferred<Unit>()
        client.beforeActivate = { entered.complete(Unit); reply.await() }
        val job = kotlinx.coroutines.SupervisorJob()
        val scope = kotlinx.coroutines.CoroutineScope(job + kotlinx.coroutines.Dispatchers.Unconfined)
        try {
            val session = com.remoteeverything.app.PairingSession(scope, service, {})
            session.foregroundChanged(true)
            entered.await()
            session.resumePendingPairing(client.origin)
            assertEquals(2, client.activateCalls)
            assertEquals(setOf(client.origin), session.checking.value)
            session.foregroundChanged(false)
            reply.complete(Unit)
            kotlinx.coroutines.yield()
            assertTrue(session.checking.value.isEmpty())
            assertEquals(1, session.pending.value.size)
            assertTrue(job.children.none { it.isActive })
        } finally { job.cancel() }
    }

    @Test fun `fast approval feedback stays visible and deduplicates retries until its minimum completes`() = runBlocking {
        val password = "test-password-12345"
        val (archive, fingerprint) = generatePkcs12(password)
        val client = TestApiClient(
            pairResponse = PairingResponse(true, "Pixel", fingerprint, "pkcs12", archive, "2099-01-01T00:00:00Z"),
            activateError = ClientError(ErrorCode.APPROVAL_PENDING, 202),
        )
        val service = PairingService(FakeVault(), SetupTransaction(tempFolder.newFile("feedback.json")), FakeRepo(),
            generatePassword = { password }, clientFactory = { _, _, _ -> client })
        val invitation = SetupUri.Invitation("a".repeat(64), "Studio", client.origin, "b".repeat(43), null)
        assertTrue(service.run(invitation, "Pixel") is PairingService.Outcome.ApprovalPending)
        val job = kotlinx.coroutines.SupervisorJob()
        val scope = kotlinx.coroutines.CoroutineScope(job + kotlinx.coroutines.Dispatchers.Unconfined)
        try {
            val session = com.remoteeverything.app.PairingSession(scope, service, {})
            val started = System.nanoTime()
            session.foregroundChanged(true)
            assertEquals(setOf(client.origin), session.checking.value)
            session.resumePendingPairing(client.origin)
            assertEquals(2, client.activateCalls)
            kotlinx.coroutines.withTimeout(4_000) {
                while (session.checking.value.isNotEmpty()) kotlinx.coroutines.delay(10)
            }
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue("feedback ended at $elapsedMs ms", elapsedMs >= com.remoteeverything.core.model.Cadence.approvalFeedbackMinMs)
            session.foregroundChanged(false)
        } finally { job.cancel() }
    }

    @Test fun `cancelled replacement preserves existing credentials and all other gateway connections`() = runBlocking {
        val password = "test-password-12345"
        val (archive, fingerprint) = generatePkcs12(password)
        val material = Pkcs12.load(Base64.getDecoder().decode(archive), password)
        val vault = FakeVault()
        val repo = FakeRepo()
        val old = Identity("https://gw.example.com", "Old", fingerprint, "old-key", null, 1)
        val other = old.copy(origin = "https://other.example", credentialRef = "other-key")
        repo.list = listOf(old, other)
        vault.store(old.credentialRef, material); vault.store(other.credentialRef, material)
        val client = TestApiClient(PairingResponse(true,"New",fingerprint,"pkcs12",archive,"2099-01-01T00:00:00Z"), activateError=ClientError(ErrorCode.APPROVAL_PENDING,202))
        val service = PairingService(vault,SetupTransaction(tempFolder.newFile("preserve.json")),repo,
            generatePassword={password},clientFactory={_,_,_->client})
        val invitation = SetupUri.Invitation("a".repeat(64),"New node",old.origin,"b".repeat(43),null)
        assertTrue(service.run(invitation,"New") is PairingService.Outcome.ApprovalPending)
        val staged = service.pendingSetups().single()
        assertTrue(staged.credentialRef != old.credentialRef)
        assertTrue(vault.load(old.credentialRef) === material)
        service.discardStaged(old.origin)
        assertEquals(listOf(old,other),repo.list)
        assertTrue(vault.load(old.credentialRef) === material)
        assertTrue(vault.load(other.credentialRef) === material)
        assertNull(vault.load(staged.credentialRef))
        assertTrue(service.run(invitation.copy(invitation="c".repeat(43)),"New") is PairingService.Outcome.ApprovalPending)
        client.activateError = null
        val approved = service.resume() as PairingService.Outcome.Activated
        assertEquals(other,repo.list.first { it.origin == other.origin })
        assertEquals(approved.identity,repo.list.first { it.origin == old.origin })
        assertNull(vault.load(old.credentialRef))
        assertNotNull(vault.load(approved.identity.credentialRef))
    }

    @Test fun `a superseded redeem reply cannot restore its cancelled request`() = runBlocking {
        val password = "test-password-12345"
        val (archive, fingerprint) = generatePkcs12(password)
        val response = PairingResponse(true,"Phone",fingerprint,"pkcs12",archive,"2099-01-01T00:00:00Z")
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        val reply = kotlinx.coroutines.CompletableDeferred<Unit>()
        val oldClient = TestApiClient(response,activateError=ClientError(ErrorCode.APPROVAL_PENDING,202)).apply {
            beforePair = { entered.complete(Unit); reply.await() }
        }
        val newClient = TestApiClient(response,activateError=ClientError(ErrorCode.APPROVAL_PENDING,202))
        val repo=FakeRepo(); val vault=FakeVault()
        val service=PairingService(vault,SetupTransaction(tempFolder.newFile("superseded.json")),repo,
            generatePassword={password},clientFactory={origin,_,_->if(origin=="https://old.example")oldClient else newClient})
        val oldInvite=SetupUri.Invitation("a".repeat(64),"Old","https://old.example","b".repeat(43),null)
        val oldRun=async { service.run(oldInvite,"Phone") }
        entered.await()
        val newInvite=oldInvite.copy(origin="https://new.example",node="c".repeat(64),invitation="d".repeat(43))
        assertTrue(service.run(newInvite,"Phone") is PairingService.Outcome.ApprovalPending)
        val latest=service.pendingSetups().single()
        reply.complete(Unit)
        assertTrue(oldRun.await() is PairingService.Outcome.Failed)
        assertEquals(listOf(latest),service.pendingSetups())
        assertEquals(newInvite.origin,latest.origin)
        assertTrue(repo.list.isEmpty())
    }

    @Test fun `an approval arriving after cancel cannot replace an existing identity`() = runBlocking {
        val password="test-password-12345"
        val (archive,fingerprint)=generatePkcs12(password)
        val entered=kotlinx.coroutines.CompletableDeferred<Unit>();val reply=kotlinx.coroutines.CompletableDeferred<Unit>()
        val client=TestApiClient(PairingResponse(true,"Phone",fingerprint,"pkcs12",archive,"2099-01-01T00:00:00Z")).apply {
            beforeActivate={entered.complete(Unit);reply.await()}
        }
        val repo=FakeRepo();val old=Identity(client.origin,"Old",fingerprint,"live",null,0);repo.list=listOf(old)
        val vault=FakeVault();val material=Pkcs12.load(Base64.getDecoder().decode(archive),password);vault.store("live",material)
        val service=PairingService(vault,SetupTransaction(tempFolder.newFile("late-approval.json")),repo,
            generatePassword={password},clientFactory={_,_,_->client})
        val run=async { service.run(SetupUri.Invitation("a".repeat(64),"Desk",client.origin,"b".repeat(43),null),"Phone") }
        entered.await();service.cancelPending();reply.complete(Unit)
        assertTrue(run.await() is PairingService.Outcome.Failed)
        assertEquals(listOf(old),repo.list);assertTrue(vault.load("live")===material)
        assertTrue(service.pendingSetups().isEmpty())
    }

    @Test fun `only the latest pending record survives restart`() {
        val file = tempFolder.newFile("multiple.json")
        val store = SetupTransaction(file)
        val first = StagedSetup(origin="https://one.example",nodeId="a".repeat(64),nodeName="One",deviceName="Phone",
            certificateFingerprint="f".repeat(64),credentialRef="pending-one",pendingExpiresAtEpochMs=9999999999999,createdAtEpochMs=0)
        val second = first.copy(origin="https://two.example",nodeName="Two")
        store.stage(first); store.stage(second)
        val restarted = SetupTransaction(file)
        assertEquals(listOf(second),restarted.loadAll())
        restarted.clear(first.origin)
        assertEquals(listOf(second),SetupTransaction(file).loadAll())
    }
}
