import Darwin
import Foundation

/// One agent session as a workspace remembers it: enough to bring the
/// conversation back, and nothing else.
///
/// The command line the session was started with is deliberately absent. It
/// can carry a prompt, a credential or an environment assignment, and
/// replaying it would not resume anything anyway — most live panes were
/// started as a bare `claude`, which opens a fresh conversation. Restore
/// constructs its command from `sessionId` alone.
public struct WorkspaceEntry: Codable, Equatable, Sendable {
    public var provider: Provider
    public var sessionId: String
    public var cwd: String
    /// Only a name someone chose: Claude's user-set session name or a Codex
    /// `/rename`. Generated names and terminal titles can be derived from
    /// the conversation, and this file is meant to be metadata only.
    public var displayName: String?
    /// The permission mode the session ran under, so an unsupervised
    /// session doesn't come back prompting on every tool call. Validated
    /// against an allow-list when a command is built, never passed raw.
    public var permissionMode: String?
    /// Last time the session was seen running.
    public var lastSeen: Date

    public init(
        provider: Provider, sessionId: String, cwd: String,
        displayName: String? = nil, permissionMode: String? = nil, lastSeen: Date
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.cwd = cwd
        self.displayName = displayName
        self.permissionMode = permissionMode
        self.lastSeen = lastSeen
    }

    public var key: String { "\(provider.rawValue)-\(sessionId)" }

    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? cwd : folder
    }

    /// Same session, same launch facts — ignoring when it was last seen.
    func sameFacts(as other: WorkspaceEntry) -> Bool {
        var a = self, b = other
        a.lastSeen = .distantPast
        b.lastSeen = .distantPast
        return a == b
    }
}

/// Everything that ran during one boot, accumulated.
///
/// It is never a mirror of the live set. Shutting down closes panes one at
/// a time and each close removes its session, so a mirror shrinks to empty
/// at exactly the moment it is needed, and the next login overwrites it
/// with nothing. A generation only ever gains entries; an entry that stops
/// running keeps its `lastSeen`, which is what restore reads.
public struct WorkspaceGeneration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var bootID: String
    public var updatedAt: Date
    public var entries: [WorkspaceEntry]

    public init(bootID: String, updatedAt: Date, entries: [WorkspaceEntry] = []) {
        self.bootID = bootID
        self.updatedAt = updatedAt
        self.entries = entries
    }

    /// Sessions that were running together when this generation last saw
    /// activity, minus any running now.
    ///
    /// "Together" means seen within `window` of the latest sighting. A
    /// session closed on purpose hours before a reboot falls outside it and
    /// isn't offered back; sessions closed one after another while shutting
    /// down fall inside it.
    public func recentlyClosed(
        live: Set<String>, window: TimeInterval = 15 * 60
    ) -> [WorkspaceEntry] {
        guard let latest = entries.map(\.lastSeen).max() else { return [] }
        let cutoff = latest.addingTimeInterval(-window)
        return entries.filter { $0.lastSeen >= cutoff && !live.contains($0.key) }
    }
}

/// A set of sessions saved under a name, restorable on demand. Never
/// pruned or updated behind the user's back.
public struct NamedWorkspace: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion = 1
    /// Stable, not derived from the name, so renaming or reusing a name is
    /// never a file operation.
    public var id: String
    public var name: String
    public var savedAt: Date
    public var entries: [WorkspaceEntry]

    public init(id: String = UUID().uuidString, name: String, savedAt: Date,
                entries: [WorkspaceEntry]) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.entries = entries
    }
}

/// Files under `Application Support/AgentDeck/workspaces/`, kept apart from
/// `sessions/` because nothing in there survives a reboot by design: dead
/// pids are swept, and every pane closing deletes its snapshot.
///
/// Not thread-safe; the app owns one instance on the main actor.
public final class WorkspaceStore {
    public let directory: URL
    /// Prior boots kept besides the current one.
    public let keepGenerations: Int
    /// A still-running session's `lastSeen` is rewritten at most this often.
    public let refreshInterval: TimeInterval

    private var current: WorkspaceGeneration?

    public init(
        directory: URL = WorkspaceStore.defaultDirectory,
        keepGenerations: Int = 5, refreshInterval: TimeInterval = 60
    ) {
        self.directory = directory
        self.keepGenerations = keepGenerations
        self.refreshInterval = refreshInterval
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_WORKSPACE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/workspaces", isDirectory: true)
    }

    var generationsDirectory: URL { directory.appendingPathComponent("boots", isDirectory: true) }
    var namedDirectory: URL { directory.appendingPathComponent("named", isDirectory: true) }

    /// Changes on every boot and only then. `kern.bootsessionuuid` rather
    /// than the boot time, which is wall-clock-derived and drifts.
    public static func currentBootID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        let id = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self)
        return id.isEmpty ? nil : id
    }

    // MARK: Generations

    /// Folds the sessions running right now into this boot's generation.
    /// Returns whether anything was written.
    ///
    /// Absence from `live` never removes an entry. A generation file is not
    /// created until it has something in it, so a login that sees no
    /// sessions can't push the previous boot's set out of the ring.
    @discardableResult
    public func record(live: [WorkspaceEntry], bootID: String, now: Date = Date()) throws -> Bool {
        var generation = current?.bootID == bootID
            ? current!
            : loadGeneration(bootID: bootID) ?? WorkspaceGeneration(bootID: bootID, updatedAt: now)
        var changed = false
        for var entry in live {
            entry.lastSeen = now
            if let i = generation.entries.firstIndex(where: { $0.key == entry.key }) {
                let old = generation.entries[i]
                if !old.sameFacts(as: entry)
                    || now.timeIntervalSince(old.lastSeen) >= refreshInterval {
                    generation.entries[i] = entry
                    changed = true
                }
            } else {
                generation.entries.append(entry)
                changed = true
            }
        }
        guard changed, !generation.entries.isEmpty else {
            current = generation
            return false
        }
        generation.updatedAt = now
        // adopted only once it is on disk, so a failed write is retried
        try write(generation, to: generationURL(bootID))
        current = generation
        pruneGenerations(keeping: bootID)
        return true
    }

    /// Newest first, by when each last changed. Unreadable files are
    /// skipped, never deleted: a newer build may have written them.
    public func generations() -> [WorkspaceGeneration] {
        files(in: generationsDirectory)
            .compactMap { read(WorkspaceGeneration.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadGeneration(bootID: String) -> WorkspaceGeneration? {
        read(WorkspaceGeneration.self, from: generationURL(bootID))
    }

    func generationURL(_ bootID: String) -> URL {
        generationsDirectory.appendingPathComponent("\(Self.safeFilename(bootID)).json")
    }

    private func pruneGenerations(keeping bootID: String) {
        let others = generations().filter { $0.bootID != bootID }
        for old in others.dropFirst(keepGenerations) {
            try? FileManager.default.removeItem(at: generationURL(old.bootID))
        }
    }

    // MARK: Named workspaces

    public func named() -> [NamedWorkspace] {
        files(in: namedDirectory)
            .compactMap { read(NamedWorkspace.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ workspace: NamedWorkspace) throws {
        try write(workspace, to: namedURL(workspace.id))
    }

    public func deleteNamed(id: String) throws {
        try FileManager.default.removeItem(at: namedURL(id))
    }

    func namedURL(_ id: String) -> URL {
        namedDirectory.appendingPathComponent("\(Self.safeFilename(id)).json")
    }

    // MARK: Files

    static func safeFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }

    private func files(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SnapshotStore.decoder().decode(type, from: data)
    }

    /// Owner-only: the file names directories and session ids, and restore
    /// acts on what it says.
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try SnapshotStore.encoder().encode(value)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}
