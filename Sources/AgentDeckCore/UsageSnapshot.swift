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
    /// When a source last reported a figure.
    public var observedAt: Date
    /// When a figure last moved. A status line re-sends cached figures on
    /// every run, so `observedAt` alone would keep claiming freshness.
    public var changedAt: Date

    public init(provider: Provider, groups: [UsageGroup], plan: String? = nil,
                observedAt: Date, changedAt: Date? = nil) {
        self.provider = provider
        self.groups = groups
        self.plan = plan
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

    func url(for provider: Provider) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json")
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

    public func load(_ provider: Provider) -> ProviderUsage? {
        guard let data = try? Data(contentsOf: url(for: provider)),
              let usage = try? Self.decoder.decode(ProviderUsage.self, from: data),
              usage.provider == provider
        else { return nil }
        return usage
    }

    /// Saves `usage`, keeping the stored `changedAt` when the figures are
    /// unchanged. Atomic, owner-only.
    public func record(_ usage: ProviderUsage) throws {
        var usage = usage
        if let previous = load(usage.provider), previous.sameFigures(as: usage) {
            usage.changedAt = previous.changedAt
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(usage)
        let temp = directory.appendingPathComponent(".\(usage.provider.rawValue).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, url(for: usage.provider).path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
