package com.remoteeverything.core.api

import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.ServerPin
import com.remoteeverything.core.identity.Pkcs12

/**
 * One client per gateway origin, kept for the life of the app: an origin's
 * connection pool is what makes a poll cheap, and rebuilding it per request is
 * how every poll becomes a handshake.
 */
class GatewayClientPool {

    private data class Device(val fingerprint: String, val pin: ServerPin?, val client: GatewayClient)
    private data class PairingKey(val origin: String, val pin: ServerPin?)
    private val clients = mutableMapOf<String, Device>()
    private val pairing = mutableMapOf<PairingKey, GatewayClient>()

    /**
     * The client for an origin whose credential the vault holds; null when the
     * credential is gone or unreadable.
     */
    @Synchronized
    fun deviceClient(identity: Identity, vault: IdentityVault): GatewayClient? {
        val material = vault.load(identity.origin) ?: run {
            clients.remove(identity.origin)
            return null
        }
        val fingerprint = Pkcs12.fingerprint(material.certificate)
        clients[identity.origin]?.takeIf { it.fingerprint == fingerprint && it.pin == identity.serverPin }?.let { return it.client }
        val client = GatewayClients.device(identity.origin, material, identity.serverPin)
        clients[identity.origin] = Device(fingerprint, identity.serverPin, client)
        return client
    }

    /**
     * The client for redeeming an invitation: the same origin, no credential
     * yet, because there is nothing to present until the invitation is spent.
     */
    @Synchronized
    fun pairingClient(origin: String, pin: ServerPin?): GatewayClient {
        pairing.keys.removeAll { it.origin == origin && it.pin != pin }
        return pairing.getOrPut(PairingKey(origin, pin)) { GatewayClients.pairing(origin, pin) }
    }

    /**
     * A credential changed or an origin was forgotten: the client that presented
     * the old one must not be used again.
     */
    @Synchronized
    fun drop(origin: String) {
        clients.remove(origin)
        pairing.keys.removeAll { it.origin == origin }
    }
}
