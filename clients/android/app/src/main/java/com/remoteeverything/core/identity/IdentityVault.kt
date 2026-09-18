package com.remoteeverything.core.identity

import com.remoteeverything.core.model.Digest
import java.security.KeyStore

/**
 * Where a gateway's credential lives once its key is no longer ours to export.
 * One entry per origin; the entry is the identity — losing it means the origin
 * must be paired again, and pretending otherwise is how a client ends up with a
 * record of a connection it can no longer make.
 */
interface IdentityVault {
    fun store(origin: String, material: Pkcs12.Material)
    fun load(origin: String): Pkcs12.Material?
    fun delete(origin: String)
}

/** The alias an origin's key is held under: stable, ASCII, and not the origin itself. */
fun credentialAlias(origin: String): String =
    "re-" + Digest.toHex(Digest.sha256(origin.toByteArray(Charsets.UTF_8))).take(16)

/**
 * Android's own key store. A key imported here is not exportable afterwards —
 * what comes back is a handle that signs inside the keystore — which is the
 * strongest of the three platforms and the reason the private key is imported
 * rather than kept as sealed bytes the app itself can open.
 */
class AndroidKeyStoreIdentityVault : IdentityVault {

    private val keyStore: KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    override fun store(origin: String, material: Pkcs12.Material) {
        val alias = credentialAlias(origin)
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }
        keyStore.setKeyEntry(alias, material.privateKey, null, material.chain.toTypedArray())
    }

    override fun load(origin: String): Pkcs12.Material? {
        val alias = credentialAlias(origin)
        val entry = try {
            keyStore.getEntry(alias, null) as? KeyStore.PrivateKeyEntry
        } catch (e: Exception) {
            // A keystore can lose an entry (a lock screen change on some devices, a
            // wiped keystore). That is "pair again", not "something went wrong".
            return null
        } ?: return null
        val chain = entry.certificateChain.mapNotNull { it as? java.security.cert.X509Certificate }
        if (chain.isEmpty()) return null
        return Pkcs12.Material(entry.privateKey, chain)
    }

    override fun delete(origin: String) {
        keyStore.deleteEntry(credentialAlias(origin))
    }
}
