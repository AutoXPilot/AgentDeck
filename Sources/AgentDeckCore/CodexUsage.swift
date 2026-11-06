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
        CodexHome.current.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The bucket for the subscription. A `premium` record with null
    /// windows can follow it in the same turn; older records have no id.
    static let subscriptionLimitID = "codex"
    /// Buckets seen beside the subscription that say nothing about it.
    static let companionLimitIDs: Set<String> = ["premium"]
    static let sessionWindowMinutes = 300
    static let weeklyWindowMinutes = 10_080

    /// What one rollout line says about the subscription.
    enum Reading {
        case usage(ProviderUsage)
        /// A token_count event that carries no subscription figures this
        /// reader understands: `rate_limits` null or without windows, or a
        /// bucket other than `codex`/`premium` (another plan kind, such as
        /// an organization's).
        /// Newer than any figure, it means the account in use isn't
        /// reporting, so older figures (possibly another account's) aren't
        /// shown in its place.
        case notReporting(observedAt: Date)

        var observedAt: Date {
            switch self {
            case .usage(let usage): return usage.observedAt
            case .notReporting(let at): return at
            }
        }

        var usage: ProviderUsage? {
            if case .usage(let usage) = self { return usage }
            return nil
        }
    }

    /// Parses one JSONL line; nil unless it is a token_count event with at
    /// least one subscription window.
    public static func parse(line: Data) -> ProviderUsage? {
        read(line: line)?.usage
    }

    /// nil = not a token_count event, or one that says nothing either way
    /// (a `premium` record, a Codex too old to report limits).
    static func read(line: Data) -> Reading? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let record = object as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "token_count"
        else { return nil }
        let observed = (record["timestamp"] as? String).flatMap {
            SnapshotStore.isoFractional.date(from: $0) ?? SnapshotStore.isoPlain.date(from: $0)
        } ?? Date()
        // absent: a Codex from before rate limits were reported
        guard let rawLimits = payload["rate_limits"] else { return nil }
        guard let limits = rawLimits as? [String: Any] else { return .notReporting(observedAt: observed) }
        if let id = limits["limit_id"], !(id is NSNull) {
            guard let id = id as? String else { return .notReporting(observedAt: observed) }
            if companionLimitIDs.contains(id) { return nil }
            if id != subscriptionLimitID { return .notReporting(observedAt: observed) }
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
        // the subscription bucket (or an unnamed one) with no windows
        guard session != nil || weekly != nil else { return .notReporting(observedAt: observed) }
        return .usage(ProviderUsage(
            provider: .codex,
            groups: [UsageGroup(session: session, weekly: weekly)],
            plan: limits["plan_type"] as? String,
            observedAt: observed
        ))
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
        latestReading(in: data, isWholeFile: isWholeFile)?.usage
    }

    static func latestReading(in data: Data, isWholeFile: Bool) -> Reading? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        if data.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        for line in lines.reversed() where !line.isEmpty {
            // cheap prefilter before JSON decoding; parse() checks the envelope
            guard line.range(of: Data("token_count".utf8)) != nil else { continue }
            if let reading = read(line: Data(line)) { return reading }
        }
        return nil
    }

    static let initialTail = 256 * 1024
    static let maxTail = 8 * 1024 * 1024

    /// Reads backwards from the end, doubling the window until a record is
    /// found or `maxTail` is reached. A single line can run to megabytes.
    public static func latest(inFile url: URL) -> ProviderUsage? {
        latestReading(inFile: url)?.usage
    }

    static func latestReading(inFile url: URL) -> Reading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var window = UInt64(initialTail)
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start))
            else { return nil }
            if let reading = latestReading(in: data, isWholeFile: start == 0) { return reading }
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
        private var cache: [FileKey: Reading?] = [:]
        private var last: ProviderUsage?

        public init(directory: URL = CodexUsage.defaultSessionsDirectory, maxFiles: Int = 20) {
            self.directory = directory
            self.maxFiles = maxFiles
        }

        /// The newest observation across the most recently modified
        /// rollouts. Active conversations can live in older date folders,
        /// so every folder is listed. A miss (none of the newest files has a
        /// record, e.g. a run of short `codex exec` threads) keeps the last
        /// figure, which expires with its windows. A newest record saying
        /// the account isn't reporting drops it: an older figure could
        /// belong to another account.
        public func load() -> ProviderUsage? {
            let files = CodexUsage.rollouts(in: directory).prefix(maxFiles)
            var fresh: [FileKey: Reading?] = [:]
            var best: Reading?
            for key in files {
                let found: Reading?
                if let cached = cache[key] {
                    found = cached
                } else {
                    found = CodexUsage.latestReading(inFile: URL(fileURLWithPath: key.path))
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
            switch best {
            case .usage(let usage)?: last = usage
            case .notReporting?: last = nil
            case nil: break
            }
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
