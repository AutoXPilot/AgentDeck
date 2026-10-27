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

    public var key: String { SessionKey.make(provider, sessionId) }

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

/// Sessions observed to stop running together — an iTerm quit, a
/// shutdown — kept as a group. Recorded when it happens rather than
/// reconstructed later, so a later, unrelated closure can't redefine it.
public struct ClosedSet: Codable, Equatable, Sendable {
    public var id: String
    /// The latest closure in the set.
    public var closedAt: Date
    public var keys: [String]

    public init(id: String = UUID().uuidString, closedAt: Date, keys: [String]) {
        self.id = id
        self.closedAt = closedAt
        self.keys = keys
    }
}

/// Sessions to offer back as one restore: when they stopped, and which.
public struct RestoreSet: Equatable, Sendable {
    public var closedAt: Date
    public var entries: [WorkspaceEntry]
}

/// Everything that ran during one boot, accumulated.
///
/// It is never a mirror of the live set. Shutting down closes panes one at
/// a time and each close removes its session, so a mirror shrinks to empty
/// at exactly the moment it is needed, and the next login overwrites it
/// with nothing. A generation only ever gains entries; an entry that stops
/// running keeps its `lastSeen`.
public struct WorkspaceGeneration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var bootID: String
    public var updatedAt: Date
    public var entries: [WorkspaceEntry]
    /// Entries this build can't decode (a newer build's provider), written
    /// back unchanged. Never offered for restore.
    public var unknownEntries: [OpaqueWorkspaceEntry] = []
    /// Oldest first, bounded.
    public var closedSets: [ClosedSet] = []

    public static let maxClosedSets = 20

    public init(bootID: String, updatedAt: Date, entries: [WorkspaceEntry] = [],
                closedSets: [ClosedSet] = []) {
        self.bootID = bootID
        self.updatedAt = updatedAt
        self.entries = entries
        self.closedSets = closedSets
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bootID, updatedAt, entries, closedSets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bootID = try c.decode(String.self, forKey: .bootID)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        (entries, unknownEntries) = WorkspaceEntrySlot.split(
            try c.decode([WorkspaceEntrySlot].self, forKey: .entries))
        // files written before closed sets existed
        closedSets = try c.decodeIfPresent([ClosedSet].self, forKey: .closedSets) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(bootID, forKey: .bootID)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(WorkspaceEntriesForEncoding(known: entries, opaque: unknownEntries),
                     forKey: .entries)
        try c.encode(closedSets, forKey: .closedSets)
    }

    /// Notes sessions that just stopped running. Closures within `gap` of
    /// the newest set's last closure join it; otherwise they start a new
    /// set. A quit closes sessions seconds apart, so it lands in one set
    /// however long it takes, and a session closed later — a quick test
    /// in the new iTerm — gets its own set instead of displacing it.
    mutating func noteClosed(_ keys: [String], at now: Date, gap: TimeInterval = 5 * 60) {
        guard !keys.isEmpty else { return }
        if var last = closedSets.last, now.timeIntervalSince(last.closedAt) <= gap {
            last.keys += keys.filter { !last.keys.contains($0) }
            last.closedAt = now
            closedSets[closedSets.count - 1] = last
        } else {
            closedSets.append(ClosedSet(closedAt: now, keys: keys))
        }
        if closedSets.count > Self.maxClosedSets {
            closedSets.removeFirst(closedSets.count - Self.maxClosedSets)
        }
    }

    /// Entries that were running at the last write and aren't in `live`,
    /// excluding any already recorded as closed since their last sighting.
    func closedWhileUnobserved(live: Set<String>, freshness: TimeInterval) -> [String] {
        let cutoff = updatedAt.addingTimeInterval(-freshness)
        return entries.filter { entry in
            entry.lastSeen >= cutoff && !live.contains(entry.key)
                && !closedSets.contains { $0.keys.contains(entry.key) && $0.closedAt >= entry.lastSeen }
        }.map(\.key).sorted()
    }

    /// What was still running when this generation's record ends: the
    /// newest sighting and every one chained to it within `gap`, measured
    /// over all entries. Only meaningful for a finished boot, where no
    /// sighting can advance any more. It covers a shutdown AgentDeck didn't
    /// see happen — quit first at logout, say — where no closed set was
    /// recorded.
    func finalSet(gap: TimeInterval = 5 * 60) -> [WorkspaceEntry] {
        let sorted = entries.sorted { $0.lastSeen > $1.lastSeen }
        guard var previous = sorted.first?.lastSeen else { return [] }
        var members = Set<String>()
        for entry in sorted {
            guard previous.timeIntervalSince(entry.lastSeen) <= gap else { break }
            members.insert(entry.key)
            previous = entry.lastSeen
        }
        return entries.filter { members.contains($0.key) }
    }

    /// The sets worth offering, newest first. Membership is fixed first and
    /// running sessions subtracted after, so restoring part of a set leaves
    /// the rest of it offered rather than reshaping what counts as a set.
    /// A set wholly inside a larger one is dropped as redundant.
    ///
    /// `finished`: a previous boot, whose final set is included too.
    public func restoreSets(
        live: Set<String>, finished: Bool, limit: Int = 3
    ) -> [RestoreSet] {
        var candidates: [(closedAt: Date, keys: Set<String>)] = closedSets.map {
            ($0.closedAt, Set($0.keys))
        }
        if finished {
            let final = finalSet()
            if let at = final.map(\.lastSeen).max() {
                candidates.append((at, Set(final.map(\.key))))
            }
        }
        // A set is redundant only if a superset is at least as recent: an
        // older superset must not swallow a newer closure, or the newest
        // thing you closed could vanish behind something from hours ago.
        let distinct = candidates.enumerated().filter { i, c in
            !candidates.enumerated().contains { j, other in
                j != i && c.keys.isSubset(of: other.keys)
                    && other.closedAt >= c.closedAt
                    && (c.keys != other.keys || j > i)
            }
        }.map(\.element)
        let all = distinct
            .sorted { $0.closedAt > $1.closedAt }
            .compactMap { c -> RestoreSet? in
                let remaining = entries.filter { c.keys.contains($0.key) && !live.contains($0.key) }
                return remaining.isEmpty ? nil : RestoreSet(closedAt: c.closedAt, entries: remaining)
            }
        guard all.count > limit, limit > 0 else { return all }
        // Newest first, but the largest always makes the cut: three small
        // closures after an iTerm quit must not push the thirty out of
        // reach.
        var shown = Array(all.prefix(limit))
        if let largest = all.max(by: { $0.entries.count < $1.entries.count }),
           !shown.contains(largest) {
            shown[shown.count - 1] = largest
        }
        return shown
    }

    /// Merges two views of the same boot; the newer sighting of each
    /// session wins, and nothing is dropped.
    func merged(with other: WorkspaceGeneration) -> WorkspaceGeneration {
        var result = self
        for entry in other.entries {
            if let i = result.entries.firstIndex(where: { $0.key == entry.key }) {
                if entry.lastSeen > result.entries[i].lastSeen { result.entries[i] = entry }
            } else {
                result.entries.append(entry)
            }
        }
        result.unknownEntries = Self.mergedOpaque(unknownEntries, other.unknownEntries)
        for set in other.closedSets {
            if let i = result.closedSets.firstIndex(where: { $0.id == set.id }) {
                // Union, not last-writer-wins: two instances can each have
                // added a different member to the same set, and a clock
                // step backwards would otherwise let the older copy win.
                var mergedSet = result.closedSets[i]
                mergedSet.keys += set.keys.filter { !mergedSet.keys.contains($0) }
                mergedSet.closedAt = max(mergedSet.closedAt, set.closedAt)
                result.closedSets[i] = mergedSet
            } else {
                result.closedSets.append(set)
            }
        }
        result.closedSets.sort { $0.closedAt < $1.closedAt }
        if result.closedSets.count > Self.maxClosedSets {
            result.closedSets.removeFirst(result.closedSets.count - Self.maxClosedSets)
        }
        result.updatedAt = max(updatedAt, other.updatedAt)
        return result
    }

    /// Same rule as known entries — the newer sighting of a key wins — so
    /// two copies of an older build can't drop or regress what a newer one
    /// recorded. An entry with no readable key is kept unless an identical
    /// one is already there.
    static func mergedOpaque(
        _ mine: [OpaqueWorkspaceEntry], _ theirs: [OpaqueWorkspaceEntry]
    ) -> [OpaqueWorkspaceEntry] {
        var result = mine
        for entry in theirs {
            if let key = entry.key, let i = result.firstIndex(where: { $0.key == key }) {
                if (entry.lastSeen ?? .distantPast) > (result[i].lastSeen ?? .distantPast) {
                    result[i] = entry
                }
            } else if !result.contains(entry) {
                result.append(entry)
            }
        }
        return result
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
    /// See `WorkspaceGeneration.unknownEntries`.
    public var unknownEntries: [OpaqueWorkspaceEntry] = []

    public init(id: String = UUID().uuidString, name: String, savedAt: Date,
                entries: [WorkspaceEntry]) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, savedAt, entries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        (entries, unknownEntries) = WorkspaceEntrySlot.split(
            try c.decode([WorkspaceEntrySlot].self, forKey: .entries))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(WorkspaceEntriesForEncoding(known: entries, opaque: unknownEntries),
                     forKey: .entries)
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
    private var previousLive: Set<String>?
    private var previousLiveBoot: String?
    /// Missing from the last call, not yet confirmed closed: when first missed.
    private var suspects: [String: Date] = [:]

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
        // A file that exists but can't be read is not a missing one: a
        // fresh generation written over it would erase whatever a newer
        // build (or a damaged write worth recovering) left there.
        var generation = try current?.bootID == bootID
            ? current!
            : readExisting(WorkspaceGeneration.self, from: generationURL(bootID))
                ?? WorkspaceGeneration(bootID: bootID, updatedAt: now)
        var changed = false
        // Closures are seen as sessions dropping out of the live set, but
        // only once they've been missing from two calls in a row, dated to
        // the first. One absence can be a registry file caught mid-write;
        // recording it would fold a running session into whatever group
        // closed nearby. Until confirmed, a suspect stays in the baseline.
        let liveKeys = Set(live.map(\.key))
        var baseline = liveKeys
        var stillSuspect: [String: Date] = [:]
        if let previous = previousLive, previousLiveBoot == bootID {
            var confirmed: [Date: [String]] = [:]
            for key in previous.subtracting(liveKeys) {
                if let since = suspects[key] {
                    confirmed[since, default: []].append(key)
                } else {
                    stillSuspect[key] = now
                }
            }
            for (since, keys) in confirmed.sorted(by: { $0.key < $1.key }) {
                generation.noteClosed(keys.sorted(), at: since)
                changed = true
            }
            baseline.formUnion(stillSuspect.keys)
        } else {
            // First look this process has had at this boot. Anything that
            // was running at the last write and isn't now closed while
            // nobody was watching: AgentDeck quit or was being updated
            // when iTerm went down. Treated as one set at that write.
            let missed = generation.closedWhileUnobserved(
                live: liveKeys, freshness: 2 * refreshInterval + 30)
            if !missed.isEmpty {
                generation.noteClosed(missed, at: generation.updatedAt)
                changed = true
            }
        }
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
            previousLive = baseline
            previousLiveBoot = bootID
            suspects = stillSuspect
            return false
        }
        generation.updatedAt = now
        // Merged with the file under a lock, not written over it: a second
        // app instance (say, a source build beside the installed one) keeps
        // its own copy, and the last writer would otherwise erase whatever
        // the other had added.
        let url = generationURL(bootID)
        generation = try withLock {
            if let onDisk = try readExisting(WorkspaceGeneration.self, from: url) {
                generation = generation.merged(with: onDisk)
            }
            try write(generation, to: url)
            return generation
        }
        // Adopted only once it is on disk, the baseline included: advanced
        // before a failed write, the closures in it would never be seen
        // again.
        current = generation
        previousLive = baseline
        previousLiveBoot = bootID
        suspects = stillSuspect
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

    // MARK: Restore reservations

    /// Sessions a restore has launched, or may have, that haven't been seen
    /// running yet. On disk and under the store's lock, so they hold across
    /// an AgentDeck restart and between two running copies; in memory, a
    /// relaunch mid-restore forgot them and the next click could start the
    /// same conversation a second time. Nothing expires on a timer: a
    /// reservation ends when its session is seen running, or when the user
    /// clears it after checking iTerm.
    struct ReservationFile: Codable {
        var schemaVersion = 1
        var reservations: [String: Date] = [:]
    }

    var reservationsURL: URL { directory.appendingPathComponent("reservations.json") }

    public func reservations() -> [String: Date] {
        read(ReservationFile.self, from: reservationsURL)?.reservations ?? [:]
    }

    /// Reserves whichever of `keys` aren't reserved already, atomically, and
    /// returns those: only they may be launched.
    @discardableResult
    public func reserve(_ keys: [String], at now: Date = Date()) throws -> Set<String> {
        try withLock {
            var file = read(ReservationFile.self, from: reservationsURL) ?? ReservationFile()
            let granted = Set(keys).subtracting(file.reservations.keys)
            guard !granted.isEmpty else { return [] }
            for key in granted { file.reservations[key] = now }
            try write(file, to: reservationsURL)
            return granted
        }
    }

    public func releaseReservations(_ keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        try withLock {
            var file = read(ReservationFile.self, from: reservationsURL) ?? ReservationFile()
            let before = file.reservations.count
            for key in keys { file.reservations[key] = nil }
            if file.reservations.count != before { try write(file, to: reservationsURL) }
        }
    }

    // MARK: Named workspaces

    public func named() -> [NamedWorkspace] {
        files(in: namedDirectory)
            .compactMap { read(NamedWorkspace.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves under a name not already taken: "givzey" becomes "givzey 2"
    /// rather than a second, indistinguishable "givzey". Returns the name
    /// used.
    @discardableResult
    public func save(_ workspace: NamedWorkspace) throws -> String {
        try withLock {
            var toSave = workspace
            let taken = Set(named().filter { $0.id != workspace.id }.map { $0.name.lowercased() })
            if taken.contains(toSave.name.lowercased()) {
                var n = 2
                while taken.contains("\(workspace.name) \(n)".lowercased()) { n += 1 }
                toSave.name = "\(workspace.name) \(n)"
            }
            try write(toSave, to: namedURL(toSave.id))
            return toSave.name
        }
    }

    /// Changes one saved workspace in place, reading it fresh under the
    /// lock. A whole-workspace save from a copy read earlier could undo a
    /// change another copy of the app had made meanwhile. Returns false if
    /// it no longer exists.
    @discardableResult
    public func updateNamed(id: String, _ change: (inout NamedWorkspace) -> Void) throws -> Bool {
        try withLock {
            guard var workspace = read(NamedWorkspace.self, from: namedURL(id)) else { return false }
            change(&workspace)
            try write(workspace, to: namedURL(id))
            return true
        }
    }

    public func deleteNamed(id: String) throws {
        try FileManager.default.removeItem(at: namedURL(id))
    }

    func namedURL(_ id: String) -> URL {
        namedDirectory.appendingPathComponent("\(Self.safeFilename(id)).json")
    }

    // MARK: Files

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Fails closed: proceeding unlocked would reintroduce exactly the
        // lost-update race the lock exists to prevent.
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

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

    /// A file that exists but couldn't be read or decoded. Thrown instead
    /// of treating it as absent wherever the caller is about to write.
    public struct UnreadableFile: Error, CustomStringConvertible {
        public var path: String
        public var description: String {
            "\(path) exists but can't be read by this version; left untouched"
        }
    }

    /// nil only when there is no file.
    private func readExisting<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let value = try? SnapshotStore.decoder().decode(type, from: data) else {
            throw UnreadableFile(path: url.path)
        }
        return value
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
