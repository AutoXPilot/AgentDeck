import Foundation

/// One rate-limit window (the 5-hour or the weekly one) as a share used.
/// Providers report it differently (Codex `used_percent`, Claude
/// `used_percentage`, agy `remaining_fraction`); this is the common form.
public struct UsageWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(usedPercent: Double, resetsAt: Date? = nil, windowMinutes: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    /// The window rolled over after this figure was taken, so the percent
    /// says nothing about now; the row shows "reset" until a new figure
    /// arrives rather than implying the capacity is known.
    public func resetPassed(now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// A quota group: Claude and Codex have one, agy has one per model family
/// ("Gemini", "Claude/GPT", plus model-specific ones).
public struct UsageGroup: Codable, Equatable, Sendable {
    public var label: String?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    /// false = shown in the tooltip only, to keep the line short.
    public var inLine: Bool

    public init(label: String? = nil, session: UsageWindow? = nil,
                weekly: UsageWindow? = nil, inLine: Bool = true) {
        self.label = label
        self.session = session
        self.weekly = weekly
        self.inLine = inLine
    }

    public var isEmpty: Bool { session == nil && weekly == nil }
}

/// The latest usage AgentDeck has seen for one provider. Only these
/// allow-listed fields are ever written to disk.
public struct ProviderUsage: Codable, Equatable, Sendable {
    public var provider: Provider
    public var groups: [UsageGroup]
    public var plan: String?
    /// Which account the figures belong to, when the source can tell
    /// (Claude: the first 8 characters of the signed-in account's id).
    public var account: String?
    /// When a source last reported a figure.
    public var observedAt: Date
    /// When a figure last moved. A status line re-sends cached figures on
    /// every run, so `observedAt` alone would keep claiming freshness.
    public var changedAt: Date
    /// Earlier 5-hour reset times of this account, newest last. A reset
    /// time is specific to the account, so a figure carrying one of these
    /// under another account is this account's figure echoed back.
    public var recentResets: [Date]?

    public init(provider: Provider, groups: [UsageGroup], plan: String? = nil,
                account: String? = nil, observedAt: Date, changedAt: Date? = nil) {
        self.provider = provider
        self.groups = groups
        self.plan = plan
        self.account = account
        self.observedAt = observedAt
        self.changedAt = changedAt ?? observedAt
    }

    public static let staleAfter: TimeInterval = 6 * 3600

    /// The figures haven't moved in 6 hours. `changedAt`, not
    /// `observedAt`: an idle session keeps re-sending cached figures, which
    /// would otherwise look fresh forever.
    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(changedAt) > Self.staleAfter
    }

    /// Past this, figures that never moved say nothing about now: the
    /// longest window (weekly) has turned over at least once since.
    public static let expireAfter: TimeInterval = 8 * 86400

    /// The figures can no longer describe the current windows: every
    /// window on the line has reset since they were taken, or they haven't
    /// moved for over a week. A source that stopped reporting (a tee
    /// removed or blocked, an account with no limits) would otherwise
    /// leave its last line up for good.
    public func isExpired(now: Date) -> Bool {
        if now.timeIntervalSince(changedAt) > Self.expireAfter { return true }
        let windows = groups.filter { $0.inLine }.flatMap { [$0.session, $0.weekly] }.compactMap { $0 }
        return !windows.isEmpty && windows.allSatisfy { $0.resetPassed(now: now) }
    }

    /// Reset times that identify this account's windows.
    var accountResets: Set<Date> {
        var all = Set(recentResets ?? [])
        for group in groups {
            if let r = group.session?.resetsAt { all.insert(r) }
        }
        return all
    }

    /// Same figures, ignoring when they were seen.
    public func sameFigures(as other: ProviderUsage) -> Bool {
        provider == other.provider && groups == other.groups && plan == other.plan
    }
}

/// Reads and writes `<directory>/<provider>.json` for the status line tees.
public struct UsageStore: Sendable {
    public let directory: URL

    /// Real location; the helper must use this (see SnapshotStore).
    public static var productionDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/usage", isDirectory: true)
    }

    public init(directory: URL = UsageStore.productionDirectory) {
        self.directory = directory
    }

    /// `<provider>.json`, or `<provider>-<account>.json` when the account
    /// is known, so two accounts never overwrite each other.
    func url(for provider: Provider, account: String? = nil) -> URL {
        guard let account = Self.safeAccount(account) else {
            return directory.appendingPathComponent("\(provider.rawValue).json")
        }
        return directory.appendingPathComponent("\(provider.rawValue)-\(account).json")
    }

    static func safeAccount(_ account: String?) -> String? {
        guard let account, !account.isEmpty, account.count <= 64,
              account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return account
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func load(_ provider: Provider, account: String? = nil) -> ProviderUsage? {
        decode(url(for: provider, account: account), provider: provider)
    }

    private func decode(_ url: URL, provider: Provider) -> ProviderUsage? {
        guard let data = try? Data(contentsOf: url),
              let usage = try? Self.decoder.decode(ProviderUsage.self, from: data),
              usage.provider == provider
        else { return nil }
        return usage
    }

    /// Every stored record for `provider`, one per account.
    public func loadAll(_ provider: Provider) -> [ProviderUsage] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.filter {
            $0 == "\(provider.rawValue).json"
                || ($0.hasPrefix("\(provider.rawValue)-") && $0.hasSuffix(".json"))
        }.compactMap { decode(directory.appendingPathComponent($0), provider: provider) }
    }

    /// The record to show and the other accounts' records, for the tooltip.
    /// With a known signed-in account only its record is shown; an
    /// account-less record (written before accounts were tracked) is then
    /// dropped as unattributable. Without one (an API key, or a
    /// `.claude.json` AgentDeck can't read), only an account-less record
    /// is shown: one filed under an account might be another person's
    /// login on this Mac, such as a personal one on a work laptop.
    public static func pick(_ records: [ProviderUsage], signedIn: String?)
        -> (shown: ProviderUsage?, others: [ProviderUsage]) {
        guard let signedIn else { return (records.first { $0.account == nil }, []) }
        let shown = records.first { $0.account == signedIn }
        let others = records.filter { $0.account != nil && $0.account != signedIn }
            .sorted { $0.observedAt > $1.observedAt }
        return (shown, others)
    }

    /// Deletes every saved record for `provider`, for when its source is
    /// turned off. They are AgentDeck's own copies of the figures and come
    /// back on the next report.
    public func removeAll(_ provider: Provider) throws {
        try withLock(provider) { removeAllLocked(provider) }
    }

    func removeAllLocked(_ provider: Provider) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names where name == "\(provider.rawValue).json"
            || (name.hasPrefix("\(provider.rawValue)-") && name.hasSuffix(".json")) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Runs `body` holding `provider`'s lock, the one every write of its
    /// figures takes. The tee's heartbeat uses it too, so uninstall can
    /// delete figures and heartbeat with no tee writing in between.
    public func locked<T>(_ provider: Provider, _ body: () throws -> T) throws -> T {
        try withLock(provider, body)
    }

    /// Saves `usage` unless it is another account's figures echoed back.
    /// After `/login` every open session moves to the new account, but an
    /// idle one keeps re-sending the old account's cached figures until its
    /// next response. Those carry the old account's 5-hour reset time (the
    /// current one or a recent one), which no other account shares, so
    /// they're dropped rather than filed under the new account. Serialized
    /// per provider: tees run concurrently, one per open session. Returns
    /// whether anything was written. `allowed` = the tee is still
    /// installed.
    @discardableResult
    public func recordUnlessEcho(_ usage: ProviderUsage, onlyIf allowed: () -> Bool = { true }) throws -> Bool {
        try withLock(usage.provider) {
            // checked under the lock: uninstall retires the tee, then
            // deletes the figures under this same lock
            guard allowed() else { return false }
            if usage.account != nil, isEcho(usage, among: loadAll(usage.provider)) { return false }
            let written = try recordLocked(usage)
            if usage.account != nil {
                // the account-less file predates account tracking; it can't
                // be attributed, so it goes once an attributed one exists
                try? FileManager.default.removeItem(at: url(for: usage.provider))
            }
            return written
        }
    }

    func isEcho(_ usage: ProviderUsage, among records: [ProviderUsage]) -> Bool {
        let incoming = usage.groups.compactMap { $0.session?.resetsAt }
        guard !incoming.isEmpty else { return false }
        return records.contains { other in
            other.account != nil && other.account != usage.account
                && !other.accountResets.isDisjoint(with: incoming)
        }
    }

    /// Saves `usage`, merged with what's stored (see `merge`). Atomic,
    /// owner-only.
    @discardableResult
    public func record(_ usage: ProviderUsage) throws -> Bool {
        try withLock(usage.provider) { try recordLocked(usage) }
    }

    /// Every open session's tee reports its own cached figures, so an idle
    /// one can report an older figure after a busy one reported a newer
    /// one. Within one window (same reset time) usage only grows, and an
    /// older window never replaces a newer one. nil = nothing worth writing
    /// (same figures seen under a minute ago).
    static func merge(previous: ProviderUsage?, incoming: ProviderUsage) -> ProviderUsage? {
        guard let previous else { return incoming }
        func window(_ old: UsageWindow?, _ new: UsageWindow?) -> UsageWindow? {
            guard let old else { return new }
            guard let new else { return old }
            if let o = old.resetsAt, let n = new.resetsAt {
                if n < o { return old }
                if n == o, old.usedPercent > new.usedPercent { return old }
            }
            return new
        }
        var merged = incoming
        merged.groups = incoming.groups.map { group in
            guard let before = previous.groups.first(where: { $0.label == group.label }) else { return group }
            var g = group
            g.session = window(before.session, group.session)
            g.weekly = window(before.weekly, group.weekly)
            return g
        }
        for old in previous.groups where !merged.groups.contains(where: { $0.label == old.label }) {
            merged.groups.append(old)
        }
        merged.observedAt = max(previous.observedAt, incoming.observedAt)
        // earlier windows only: the current one is in the groups already
        var resets = previous.recentResets ?? []
        let current = Set(merged.groups.compactMap { $0.session?.resetsAt })
        for r in previous.groups.compactMap({ $0.session?.resetsAt })
        where !resets.contains(r) && !current.contains(r) {
            resets.append(r)
        }
        merged.recentResets = resets.isEmpty ? nil : Array(resets.suffix(8))
        if merged.sameFigures(as: previous) {
            merged.changedAt = previous.changedAt
            if incoming.observedAt.timeIntervalSince(previous.observedAt) < 60,
               merged.recentResets == previous.recentResets {
                return nil
            }
        } else {
            merged.changedAt = incoming.observedAt
        }
        return merged
    }

    private func recordLocked(_ incoming: ProviderUsage) throws -> Bool {
        guard let usage = Self.merge(previous: load(incoming.provider, account: incoming.account),
                                     incoming: incoming)
        else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(usage)
        let destination = url(for: usage.provider, account: usage.account)
        let temp = directory.appendingPathComponent(".\(usage.provider.rawValue).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, destination.path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }

    /// flock on a per-provider sidecar; fails closed like the installer's.
    private func withLock<T>(_ provider: Provider, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent(".\(provider.rawValue).lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileWriteUnknown) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
