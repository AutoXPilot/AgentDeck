import Foundation

/// What agy's presence locks say right now: which conversations run, and
/// which process runs each.
///
/// agy can switch conversations inside one process, so the pid a hook
/// recorded can since have moved on. Each agy process keeps exactly one
/// `presence/<id>.lock` open, the conversation it runs now (observed); one
/// conversation can also be open in a second process that holds no lock.
/// So a pid holding another conversation's lock has moved on, a pid
/// holding none may still be in it, and the holder is where the
/// conversation runs when nothing better is known.
public struct AgyPresence: Equatable, Sendable {
    /// The presence folder was listed. Without it nothing below is evidence.
    public var listed: Bool
    /// Conversations whose lock some process holds.
    public var held: Set<String>
    /// Conversation → the one agy process holding its lock.
    public var holderOf: [String: Int32]
    /// Process → the one conversation whose lock it holds.
    public var heldBy: [Int32: String]
    /// Held conversations whose holder can't be told: two processes, or a
    /// process with two. Neither side gets a mapping.
    public var ambiguous: Set<String>
    /// Processes whose descriptors couldn't be read.
    public var unreadable: Set<Int32>

    public init(listed: Bool, held: Set<String> = [], holderOf: [String: Int32] = [:],
                heldBy: [Int32: String] = [:], ambiguous: Set<String> = [],
                unreadable: Set<Int32> = []) {
        self.listed = listed
        self.held = held
        self.holderOf = holderOf
        self.heldBy = heldBy
        self.ambiguous = ambiguous
        self.unreadable = unreadable
    }

    public static let unknown = AgyPresence(listed: false)

    /// `held` nil: the folder wasn't listed. `lockPaths`: each agy pid's
    /// open presence-lock paths, nil where unreadable. `presenceDirectory`
    /// must be resolved (no symlinks), as the kernel reports paths.
    public static func resolve(held: Set<String>?, lockPaths: [Int32: [String]?],
                               presenceDirectory: String) -> AgyPresence {
        guard let held else { return .unknown }
        var idsOf: [Int32: Set<String>] = [:]
        var unreadable = Set<Int32>()
        for (pid, paths) in lockPaths {
            guard let paths else { unreadable.insert(pid); continue }
            // an open file whose lock isn't held proves nothing
            let ids = heldIds(in: paths, presenceDirectory: presenceDirectory, isHeld: held.contains)
            if !ids.isEmpty { idsOf[pid] = ids }
        }
        var pidsOf: [String: Set<Int32>] = [:]
        var ambiguous = Set<String>()
        for (pid, ids) in idsOf {
            if ids.count > 1 { ambiguous.formUnion(ids) }
            for id in ids { pidsOf[id, default: []].insert(pid) }
        }
        for (id, pids) in pidsOf where pids.count > 1 { ambiguous.insert(id) }
        var holderOf: [String: Int32] = [:]
        var heldBy: [Int32: String] = [:]
        for (id, pids) in pidsOf where !ambiguous.contains(id) {
            guard let pid = pids.first, idsOf[pid]?.count == 1 else { continue }
            holderOf[id] = pid
            heldBy[pid] = id
        }
        return AgyPresence(listed: true, held: held, holderOf: holderOf, heldBy: heldBy,
                           ambiguous: ambiguous, unreadable: unreadable)
    }

    /// Reads it: the presence folder, then the open lock files of `pids`
    /// (agy processes; the caller caches that list).
    public static func observe(pids: [Int32],
                               directory: URL = AntigravityState.defaultDirectory) -> AgyPresence {
        let held = AntigravityState.listedConversations(directory: directory)
            .map { Set($0.map(\.conversationId)) }
        let presence = presenceDirectory(directory)
        var paths: [Int32: [String]?] = [:]
        for pid in pids { paths[pid] = ProcessTree.agyLockPaths(of: pid) }
        return resolve(held: held, lockPaths: paths, presenceDirectory: presence)
    }

    /// Whether `pid`'s snapshot of `id` is stale: the process now holds a
    /// different conversation's lock. A process holding none may still be
    /// in it, and nothing is known when the folder wasn't listed.
    public func movedOn(pid: Int32, from id: String) -> Bool {
        guard listed, let now = heldBy[pid] else { return false }
        return now != id.lowercased()
    }

    /// The presence folder as the kernel names it in a process's open
    /// files: symlinks resolved.
    public static func presenceDirectory(_ directory: URL = AntigravityState.defaultDirectory) -> String {
        directory.appendingPathComponent("presence", isDirectory: true).resolvingSymlinksInPath().path
    }

    /// The held conversations among one process's open lock paths, by the
    /// same rules as `resolve`: in the presence folder, a UUID name, held.
    static func heldIds(in paths: [String], presenceDirectory: String,
                        isHeld: (String) -> Bool) -> Set<String> {
        let prefix = presenceDirectory.hasSuffix("/") ? presenceDirectory : presenceDirectory + "/"
        var ids = Set<String>()
        for path in paths where path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            guard name.hasSuffix(".lock"), !name.contains("/"),
                  let uuid = UUID(uuidString: String(name.dropLast(".lock".count)))
            else { continue }
            let id = uuid.uuidString.lowercased()
            if isHeld(id) { ids.insert(id) }
        }
        return ids
    }

    /// Whether to act on an agy row's pane now: focus it, or rename its tab.
    /// Read fresh at that moment, since a process can switch conversations
    /// between reloads.
    /// - An adopted holder must still hold this conversation's lock; if
    ///   its files can't be read (it exited), that isn't proof.
    /// - A hook-recorded pid is refused only once it holds another
    ///   conversation's lock past the grace: a lockless process may still
    ///   be in it, and a new conversation's first hook can come before
    ///   its lock.
    public static func mayAct(pid: Int32, id: String, adopted: Bool, snapshotAge: TimeInterval,
                              lockPaths: [String]?, presenceDirectory: String,
                              isHeld: (String) -> Bool) -> Bool {
        let own = id.lowercased()
        guard let lockPaths else { return !adopted }
        let held = heldIds(in: lockPaths, presenceDirectory: presenceDirectory, isHeld: isHeld)
        if adopted { return held.contains(own) }
        guard !held.isEmpty, !held.contains(own) else { return true }
        return snapshotAge <= Liveness.agySwitchGrace
    }
}
