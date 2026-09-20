package com.remoteeverything.core.pairing

import com.remoteeverything.core.model.ServerPin
import com.remoteeverything.core.store.AtomicFile
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The one file a pairing leaves behind until it is finished. Pairing is two
 * round trips — redeem the invitation, then be activated — and being killed
 * between them must not consume the invitation: the invitation is single-use,
 * so the client that lost the answer must be able to ask again with what this
 * file remembers. Everything the resumed attempt needs is here at once, which is
 * why it is one file and not a handful of them: one rename is the whole commit.
 *
 * What is deliberately not here: the credential and the password it was opened
 * with. They live in the keystore, which is where a resumed activation finds
 * them, and the password itself only exists long enough to import the key.
 */
@Serializable
data class StagedSetup(
    val schema: Int = 1,
    val origin: String,
    val nodeId: String,
    val nodeName: String,
    val deviceName: String,
    val certificateFingerprint: String,
    val serverPin: ServerPin? = null,
    val pendingExpiresAtEpochMs: Long,
    val createdAtEpochMs: Long,
)

class StagedSetupStore(private val file: File) {

    private val json = Json { ignoreUnknownKeys = false }

    fun stage(staged: StagedSetup) {
        AtomicFile.write(file, json.encodeToString(StagedSetup.serializer(), staged).toByteArray(Charsets.UTF_8))
    }

    /** The staged setup, when there is a readable one. An unreadable file is no setup. */
    fun load(): StagedSetup? {
        val bytes = AtomicFile.read(file) ?: return null
        return try {
            json.decodeFromString(StagedSetup.serializer(), bytes.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            null
        }
    }

    /**
     * What a restart resumes: a staged setup whose pending window is still open.
     * One whose window has passed is dropped — the gateway will not admit it any
     * more, and keeping it would only promise a resumption that cannot happen.
     */
    fun resume(nowEpochMs: Long): StagedSetup? {
        val staged = load() ?: return null
        if (nowEpochMs >= staged.pendingExpiresAtEpochMs) {
            clear()
            return null
        }
        return staged
    }

    fun clear() {
        if (file.exists()) {
            AtomicFile.delete(file)
        }
    }
}

typealias SetupTransaction = StagedSetupStore
