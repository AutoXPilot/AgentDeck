import Darwin
import Foundation

/// What Antigravity's own state directory says about running
/// conversations, read as metadata only.
///
/// Read: the names of `presence/*.lock` and whether a process holds each
/// one; `cache/last_conversations.json` (workspace path → last
/// conversation id); whether `conversations/<id>.db` exists.
/// Never read: `history.jsonl` (prompt text), the conversation databases,
/// `conversation_summaries.db`, `brain/`, logs.
public enum AntigravityState {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    /// Whether some process holds `url`'s lock. A running agy holds its
    /// conversation's presence lock for as long as it runs (observed with
    /// agy 1.4.7); the file itself stays behind after exit and its mtime
    /// never changes, so only the lock state means anything.
    ///
    /// Opened read-only and never created, written or unlinked. The probe
    /// is a non-blocking shared lock released at once: it fails only while
    /// another process holds the lock.
    public static func isLockHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// A held presence lock: a running conversation, and when its lock
    /// file was created (stable, so a row's age doesn't advance per scan).
    public struct Presence: Equatable, Sendable {
        public var conversationId: String
        public var since: Date?
    }

    /// Conversations whose presence lock is held right now. Ids are
    /// canonical lowercased UUIDs; anything else in the folder is ignored.
    public static func runningConversations(
        directory: URL = defaultDirectory,
        isHeld: (URL) -> Bool = isLockHeld
    ) -> [Presence] {
        let presence = directory.appendingPathComponent("presence", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: presence.path)
        else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".lock"),
                  let uuid = UUID(uuidString: String(name.dropLast(".lock".count)))
            else { return nil }
            let url = presence.appendingPathComponent(name)
            guard isHeld(url) else { return nil }
            let created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .creationDate] as? Date
            return Presence(conversationId: uuid.uuidString.lowercased(), since: created)
        }
    }

    /// Conversation id → workspace path, only where exactly one workspace
    /// names that conversation. The cache keeps one conversation per
    /// workspace — the last one used there, not an index of running
    /// sessions — so it is a hint for the folder and nothing else.
    public static func unambiguousWorkspaces(directory: URL = defaultDirectory) -> [String: String] {
        let url = directory.appendingPathComponent("cache/last_conversations.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return unambiguousWorkspaces(fromCache: data)
    }

    static func unambiguousWorkspaces(fromCache data: Data) -> [String: String] {
        guard let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var paths: [String: [String]] = [:]
        for (path, value) in map {
            guard path.hasPrefix("/"), let raw = value as? String,
                  let uuid = UUID(uuidString: raw) else { continue }
            paths[uuid.uuidString.lowercased(), default: []].append(path)
        }
        return paths.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    /// Rows for running conversations no hook has reported. They carry
    /// what is verified — the conversation is running — and the folder
    /// only when the cache names it unambiguously. No pid and no pane: such
    /// a row can't be focused, and without a folder it is never captured
    /// for restore. `.done`/`.error` are hook-only facts and never guessed.
    public static func discoveredSnapshots(
        _ running: [Presence], workspaces: [String: String]
    ) -> [SessionSnapshot] {
        running.map { presence in
            SessionSnapshot(
                provider: .antigravity,
                sessionId: presence.conversationId,
                projectPath: workspaces[presence.conversationId] ?? "",
                state: .ready,
                event: discoveryEvent,
                // never the scan time: an advancing timestamp re-arms acks
                updatedAt: presence.since ?? .distantPast)
        }
    }

    public static let discoveryEvent = "PresenceDiscovery"

    /// Whether agy still has the conversation (its database file exists;
    /// never opened). nil when that can't be told.
    public static func conversationExists(
        id: String, directory: URL = defaultDirectory
    ) -> Bool? {
        guard let uuid = UUID(uuidString: id) else { return false }
        let conversations = directory.appendingPathComponent("conversations", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: conversations.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return FileManager.default.fileExists(
            atPath: conversations.appendingPathComponent(
                "\(uuid.uuidString.lowercased()).db").path)
    }
}
