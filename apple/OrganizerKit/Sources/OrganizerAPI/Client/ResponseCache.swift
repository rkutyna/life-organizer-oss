import CryptoKit
import Foundation

/// The last good response per read, on disk, so a screen shows data at once and says how old
/// it is ("a copy is a cache that shows its age").
///
/// One file per request in `directory`, named by a hash of the base URL and the endpoint's
/// `cacheKey`; each holds the raw response bytes and when they were fetched. The app keeps the
/// directory in its Caches folder (`AppPaths.cacheDirectory`). `OrganizerClient` writes it after
/// every successful GET; nothing else needs to. Mail bodies are never cached (see
/// `OrganizerClient.fetch`).
public final class ResponseCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Entry: Codable, Sendable {
        public let key: String
        public let fetchedAt: Date
        public let body: Data
    }

    public func read(key: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.key == key
        else { return nil }
        return entry
    }

    public func write(key: String, body: Data, fetchedAt: Date) {
        let entry = Entry(key: key, fetchedAt: fetchedAt, body: body)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // A cache that cannot be written only costs the next cold start; never fail a read.
        }
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Deletes every cached response (Settings, "Clear cached data").
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Total bytes on disk, for Settings.
    public func size() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }
}
