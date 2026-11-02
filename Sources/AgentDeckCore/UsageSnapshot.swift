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

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(observedAt) > Self.staleAfter
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
    /// dropped as unattributable. Without one, the newest record is shown.
    public static func pick(_ records: [ProviderUsage], signedIn: String?)
        -> (shown: ProviderUsage?, others: [ProviderUsage]) {
        if let signedIn {
            let shown = records.first { $0.account == signedIn }
            let others = records.filter { $0.account != nil && $0.account != signedIn }
                .sorted { $0.observedAt > $1.observedAt }
            return (shown, others)
        }
        let sorted = records.sorted { $0.observedAt > $1.observedAt }
        return (sorted.first, Array(sorted.dropFirst()))
    }

    /// Saves `usage` unless it is another account's figures echoed back.
    /// After `/login` every open session moves to the new account, but an
    /// idle one keeps re-sending the old account's cached figures until its
    /// next response; those match the old account's record exactly
    /// (percent and reset time), so they're dropped rather than filed under
    /// the new account. Returns whether it was saved.
    @discardableResult
    public func recordUnlessEcho(_ usage: ProviderUsage) throws -> Bool {
        if usage.account != nil {
            let echo = loadAll(usage.provider).contains {
                $0.account != nil && $0.account != usage.account && $0.sameFigures(as: usage)
            }
            if echo { return false }
        }
        try record(usage)
        if usage.account != nil {
            // the account-less file predates account tracking; it can't be
            // attributed, so it goes once an attributed one exists
            try? FileManager.default.removeItem(at: url(for: usage.provider))
        }
        return true
    }

    /// Saves `usage`, keeping the stored `changedAt` when the figures are
    /// unchanged. Atomic, owner-only.
    public func record(_ usage: ProviderUsage) throws {
        var usage = usage
        if let previous = load(usage.provider, account: usage.account), previous.sameFigures(as: usage) {
            usage.changedAt = previous.changedAt
        }
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
    }
}
