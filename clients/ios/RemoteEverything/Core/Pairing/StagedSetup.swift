import Foundation

/// The one file a pairing leaves behind until it is finished.
///
/// Pairing is two round trips — redeem the invitation, then be activated — and
/// being killed between them must not consume the invitation: the invitation is
/// single-use, so a client that lost its answer has to be able to pick the
/// attempt back up. Everything the resumed attempt needs is here at once, which
/// is why it is one file and not a handful of them: one rename is the whole
/// commit.
///
/// What is *not* here is the credential. The PKCS#12 bytes and the one-shot
/// password that opens them live in one Keychain item, and this file names it by
/// reference — the password may not be written to a file, and the credential is
/// no safer beside it.
struct StagedSetup: Codable, Equatable {
    var schema: Int = 1
    var origin: String
    var nodeID: String
    var nodeName: String
    var deviceName: String
    var certificateFingerprint: String
    /// The Keychain account the credential is stored under.
    var credentialRef: String
    var serverPin: ServerPin?
    var pendingExpiresAt: Date
    var createdAt: Date

    var isExpired: Bool {
        pendingExpiresAt <= Date()
    }
}

/// Where staged setups live: one file per origin, written in one rename.
final class StagedSetupStore {

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(origin: String) -> URL {
        directory.appendingPathComponent("\(Digest.originAlias(origin)).json")
    }

    /// Writes the staged setup, replacing whatever was staged for that origin.
    func stage(_ setup: StagedSetup) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(setup)
        try AtomicFile.write(data, to: fileURL(origin: setup.origin))
    }

    /// The staged setup for an origin, when there is a readable one. An
    /// unreadable file is no setup: what cannot be understood is not resumed.
    func load(origin: String) -> StagedSetup? {
        guard let setup = decode(AtomicFile.read(fileURL(origin: origin))) else { return nil }
        guard setup.origin == origin else { return nil }
        return setup
    }

    /// Every staged setup on disk.
    func loadAll() -> [StagedSetup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var setups: [StagedSetup] = []
        for file in files where file.pathExtension == "json" {
            let alias = file.deletingPathExtension().lastPathComponent
            if let setup = decode(AtomicFile.read(file)), Digest.originAlias(setup.origin) == alias {
                setups.append(setup)
            }
        }
        return setups
    }

    func clear(origin: String) {
        AtomicFile.remove(fileURL(origin: origin))
    }

    private func decode(_ data: Data?) -> StagedSetup? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let setup = try? decoder.decode(StagedSetup.self, from: data) else { return nil }
        guard setup.schema == 1 else { return nil }
        return setup
    }
}
