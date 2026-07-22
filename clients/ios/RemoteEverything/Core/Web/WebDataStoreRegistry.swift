import Foundation
import WebKit

/// Tracks every persistent WebKit profile created by Remote Everything.
/// Entries remain on disk until the corresponding data store is successfully
/// removed, so an interrupted or failed profile deletion can be retried.
@MainActor
final class WebDataStoreRegistry {
    static let shared = WebDataStoreRegistry()

    enum RegistryError: LocalizedError {
        case profileInUse
        case removalInProgress
        case removalFailed(count: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .profileInUse:
                return "远程页面仍在使用该连接，请返回目录后重试"
            case .removalInProgress:
                return "该连接正在删除"
            case .removalFailed(let count, let detail):
                return "有 \(count) 个网页资料域未能清除，可重试：\(detail)"
            }
        }
    }

    private struct Entry: Codable, Hashable {
        let installationId: String
        let appId: String

        var identifier: UUID {
            WebIsolationPolicy.profileUUID(installationId: installationId, appId: appId)
        }
    }

    typealias RemoveHandler = (UUID) async throws -> Void

    private let defaults: UserDefaults
    private let storageKey: String
    private let removeHandler: RemoveHandler
    private var entries: Set<Entry>
    private var activeCounts: [UUID: Int] = [:]
    private var removalsInProgress: Set<String> = []

    convenience init(
        defaults: UserDefaults = .standard,
        storageKey: String = "remote_everything_web_data_stores_v1"
    ) {
        self.init(
            defaults: defaults,
            storageKey: storageKey,
            removeHandler: Self.removeSystemDataStore
        )
    }

    init(
        defaults: UserDefaults,
        storageKey: String,
        removeHandler: @escaping RemoveHandler
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.removeHandler = removeHandler
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Set<Entry>.self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    /// Registers and leases a persistent data store before a WKWebView uses it.
    func acquire(installationId: String, appId: String) throws -> UUID {
        guard !removalsInProgress.contains(installationId) else {
            throw RegistryError.removalInProgress
        }
        let entry = Entry(installationId: installationId, appId: appId)
        if entries.insert(entry).inserted {
            persist()
        }
        activeCounts[entry.identifier, default: 0] += 1
        return entry.identifier
    }

    /// Releases the in-memory lease when SwiftUI dismantles the WKWebView.
    func release(identifier: UUID) {
        guard let current = activeCounts[identifier] else { return }
        if current <= 1 {
            activeCounts.removeValue(forKey: identifier)
        } else {
            activeCounts[identifier] = current - 1
        }
    }

    /// Removes every known data store for a profile and retains failed entries.
    /// On success the profile remains locked until `finishProfileRemoval` or
    /// `cancelProfileRemoval` is called around the metadata/keychain commit.
    func prepareProfileRemoval(installationId: String) async throws {
        guard !removalsInProgress.contains(installationId) else {
            throw RegistryError.removalInProgress
        }
        let matching = entries
            .filter { $0.installationId == installationId }
            .sorted { $0.appId < $1.appId }
        guard matching.allSatisfy({ activeCounts[$0.identifier, default: 0] == 0 }) else {
            throw RegistryError.profileInUse
        }

        removalsInProgress.insert(installationId)
        do {
            // Let a just-dismantled WKWebView leave the current main run-loop turn.
            await Task.yield()
            try Task.checkCancellation()
            guard matching.allSatisfy({ activeCounts[$0.identifier, default: 0] == 0 }) else {
                throw RegistryError.profileInUse
            }

            var failures: [String] = []
            for entry in matching {
                try Task.checkCancellation()
                do {
                    try await removeHandler(entry.identifier)
                    entries.remove(entry)
                    persist()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if !failures.isEmpty {
                throw RegistryError.removalFailed(
                    count: failures.count,
                    detail: failures.first ?? "未知错误"
                )
            }
        } catch {
            removalsInProgress.remove(installationId)
            throw error
        }
    }

    func finishProfileRemoval(installationId: String) {
        removalsInProgress.remove(installationId)
    }

    func cancelProfileRemoval(installationId: String) {
        removalsInProgress.remove(installationId)
    }

    // Internal inspection points used by deterministic unit tests.
    func registeredIdentifiers(installationId: String) -> Set<UUID> {
        Set(entries.filter { $0.installationId == installationId }.map(\.identifier))
    }

    func isRemovalInProgress(installationId: String) -> Bool {
        removalsInProgress.contains(installationId)
    }

    private func persist() {
        let ordered = entries.sorted {
            if $0.installationId == $1.installationId { return $0.appId < $1.appId }
            return $0.installationId < $1.installationId
        }
        if let data = try? JSONEncoder().encode(ordered) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func removeSystemDataStore(_ identifier: UUID) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
}
