import Foundation

/// Claude Code maintains a live registry of its own sessions, one JSON file
/// per process, at ~/.claude/sessions/<pid>.json. It knows things hooks
/// cannot express — notably that a permission prompt was ANSWERED (no hook
/// fires for that) and *why* a session is blocked.
///
/// Files persist after a process exits, so entries must always be matched
/// against a live pid and the snapshot's own session id before being trusted.
public enum ClaudeSessionRegistry {
    public struct Entry: Sendable, Equatable {
        public var pid: Int32
        public var sessionId: String
        /// "busy" | "shell" | "idle" | "waiting"
        public var status: String
        /// e.g. "permission prompt", "input needed", "sandbox request"
        public var waitingFor: String?
        /// Claude's own session name — cleaner than the terminal title and
        /// available without AppleScript (so it works outside iTerm too).
        public var name: String?
        /// "derived" marks an auto-generated name; absent means user-set.
        public var nameSource: String?
        /// "interactive" | "bg" | "daemon" | "daemon-worker"
        public var kind: String?
        public var statusUpdatedAt: Date?

        public init(
            pid: Int32, sessionId: String, status: String, waitingFor: String? = nil,
            name: String? = nil, nameSource: String? = nil, kind: String? = nil,
            statusUpdatedAt: Date? = nil
        ) {
            self.pid = pid
            self.sessionId = sessionId
            self.status = status
            self.waitingFor = waitingFor
            self.name = name
            self.nameSource = nameSource
            self.kind = kind
            self.statusUpdatedAt = statusUpdatedAt
        }

        public var isUserNamed: Bool { name != nil && nameSource != "derived" }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    public static func parse(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let pid = (dict["pid"] as? NSNumber)?.int32Value,
              let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty,
              let status = dict["status"] as? String
        else { return nil }
        let stamp = (dict["statusUpdatedAt"] as? NSNumber)?.doubleValue
        return Entry(
            pid: pid,
            sessionId: sessionId,
            status: status,
            waitingFor: dict["waitingFor"] as? String,
            name: dict["name"] as? String,
            nameSource: dict["nameSource"] as? String,
            kind: dict["kind"] as? String,
            statusUpdatedAt: stamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    public static func load(from directory: URL = ClaudeSessionRegistry.defaultDirectory)
        -> [Int32: Entry]
    {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [:] }
        var entries: [Int32: Entry] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let entry = parse(data) else { continue }
            entries[entry.pid] = entry
        }
        return entries
    }
}

/// Merges the hook-driven snapshot with Claude's registry view.
///
/// Neither source is a perfect oracle: hooks miss the answering of a
/// permission prompt, and the registry only writes on transitions so it can
/// lag a busy session. So the newer observation wins, and the registry is
/// used only to correct the blocked/not-blocked question it uniquely knows.
public enum StateReconciler {
    public struct Result: Equatable, Sendable {
        public var state: SessionState
        public var waitingFor: String?
        public var correctedByRegistry: Bool
    }

    static func blockedState(_ status: String) -> Bool { status == "waiting" }

    static func unblockedState(_ status: String) -> SessionState {
        // "busy"/"shell" = actively running; anything else = sitting idle
        (status == "busy" || status == "shell") ? .working : .ready
    }

    public static func reconcile(
        snapshot: SessionSnapshot, entry: ClaudeSessionRegistry.Entry?
    ) -> Result {
        guard let entry, entry.sessionId == snapshot.sessionId else {
            return Result(state: snapshot.state, waitingFor: nil, correctedByRegistry: false)
        }
        let registryIsNewer = (entry.statusUpdatedAt ?? .distantPast) > snapshot.updatedAt

        // A prompt was answered and no hook told us.
        if snapshot.state == .waiting, !blockedState(entry.status), registryIsNewer {
            return Result(
                state: unblockedState(entry.status), waitingFor: nil, correctedByRegistry: true
            )
        }
        // A block we never got a hook for.
        if blockedState(entry.status), snapshot.state != .waiting, registryIsNewer {
            return Result(
                state: .waiting, waitingFor: entry.waitingFor, correctedByRegistry: true
            )
        }
        // Agreement: enrich a known wait with the reason.
        if snapshot.state == .waiting {
            return Result(
                state: .waiting,
                waitingFor: entry.waitingFor ?? snapshot.notificationType,
                correctedByRegistry: false
            )
        }
        return Result(state: snapshot.state, waitingFor: nil, correctedByRegistry: false)
    }
}
