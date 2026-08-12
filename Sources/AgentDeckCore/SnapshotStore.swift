import Foundation

/// One JSON file per session under the sessions directory; writes are
/// atomic (temp file + rename) so concurrent hooks never expose partial JSON.
public struct SnapshotStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        // Env override so the render harness and golden tests can run
        // against fixtures instead of live production state.
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/sessions", isDirectory: true)
    }

    public init(directory: URL = SnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    // Fractional seconds matter: acks are sub-second Dates, and whole-second
    // snapshot timestamps let a same-second event hide behind an ack.
    // ISO8601DateFormatter is documented thread-safe; it just isn't Sendable
    public nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFractional.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: dec.codingPath, debugDescription: "unparseable date \(s)"
            ))
        }
        return d
    }

    /// Keys come partly from hook payloads; they must never traverse out of
    /// the sessions directory.
    public static func sanitizeKeyComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var s = String(String.UnicodeScalarView(
            raw.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }
        ))
        while s.contains("..") {
            s = s.replacingOccurrences(of: "..", with: "-.")
        }
        return s
    }

    public func url(forKey key: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitizeKeyComponent(key)).json")
    }

    public func write(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
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

    /// Removes debris that would otherwise live forever: temp files from
    /// helpers killed mid-write, and undecodable .json that loadAll skips
    /// (which the liveness sweep therefore can never remove).
    public func sweepOrphans(olderThan interval: TimeInterval = 3600, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let decoder = Self.decoder()
        for url in files {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? now
            guard now.timeIntervalSince(mtime) > interval else { continue }
            if url.lastPathComponent.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(at: url)
            } else if url.pathExtension == "json" {
                let decodable = (try? Data(contentsOf: url))
                    .flatMap { try? decoder.decode(SessionSnapshot.self, from: $0) } != nil
                if !decodable {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
