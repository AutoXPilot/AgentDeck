import Foundation

/// One JSON file per session under the sessions directory; writes are
/// atomic (temp file + rename) so concurrent hooks never expose partial JSON.
public struct SnapshotStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/sessions", isDirectory: true)
    }

    public init(directory: URL = SnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func url(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    public func write(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        let tmp = directory.appendingPathComponent(".\(snapshot.key).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [])
        _ = try FileManager.default.replaceItemAt(url(forKey: snapshot.key), withItemAt: tmp)
    }

    public func load(key: String) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url(forKey: key)) else { return nil }
        return try? Self.decoder().decode(SessionSnapshot.self, from: data)
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }

    /// Loads every parseable snapshot; unreadable/corrupt files are skipped.
    public func loadAll() -> [SessionSnapshot] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = Self.decoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionSnapshot.self, from: data)
            }
    }
}
