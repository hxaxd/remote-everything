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
    private var started = false

    /// Called on the main queue whenever the network changed.
    var onPathChange: (() -> Void)?

    /// The cache key. Read and written on the main thread only.
    var key: String {
        "network-\(generation)-\(satisfied ? "up" : "down")"
    }

    var isSatisfied: Bool { satisfied }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                self.generation += 1
                self.satisfied = satisfied
                self.onPathChange?()
            }
        }
        monitor.start(queue: queue)
    }
}

typealias NetworkMonitor = NetworkEnvironment
