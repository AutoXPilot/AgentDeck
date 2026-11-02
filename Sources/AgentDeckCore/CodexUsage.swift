import Foundation

/// Codex's subscription limits, read from its rollout logs. Each
/// `event_msg` / `token_count` line carries `rate_limits` with a 5-hour
/// (`window_minutes` 300) and a weekly (10080) window. The same files hold
/// prompts and responses, so only lines with that exact envelope are
/// decoded and only the window figures are kept.
///
/// The record names no account: with several Codex accounts the figures
/// belong to whichever one wrote the newest record.
public enum CodexUsage {
    public static var defaultSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// The bucket for the subscription. A `premium` record with null
    /// windows can follow it in the same turn; older records have no id.
    static let subscriptionLimitID = "codex"
    static let sessionWindowMinutes = 300
    static let weeklyWindowMinutes = 10_080

    /// Parses one JSONL line; nil unless it is a token_count event with at
    /// least one subscription window.
    public static func parse(line: Data) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }
        if let id = limits["limit_id"], !(id is NSNull) {
            guard id as? String == subscriptionLimitID else { return nil }
        }
        var session: UsageWindow?
        var weekly: UsageWindow?
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = number(window["used_percent"])
            else { continue }
            let minutes = number(window["window_minutes"]).map { Int($0) }
            let resets = number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            let parsed = UsageWindow(usedPercent: used, resetsAt: resets, windowMinutes: minutes)
            // by duration, not position: nothing promises primary is 5-hour
            switch minutes {
            case sessionWindowMinutes: session = parsed
            case weeklyWindowMinutes: weekly = parsed
            default: if key == "primary" { session = session ?? parsed } else { weekly = weekly ?? parsed }
            }
        }
        guard session != nil || weekly != nil else { return nil }
        let observed = (record["timestamp"] as? String).flatMap {
            SnapshotStore.isoFractional.date(from: $0) ?? SnapshotStore.isoPlain.date(from: $0)
        } ?? Date()
        return ProviderUsage(
            provider: .codex,
            groups: [UsageGroup(session: session, weekly: weekly)],
            plan: limits["plan_type"] as? String,
            observedAt: observed
        )
    }

    private static func number(_ value: Any?) -> Double? {
        // `is Bool` also matches NSNumber 0 and 1; only a real JSON
        // true/false is a CFBoolean
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// The last valid record in `data`, which may start mid-line (a tail
    /// read) and end mid-line (Codex still appending). Both partial lines
    /// are dropped unless `data` is the whole file.
    public static func latest(in data: Data, isWholeFile: Bool) -> ProviderUsage? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        if data.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        for line in lines.reversed() where !line.isEmpty {
            // cheap prefilter before JSON decoding; parse() checks the envelope
            guard line.range(of: Data("token_count".utf8)) != nil else { continue }
            if let usage = parse(line: Data(line)) { return usage }
        }
        return nil
    }

    static let initialTail = 256 * 1024
    static let maxTail = 8 * 1024 * 1024

    /// Reads backwards from the end, doubling the window until a record is
    /// found or `maxTail` is reached. A single line can run to megabytes.
    public static func latest(inFile url: URL) -> ProviderUsage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var window = UInt64(initialTail)
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start))
            else { return nil }
            if let usage = latest(in: data, isWholeFile: start == 0) { return usage }
            if start == 0 || window >= UInt64(maxTail) { return nil }
            window *= 2
        }
    }

    struct FileKey: Hashable {
        let path: String
        let modified: Date
        let size: Int
    }

    /// Remembers per-file results so unchanged rollouts aren't re-read on
    /// every sweep. Not thread-safe; owned by one caller.
    public final class Reader: @unchecked Sendable {
        let directory: URL
        let maxFiles: Int
        private var cache: [FileKey: ProviderUsage?] = [:]
        private var last: ProviderUsage?

        public init(directory: URL = CodexUsage.defaultSessionsDirectory, maxFiles: Int = 20) {
            self.directory = directory
            self.maxFiles = maxFiles
        }

        /// The newest valid observation across the most recently modified
        /// rollouts. Active conversations can live in older date folders,
        /// so every folder is listed. A miss keeps the previous figure.
        public func load() -> ProviderUsage? {
            let files = CodexUsage.rollouts(in: directory).prefix(maxFiles)
            var fresh: [FileKey: ProviderUsage?] = [:]
            var best: ProviderUsage?
            for key in files {
                let found: ProviderUsage?
                if let cached = cache[key] {
                    found = cached
                } else {
                    found = CodexUsage.latest(inFile: URL(fileURLWithPath: key.path))
                }
                fresh[key] = found
                if let found, found.observedAt > (best?.observedAt ?? .distantPast) {
                    best = found
                }
                // a file's records are no newer than its mtime, and files
                // come newest-first, so the rest can't beat this one
                if let best, key.modified <= best.observedAt { break }
            }
            cache = fresh
            if let best { last = best }
            return last
        }
    }

    /// Rollout files, newest modification first.
    static func rollouts(in directory: URL) -> [FileKey] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [FileKey] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            found.append(FileKey(path: url.path, modified: modified, size: values.fileSize ?? 0))
        }
        return found.sorted { $0.modified > $1.modified }
    }
}
