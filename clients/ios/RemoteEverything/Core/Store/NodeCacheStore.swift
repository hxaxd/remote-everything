import Foundation

/// What each gateway last said about its nodes, cached locally on device.
final class NodeCacheStore {

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func cacheURL(origin: String) -> URL {
        directory.appendingPathComponent("nodes-\(Digest.originAlias(origin)).json")
    }

    func cachedNodes(origin: String) -> NodesResponse? {
        guard let data = AtomicFile.read(cacheURL(origin: origin)) else { return nil }
        return try? JSONDecoder().decode(NodesResponse.self, from: data)
    }

    func saveCachedNodes(_ response: NodesResponse, origin: String) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? AtomicFile.write(data, to: cacheURL(origin: origin))
    }

    func clearCachedNodes(origin: String) {
        AtomicFile.remove(cacheURL(origin: origin))
    }
}
