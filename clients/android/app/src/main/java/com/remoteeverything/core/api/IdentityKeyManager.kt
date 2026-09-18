package com.remoteeverything.core.api

import com.remoteeverything.core.identity.Pkcs12
import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager

/**
 * Speaks for one identity and no other: the keystore holds one key per gateway,
 * and choosing by key type alone is how a request to one gateway ends up signed
 * by another gateway's key.
 */
class IdentityKeyManager(
    private val alias: String,
    private val material: Pkcs12.Material,
) : X509ExtendedKeyManager() {

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> =
        if (keyType == null || matches(keyType)) arrayOf(alias) else emptyArray()

    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? =
        if (keyType == null || keyType.any { matches(it) }) alias else null

    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> = emptyArray()

    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null

    override fun getCertificateChain(alias: String?): Array<X509Certificate>? =
        if (alias == this.alias) material.chain.toTypedArray() else null

    override fun getPrivateKey(alias: String?): PrivateKey? =
        if (alias == this.alias) material.privateKey else null

    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?): String? =
        chooseClientAlias(keyType, issuers, null)

    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String? = null

    /**
     * What the TLS stack asks with is not always what the key was generated as:
     * an EC key arrives as "EC" from one stack and "EC_EC" from another — the
     * family, then the signature scheme. Matching only the exact name is how a
     * handshake silently finds no certificate.
     */
    private fun matches(keyType: String): Boolean {
        val family = material.privateKey.algorithm.uppercase()
        val requested = keyType.uppercase()
        return requested == family || requested.startsWith(family + "_")
    }
}
