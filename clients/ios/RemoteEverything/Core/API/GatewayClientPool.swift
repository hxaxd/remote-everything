import Foundation

/// One client per gateway origin, kept for the life of the app: an origin's
/// connection pool is what makes a poll cheap, and rebuilding it per request is
/// how every poll becomes a handshake.
final class GatewayClientPool {

    private var clients: [String: GatewayClient] = [:]
    private var deviceIdentities: [String: Identity] = [:]
    private var deviceVersions: [String: Int] = [:]
    private var pairingClients: [String: (pin: ServerPin?, client: GatewayClient)] = [:]

    /// The client for an origin whose credential the vault holds. Nil when the
    /// credential is gone: the origin has to be paired again, and saying so is
    /// the caller's job.
    func deviceClient(for identity: Identity, vault: IdentityVault) -> GatewayClient? {
        if deviceIdentities[identity.origin] == identity, deviceVersions[identity.origin] == vault.version(origin:identity.origin), let existing = clients[identity.origin] { return existing }
        guard let credential = vault.prepare(origin: identity.origin) else { return nil }
        let client = GatewayClient(origin: identity.origin, credential: credential, pin: identity.serverPin)
        clients[identity.origin] = client
        deviceIdentities[identity.origin] = identity
        deviceVersions[identity.origin] = vault.version(origin:identity.origin)
        return client
    }

    /// The client for redeeming an invitation: the same origin, no credential
    /// yet, because there is nothing to present until the invitation is spent.
    func pairingClient(origin: String, pin: ServerPin?) -> GatewayClient {
        if let existing = pairingClients[origin], existing.pin == pin { return existing.client }
        let client = GatewayClient(origin: origin, credential: nil, pin: pin)
        pairingClients[origin] = (pin, client)
        return client
    }

    /// A credential changed or an origin was forgotten: the client that presented
    /// the old one must not be used again.
    func drop(origin: String) {
        _ = clients.removeValue(forKey: origin)
        deviceIdentities.removeValue(forKey: origin)
        deviceVersions.removeValue(forKey:origin)
        pairingClients.removeValue(forKey: origin)
    }
}
