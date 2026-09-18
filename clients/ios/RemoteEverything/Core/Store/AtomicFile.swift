import Foundation

/// A file that is replaced, never edited: the new contents are written beside it
/// and renamed over it, so a reader sees either the whole old file or the whole
/// new one. Everything that must survive being killed halfway is written this way.
enum AtomicFile {

    static func write(_ contents: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(url.lastPathComponent + ".new")
        try contents.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            // Replacing is not atomic on every filesystem, but the old file stays
            // whole until the move lands, which is what the readers depend on.
            _ = try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
