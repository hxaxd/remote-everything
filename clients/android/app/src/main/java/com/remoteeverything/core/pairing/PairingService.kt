package com.remoteeverything.core.pairing

import com.remoteeverything.core.api.GatewayClient
import com.remoteeverything.core.api.GatewayClients
import com.remoteeverything.core.api.PairRequest
import com.remoteeverything.core.api.PairingResponse
import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.identity.Pkcs12
import com.remoteeverything.core.model.ClientError
import com.remoteeverything.core.model.ErrorCode
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.MessageKeys
import com.remoteeverything.core.model.ServerPin
import com.remoteeverything.core.setup.SetupUri
import com.remoteeverything.core.store.SettingsStore
import java.security.SecureRandom
import java.util.Base64
import kotlinx.coroutines.CancellationException

/**
 * Pairing, as two round trips with a restart-safe middle: redeem the invitation
 * for a credential, then be activated with it. The credential is in the vault
 * before anything is written about the connection, so what the client claims and
 * what it can do cannot disagree — and the staged file is what lets an
 * interrupted pairing be finished instead of burning the invitation.
 */
class PairingService(
    private val vault: IdentityVault,
    private val transaction: SetupTransaction,
    private val repository: com.remoteeverything.core.store.IdentityRepository,
    private val generatePassword: () -> String = ::randomCredentialPassword,
    private val clock: () -> Long = System::currentTimeMillis,
    private val clientFactory: ((origin: String, pin: ServerPin?, material: Pkcs12.Material?) -> GatewayClient)? = null,
) {

    sealed interface Outcome {
        data class Activated(val identity: Identity, val nodeName: String = "") : Outcome
        data class ApprovalPending(val nodeName: String) : Outcome
        data class Failed(val code: ErrorCode?, val key: String? = null) : Outcome
    }

    /**
     * A pairing that was interrupted is finished from what it staged: the
     * invitation is spent, but the device it created is still pending, and
     * asking again with the same credential is how it is activated.
     */
    suspend fun resume(): Outcome? {
        val staged = transaction.resume(clock()) ?: return null
        return activate(staged)
    }

    suspend fun run(invitation: SetupUri.Invitation, deviceName: String): Outcome {
        // A pairing whose redeem succeeded but whose activation did not is not
        // redeemed again: the invitation is spent, a second redeem with a fresh
        // password is answered invitation_denied, and finishing what the vault
        // already holds is exactly what resume does. A staged setup for this
        // origin is therefore finished, not paired over — unless its pending
        // window has closed, in which case it is dropped and the server's own
        // answer to a spent invitation is what the user sees.
        val stagedBefore = transaction.load()
        if (stagedBefore != null && stagedBefore.origin == invitation.origin) {
            if (clock() < stagedBefore.pendingExpiresAtEpochMs) {
                return resume() ?: Outcome.Failed(null)
            }
            transaction.clear()
        }
        val password = generatePassword()
        val client = clientFactory?.invoke(invitation.origin, pinOf(invitation), null)
            ?: GatewayClients.pairing(invitation.origin, pinOf(invitation))
        val pairing = try {
            client.pair(
                PairRequest(
                    origin = invitation.origin,
                    invitation = invitation.invitation,
                    deviceName = deviceName,
                    credentialPassword = password,
                ),
            )
        } catch (e: ClientError) {
            return Outcome.Failed(e.code)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return Outcome.Failed(null)
        }
        val staged = try {
            stage(invitation, deviceName, password, pairing)
        } catch (e: Pkcs12.InvalidCredential) {
            // A credential that will not open is this client's fault to name, not
            // the network's: the gateway answered, and what it answered was not a
            // credential this device could take.
            return Outcome.Failed(null, MessageKeys.ERROR_CLIENT)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return Outcome.Failed(null)
        }
        return activate(staged)
    }

    private fun stage(
        invitation: SetupUri.Invitation,
        deviceName: String,
        password: String,
        pairing: PairingResponse,
    ): StagedSetup {
        val credential = Base64.getDecoder().decode(pairing.credential_pkcs12)
        val material = Pkcs12.load(credential, password)
        // The fingerprint the gateway says the certificate has is not taken on
        // faith: the one computed here is the one the client will match later.
        val fingerprint = Pkcs12.fingerprint(material.certificate)
        if (fingerprint != pairing.certificate_fingerprint.lowercase()) {
            throw Pkcs12.InvalidCredential("the credential is not the certificate that was promised")
        }
        Pkcs12.verifyKeyPair(material)
        if (vault.load(invitation.origin) != null) {
            // Pairing the same gateway again replaces the credential it holds;
            // the identity is the vault entry, so the old one has to go first.
            vault.delete(invitation.origin)
        }
        vault.store(invitation.origin, material)
        val staged = StagedSetup(
            origin = invitation.origin,
            nodeId = invitation.node,
            nodeName = invitation.nodeName,
            deviceName = deviceName,
            certificateFingerprint = fingerprint,
            serverPin = pinOf(invitation),
            pendingExpiresAtEpochMs = requireNotNull(parseInstant(pairing.pending_expires_at)) {
                "a pairing expiry the strict decoder accepted is not parseable here"
            },
            createdAtEpochMs = clock(),
        )
        transaction.stage(staged)
        return staged
    }

    private suspend fun activate(staged: StagedSetup): Outcome {
        val material = vault.load(staged.origin)
        val client = if (material != null) {
            clientFactory?.invoke(staged.origin, staged.serverPin, material)
                ?: GatewayClients.device(staged.origin, material, staged.serverPin)
        } else null
        if (client == null) {
            transaction.clear()
            return Outcome.Failed(null)
        }
        return try {
            client.activate(staged.nodeId)
            promote(staged)
            Outcome.Activated(
                Identity(
                    origin = staged.origin,
                    deviceName = staged.deviceName,
                    certFingerprint = staged.certificateFingerprint,
                    credentialRef = staged.origin,
                    serverPin = staged.serverPin,
                    createdAtEpochMs = staged.createdAtEpochMs,
                ),
                nodeName = staged.nodeName,
            )
        } catch (e: ClientError) {
            when (e.code) {
                // Waiting for a human is not a failure: the staged setup stays and
                // the client asks again, which is what pending_expires_at is for.
                ErrorCode.APPROVAL_PENDING -> Outcome.ApprovalPending(staged.nodeName)
                ErrorCode.INVITATION_DENIED, ErrorCode.INVITATION_EXPIRED, ErrorCode.UNAUTHORIZED -> {
                    abandon(staged)
                    Outcome.Failed(e.code)
                }
                else -> Outcome.Failed(e.code)
            }
        } catch (e: CancellationException) {
            // Cancelling is a verdict of its own: the person left. Not a failure
            // of the pairing, and not something to paint as one.
            throw e
        } catch (e: Exception) {
            // A network that is down is not a verdict: keep the staged setup for
            // the retry that a resumed launch or the wizard's next attempt makes.
            Outcome.Failed(null)
        }
    }

    private suspend fun promote(staged: StagedSetup) {
        val identity = Identity(
            origin = staged.origin,
            deviceName = staged.deviceName,
            certFingerprint = staged.certificateFingerprint,
            credentialRef = staged.origin,
            serverPin = staged.serverPin,
            createdAtEpochMs = staged.createdAtEpochMs,
        )
        val existing = repository.currentIdentities().filterNot { it.origin == identity.origin }
        repository.saveIdentities(existing + identity)
        transaction.clear()
    }

    private fun abandon(staged: StagedSetup) {
        vault.delete(staged.origin)
        transaction.clear()
    }

    /**
     * Forgetting a gateway takes the pairing still staged for it: the staged
     * setup of another gateway's pending pairing is not this one's to drop.
     */
    fun discardStaged(origin: String) {
        val staged = transaction.load() ?: return
        if (staged.origin == origin) transaction.clear()
    }

    private fun pinOf(invitation: SetupUri.Invitation): ServerPin? =
        invitation.serverPin?.let { ServerPin(certFingerprint = it.certFingerprint, publicKeyPin = it.publicKeyPin) }

    companion object {
        /**
         * The password the credential is encrypted under: 32 random bytes in the
         * one alphabet the gateway accepts. It never leaves memory — it dies with
         * the staging file it was written to.
         */
        fun randomCredentialPassword(): String {
            val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        }

        /** RFC 3339 instants as the wire writes them; an unreadable one is no instant. */
        fun parseInstant(value: String): Long? = try {
            java.time.Instant.parse(value).toEpochMilli()
        } catch (e: Exception) {
            null
        }
    }
}
