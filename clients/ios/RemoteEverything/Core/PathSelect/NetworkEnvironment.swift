import Foundation
import Network

/// Watches the network's shape so a path choice made on one network is not used
/// on the next one. iOS gives no SSID without location permission, so the key is
/// "which network generation this is": any change of path retires every choice
/// made before it.
final class NetworkEnvironment {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.remoteeverything.network")
    private var generation = 0
    private var satisfied = true
    private var currentTransport = "unknown"
    private var isVpn = false
    private var started = false

    /// Called on the main queue whenever the network changed.
    var onPathChange: (() -> Void)?

    /// The cache key. Read and written on the main thread only.
    var key: String {
        "network-\(generation)-\(satisfied ? "up" : "down")"
    }

    /// Nothing to send on at all: every connection fails the same way, and this says why.
    var isOffline: Bool { !satisfied }

    /// The network as a report should print it. Tokens rather than prose, because a
    /// reader who has the phone in hand reads `wifi · internet ✓ · vpn ✗` faster than
    /// a sentence — and the marks do not need translating.
    func describe() -> String {
        guard satisfied else { return "offline" }
        let internet = "✓"
        let vpnMark = isVpn ? "✓" : "✗"
        return "\(currentTransport) · internet \(internet) · vpn \(vpnMark)"
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let transport: String
            if path.usesInterfaceType(.wifi) {
                transport = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                transport = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                transport = "ethernet"
            } else {
                transport = "other"
            }
            let vpn = path.availableInterfaces.contains {
                $0.name.hasPrefix("utun") || $0.name.hasPrefix("ppp") || $0.name.hasPrefix("ipsec")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.generation += 1
                self.satisfied = satisfied
                self.currentTransport = transport
                self.isVpn = vpn
                self.onPathChange?()
            }
        }
        monitor.start(queue: queue)
    }
}

typealias NetworkMonitor = NetworkEnvironment
