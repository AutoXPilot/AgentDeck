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
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_REGISTRY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
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

    /// The whole per-row correction, in the order that matters:
    /// re-judge non-blocking notification types FIRST, then reconcile the
    /// corrected snapshot against the registry. Doing it the other way round
    /// let the registry hand back the stale `waiting` and silently undo the
    /// repair — which is exactly the bug this function exists to prevent.
    public static func normalize(
        snapshot: SessionSnapshot, entry: ClaudeSessionRegistry.Entry?,
        now: Date = Date()
    ) -> (snapshot: SessionSnapshot, waitingFor: String?) {
        var adjusted = snapshot
        if adjusted.state == .waiting, let type = snapshot.notificationType,
           !EventMapping.isBlockingNotification(type) {
            adjusted.state = .ready
        }
        guard snapshot.provider == .claude else {
            let reason = adjusted.state == .waiting
                ? snapshot.notificationType.map { $0.replacingOccurrences(of: "_", with: " ") }
                : nil
            return (adjusted, reason)
        }
        let outcome = reconcile(snapshot: adjusted, entry: entry)
        adjusted.state = outcome.state
        // A correction is an OBSERVATION and must carry its own time.
        // Leaving the old hook timestamp in place made three consumers lie:
        // acks judged the corrected state against the stale time (a
        // registry-detected block on an acked session was permanently
        // invisible), WaitingTracker seeded its clock hours in the past
        // (instant escalation), and the row displayed the wrong age.
        if outcome.correctedByRegistry {
            if let observed = entry?.statusUpdatedAt, observed > adjusted.updatedAt {
                adjusted.updatedAt = observed
            } else if entry?.statusUpdatedAt == nil {
                // no transition time available: "now" is still closer to the
                // truth than the hours-old hook time
                adjusted.updatedAt = now
            }
        }
        return (adjusted, outcome.waitingFor)
    }
}
