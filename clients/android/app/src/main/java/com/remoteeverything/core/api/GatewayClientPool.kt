package com.remoteeverything.core.api

import com.remoteeverything.core.identity.IdentityVault
import com.remoteeverything.core.model.Identity
import com.remoteeverything.core.model.ServerPin
import java.util.concurrent.ConcurrentHashMap

/**
 * One client per gateway origin, kept for the life of the app: an origin's
 * connection pool is what makes a poll cheap, and rebuilding it per request is
 * how every poll becomes a handshake.
 */
class GatewayClientPool {

    private val clients = ConcurrentHashMap<String, GatewayClient>()

    /**
     * The client for an origin whose credential the vault holds; null when the
     * credential is gone or unreadable.
     */
    fun deviceClient(identity: Identity, vault: IdentityVault): GatewayClient? {
        clients[identity.origin]?.let { return it }
        val client = GatewayClients.device(identity.origin, vault, identity.serverPin) ?: return null
        clients[identity.origin] = client
        return client
    }

    /**
     * The client for redeeming an invitation: the same origin, no credential
     * yet, because there is nothing to present until the invitation is spent.
     */
    fun pairingClient(origin: String, pin: ServerPin?): GatewayClient {
        val key = "$origin#pairing"
        return clients.computeIfAbsent(key) {
            GatewayClients.pairing(origin, pin)
        }
    }

    /**
     * A credential changed or an origin was forgotten: the client that presented
     * the old one must not be used again.
     */
    fun drop(origin: String) {
        clients.remove(origin)
        clients.remove("$origin#pairing")
    }
}
