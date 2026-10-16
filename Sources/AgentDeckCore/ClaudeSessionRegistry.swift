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
        /// The session's working directory. Durable across a reboot and the
        /// only thing besides `sessionId` that resuming needs.
        public var cwd: String?
        /// When the process started, per Claude's own record. Paired with
        /// `pid` this is a process identity, which is what makes it safe to
        /// trust a registry file whose process may have exited.
        public var startedAt: Date?
        public var statusUpdatedAt: Date?
        /// The registry file's mtime, filled in at load time. Fallback for
        /// `observedAt` when a build omits `statusUpdatedAt` (some Claude
        /// versions), so reconciliation never silently no-ops.
        public var fileModifiedAt: Date?

        public init(
            pid: Int32, sessionId: String, status: String, waitingFor: String? = nil,
            name: String? = nil, nameSource: String? = nil, kind: String? = nil,
            cwd: String? = nil, startedAt: Date? = nil,
            statusUpdatedAt: Date? = nil, fileModifiedAt: Date? = nil
        ) {
            self.pid = pid
            self.sessionId = sessionId
            self.status = status
            self.waitingFor = waitingFor
            self.name = name
            self.nameSource = nameSource
            self.kind = kind
            self.cwd = cwd
            self.startedAt = startedAt
            self.statusUpdatedAt = statusUpdatedAt
            self.fileModifiedAt = fileModifiedAt
        }

        public var isUserNamed: Bool { name != nil && nameSource != "derived" }

        /// Best available time for "when the registry last observed this
        /// session's status" — the field if present, else the file mtime.
        /// Used as the single authority for both the newer-than comparison
        /// and the corrected snapshot's timestamp, so an unchanged entry can
        /// never keep re-arming (mtime is stable until the file is rewritten).
        public var observedAt: Date? { statusUpdatedAt ?? fileModifiedAt }
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_REGISTRY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    public static func parse(_ data: Data, fileModifiedAt: Date? = nil) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let pid = (dict["pid"] as? NSNumber)?.int32Value,
              let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty,
              let status = dict["status"] as? String
        else { return nil }
        let stamp = (dict["statusUpdatedAt"] as? NSNumber)?.doubleValue
        let started = (dict["startedAt"] as? NSNumber)?.doubleValue
        return Entry(
            pid: pid,
            sessionId: sessionId,
            status: status,
            waitingFor: dict["waitingFor"] as? String,
            name: dict["name"] as? String,
            nameSource: dict["nameSource"] as? String,
            kind: dict["kind"] as? String,
            cwd: (dict["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            startedAt: started.map { Date(timeIntervalSince1970: $0 / 1000) },
            statusUpdatedAt: stamp.map { Date(timeIntervalSince1970: $0 / 1000) },
            fileModifiedAt: fileModifiedAt
        )
    }

    public static func load(from directory: URL = ClaudeSessionRegistry.defaultDirectory)
        -> [Int32: Entry]
    {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [:] }
        var entries: [Int32: Entry] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let entry = parse(data, fileModifiedAt: mtime) else { continue }
            entries[entry.pid] = entry
        }
        return entries
    }

    /// The sessions Claude believes are running right now, keyed by session id.
    ///
    /// This is the same set `claude agents --json` returns — verified on a
    /// machine with 36 live sessions, zero differences in either direction —
    /// without spawning anything. That matters: the `claude` binary lives at
    /// a version-named path that gets pruned on update, a GUI app does not
    /// inherit the shell's PATH, and a subprocess on the reload path would
    /// block the main actor.
    ///
    /// Registry files outlive their process, so every entry is checked
    /// against a live pid AND that pid's start time. Without the second
    /// check a recycled pid would resurrect a dead session forever.
    public static func liveSessions(
        from directory: URL = ClaudeSessionRegistry.defaultDirectory,
        probe: Liveness.ProcessProbe = .system,
        slack: TimeInterval = 120
    ) -> [String: Entry] {
        var live: [String: Entry] = [:]
        for entry in load(from: directory).values {
            guard isLive(entry, probe: probe, slack: slack) else { continue }
            // One session id can only have one live process. If two files
            // claim it, prefer the one that started later — the older is a
            // stale file whose pid has been reused.
            if let existing = live[entry.sessionId],
               (existing.startedAt ?? .distantPast) >= (entry.startedAt ?? .distantPast) {
                continue
            }
            live[entry.sessionId] = entry
        }
        return live
    }

    /// Best-effort pid-reuse rejection, not proof of identity.
    ///
    /// It catches the ordinary case — a long-dead session whose pid has been
    /// handed to something that started much later — and nothing stronger.
    /// Known holes, accepted because the failure mode is one stale row
    /// rather than a wrong action:
    ///  - an entry with no `startedAt` is accepted on liveness alone;
    ///  - a replacement that started inside `slack` is accepted, and then
    ///    stays accepted for as long as it lives;
    ///  - no check that the process is even Claude.
    /// Tightening this needs to know what Claude's `startedAt` actually
    /// measures, which isn't documented.
    static func isLive(
        _ entry: Entry, probe: Liveness.ProcessProbe, slack: TimeInterval
    ) -> Bool {
        guard let started = probe.startTime(entry.pid) else { return false }
        guard let claimed = entry.startedAt else { return true }
        return started <= claimed.addingTimeInterval(slack)
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

    /// A row for a live session the hooks never reported — one that started
    /// before the hooks were installed, or whose snapshot was swept while it
    /// sat idle. Without this they are simply invisible, which on one real
    /// machine meant 15 rows for 36 live sessions, two of them blocked on
    /// the user.
    ///
    /// Deliberately NOT set:
    /// - `notificationType`: `normalize` downgrades a `.waiting` row whose
    ///   notification type isn't a recognised blocking prefix, so putting
    ///   the registry's free-text `waitingFor` there would silently un-block
    ///   the row. The reason travels in the pipeline's `waitingReasons`.
    /// - `.done` / `.error`: neither can be inferred from a status. They are
    ///   hook-only facts, and guessing them would fake a completion.
    public static func discoveredSnapshot(
        from entry: ClaudeSessionRegistry.Entry
    ) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude,
            sessionId: entry.sessionId,
            projectPath: entry.cwd ?? "",
            state: blockedState(entry.status) ? .waiting : unblockedState(entry.status),
            event: "RegistryDiscovery",
            // Never `now`: a timestamp that advances on every scan re-arms
            // acknowledged waits through Attention's ack comparison, so an
            // acknowledged session would nag again on the next reload.
            updatedAt: entry.observedAt ?? entry.startedAt ?? .distantPast,
            terminalSessionId: nil,
            agentPid: entry.pid,
            permissionMode: nil,
            model: nil,
            effort: nil
        )
    }

    public static func reconcile(
        snapshot: SessionSnapshot, entry: ClaudeSessionRegistry.Entry?
    ) -> Result {
        guard let entry, entry.sessionId == snapshot.sessionId else {
            return Result(state: snapshot.state, waitingFor: nil, correctedByRegistry: false)
        }
        // observedAt (statusUpdatedAt ?? file mtime) is the single authority.
        // Using mtime as the fallback means a build that omits statusUpdatedAt
        // still reconciles — and because mtime is stable until the file is
        // actually rewritten, an unchanged entry can't keep re-arming an ack.
        let registryIsNewer = (entry.observedAt ?? .distantPast) > snapshot.updatedAt

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
        snapshot: SessionSnapshot, entry: ClaudeSessionRegistry.Entry?
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
        // Claude sessions with NO registry entry (pid unknown, older CLI, or
        // a machine that never writes ~/.claude/sessions) must still explain
        // their wait from the hook's own notification type — this fallback
        // used to exist only for Codex, and the golden file-path test caught
        // the gap.
        let reason = outcome.waitingFor
            ?? (adjusted.state == .waiting ? snapshot.notificationType : nil)
        // A correction is an OBSERVATION and must carry its own time, or
        // three consumers lie: acks judge the corrected state against the
        // stale hook time (a registry-detected block on an acked session
        // stays invisible), WaitingTracker seeds its clock hours in the past
        // (instant escalation), and the row shows the wrong age. Use the SAME
        // observedAt the comparison used — a separate `now` would re-arm the
        // ack on every reload even though nothing changed.
        if outcome.correctedByRegistry, let observed = entry?.observedAt,
           observed > adjusted.updatedAt {
            adjusted.updatedAt = observed
        }
        return (adjusted, reason)
    }
}
