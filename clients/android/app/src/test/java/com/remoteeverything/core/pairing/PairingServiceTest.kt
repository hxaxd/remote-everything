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
        override val origin: String = "https://gw.example.com"
        override suspend fun pair(request: PairRequest): PairingResponse {
            pairCalls += 1
            return pairResponse ?: error("no pair response")
        }
        override suspend fun activate(nodeId: String): CatalogResponse {
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
        assertNotNull(vault.load("https://gw.example.com"))
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
        // reached — the outcome is a Failed and the staged setup stays.
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
        assertTrue(first is PairingService.Outcome.Failed)
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
}
