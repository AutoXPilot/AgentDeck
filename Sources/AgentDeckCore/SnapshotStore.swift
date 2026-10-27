import Foundation

/// One JSON file per session under the sessions directory; writes are
/// atomic (temp file + rename) so concurrent hooks never expose partial JSON.
public struct SnapshotStore: Sendable {
    public let directory: URL

    /// The real location, ignoring any environment override. The helper MUST
    /// use this: it inherits the agent's environment, so honoring
    /// AGENTDECK_STATE_DIR there would let any env leak silently redirect
    /// every snapshot write (deck empties, health dots stay green).
    public static var productionDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/sessions", isDirectory: true)
    }

    /// App/test/harness entry point: honors AGENTDECK_STATE_DIR so the render
    /// harness and golden tests can point at fixtures. The app sets its own
    /// environment, so the override is trusted here — never in the helper.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return productionDirectory
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
    /// the sessions directory. When sanitization actually CHANGES the string,
    /// a short stable hash of the original is appended so two distinct raw
    /// ids that sanitize to the same text (e.g. "a/b" and "a-b") can't share
    /// — and overwrite/remove — one file. Already-safe ids (real UUIDs) are
    /// returned unchanged, preserving existing files and readability.
    public static func sanitizeKeyComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var s = String(String.UnicodeScalarView(
            raw.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }
        ))
        while s.contains("..") {
            s = s.replacingOccurrences(of: "..", with: "-.")
        }
        if s != raw {
            s += "-" + String(fnv1a(raw), radix: 16)
        }
        return s
    }

    /// Stable (across processes) 32-bit FNV-1a — Swift's Hasher is seeded per
    /// run, so it can't key a filename.
    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return h
    }

    public func url(forKey key: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitizeKeyComponent(key)).json")
    }

    public func write(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [])
        do {
            _ = try FileManager.default.replaceItemAt(url(forKey: snapshot.key), withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)  // don't strand debris
            throw error
        }
    }

    public struct LockUnavailable: Error {}

    /// Serializes a session's load-merge-write/remove against concurrent hook
    /// processes for the SAME key, so a `Stop` can't read-then-write a
    /// snapshot back after a racing `SessionEnd` already removed it. flock is
    /// advisory but every writer is this same code path, so it holds.
    ///
    /// Throws rather than running unlocked when the lock can't be taken.
    /// For the helper that drops one event; running unlocked instead could
    /// resurrect a removed session or erase a fresh one, which is worse and
    /// silent.
    public func withKeyLock<T>(_ key: String, _ body: () throws -> T) throws -> T {
        let safe = Self.sanitizeKeyComponent(key)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".\(safe).lock")
        // The sweep may unlink an idle lock file. A process that opened it
        // just before then and was waiting on it would get the lock on a
        // file no longer at this path, while the next process creates a
        // new one and locks that: two holders. So after locking, confirm
        // the file locked is still the one at the path, and retry if not.
        for _ in 0..<8 {
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw LockUnavailable() }
            var locked = flock(fd, LOCK_EX)
            while locked != 0 && errno == EINTR { locked = flock(fd, LOCK_EX) }
            guard locked == 0 else { close(fd); throw LockUnavailable() }
            var held = stat(), atPath = stat()
            guard fstat(fd, &held) == 0, stat(lockURL.path, &atPath) == 0,
                  held.st_ino == atPath.st_ino, held.st_dev == atPath.st_dev else {
                flock(fd, LOCK_UN)
                close(fd)
                continue
            }
            // Mark the lock as in use. Neither open() nor flock() touches
            // mtime, so a long-lived session's lock aged past the sweep's
            // threshold and got unlinked while a helper still held it.
            futimens(fd, nil)
            defer { flock(fd, LOCK_UN); close(fd) }
            return try body()
        }
        throw LockUnavailable()
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
    /// Unlink a lock file only after proving nobody holds it. An idle-looking
    /// lock can still be held — mtime says when it was last *acquired*, not
    /// whether the holder is still inside the critical section.
    private func reclaimLockIfUnheld(_ url: URL) {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        reclaimLock(openedAs: fd, at: url)
    }

    /// Split from the open so a test can hold a descriptor opened earlier,
    /// as a second sweeper would have.
    func reclaimLock(openedAs fd: Int32, at url: URL) {
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }  // in use
        defer { flock(fd, LOCK_UN) }
        // Unlink only the file this sweep locked. Two app copies can open
        // the same old lock file; if the first reclaims it and a helper then
        // creates and locks a new one at the path, the second would unlink
        // that live lock — and the next helper would make a third.
        var held = stat(), atPath = stat()
        guard fstat(fd, &held) == 0, stat(url.path, &atPath) == 0,
              held.st_ino == atPath.st_ino, held.st_dev == atPath.st_dev else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether `data` has a snapshot's identity — string `provider`,
    /// `sessionId` and `updatedAt` — whether or not this build can decode
    /// the rest. A newer build can write a provider or a state this one has
    /// no case for; that file is the newer build's to manage, and deleting
    /// it would silently drop a live session from the newer app's list.
    static func looksLikeSnapshot(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return object["provider"] is String && object["sessionId"] is String
            && object["updatedAt"] is String
    }

    public func sweepOrphans(olderThan interval: TimeInterval = 3600, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let decoder = Self.decoder()
        for url in files {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? now
            guard now.timeIntervalSince(mtime) > interval else { continue }
            // stale .tmp (killed mid-write) and .lock files (one per session
            // key, otherwise never reclaimed) whose session is long idle
            if url.lastPathComponent.hasSuffix(".lock") {
                reclaimLockIfUnheld(url)
            } else if url.lastPathComponent.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(at: url)
            } else if url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url) else { continue }
                let decodable = (try? decoder.decode(SessionSnapshot.self, from: data)) != nil
                if !decodable && !Self.looksLikeSnapshot(data) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
