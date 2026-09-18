package com.remoteeverything.core.api

import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.identity.Pkcs12
import com.remoteeverything.core.model.ServerPin

/**
 * The protocol client, one instance per gateway origin: an origin is what a
 * credential, a pin and a connection belong to, so a client bound to one cannot
 * be asked for another by mistake. Every request except pairing carries the node
 * it is for; the node list is the one request that names none. Application
 * traffic never comes through here — it belongs to the WebView and to the
 * origin `open` answers with.
 */
interface ApiClient {
    val origin: String

    /** Redeem an invitation. The one request made without a credential. */
    suspend fun pair(request: PairRequest): PairingResponse

    /** Be admitted for one node; a pending device is told so, not refused. */
    suspend fun activate(nodeId: String): CatalogResponse

    /** Which nodes this device may reach. */
    suspend fun nodes(): NodesResponse

    suspend fun catalog(nodeId: String): CatalogResponse

    suspend fun status(nodeId: String, appId: String): ControlResponse

    suspend fun start(nodeId: String, appId: String): ControlResponse

    suspend fun stop(nodeId: String, appId: String): ControlResponse

    /** Where the application lives: the absolute origin the WebView loads. */
    suspend fun open(nodeId: String, appId: String): String
}

data class PairRequest(
    val origin: String,
    val invitation: String,
    val deviceName: String,
    val credentialPassword: String,
)

/** Clients are built where a credential is: before pairing, and after it. */
object GatewayClients {

    fun pairing(origin: String, serverPin: ServerPin?): ApiClient =
        OkHttpGatewayClient(origin, material = null, serverPin = serverPin)

    fun device(origin: String, material: Pkcs12.Material, serverPin: ServerPin?): ApiClient =
        OkHttpGatewayClient(origin, material = material, serverPin = serverPin)

    /** A client for an origin whose credential the vault still holds; null when it does not. */
    fun device(origin: String, vault: IdentityVault, serverPin: ServerPin?): ApiClient? {
        val material = vault.load(origin) ?: return null
        return device(origin, material, serverPin)
    }
}
