import Foundation

/// The whole snapshots→UI derivation as one pure function. This ordering is
/// load-bearing (a mis-ordering here shipped a production bug when it lived
/// as untested app-target glue), so it lives in the core where every hop is
/// under test. The app's reload() should contain no decisions: read files,
/// call this, assign the output, perform the removals it was told about.
/// The terminal window a background job's conversation moved out of. When
/// a session goes to the background Claude keeps both: the job carries on
/// the conversation in a private pty, and the window drops to the agents
/// view with that job selected. So the job is the session and the window is
/// the way to it, but only a way: the agents view is a list, and nothing
/// shows it's still on this job.
public struct ParkedWindow: Equatable, Sendable {
    public var entry: ClaudeSessionRegistry.Entry
    /// The pane its last hook recorded, if that's still its process's.
    public var pane: String?

    public init(entry: ClaudeSessionRegistry.Entry, pane: String? = nil) {
        self.entry = entry
        self.pane = pane
    }
}

public enum SessionPipeline {
    public static let inferredWaitingReason = "may need you (no hook reports this prompt)"

    public struct Output: Sendable {
        public var rows: [SessionSnapshot]
        public var frozenOrder: [String]?
        public var alertCount: Int
        public var doneCount: Int
        public var mostUrgent: SessionState?
        public var waitingReasons: [String: String]
        /// Row key of a background job → the window it moved out of.
        public var parkedWindows: [String: ParkedWindow] = [:]
    }

    /// Job session id → the live window parked on it. Live entries only:
    /// their identity is checked, and a file can outlive its process.
    static func parkedPairs(
        _ liveSessions: [String: ClaudeSessionRegistry.Entry]
    ) -> [String: ClaudeSessionRegistry.Entry] {
        var pairs: [String: ClaudeSessionRegistry.Entry] = [:]
        let windows = liveSessions.values.filter { $0.kind == "interactive" && $0.parkedJobId != nil }
        for job in liveSessions.values where job.kind == "bg" && !job.isSpare {
            guard let id = job.jobId else { continue }
            let parked = windows.filter { $0.parkedJobId == id }
                .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            if let parked { pairs[job.sessionId] = parked }
        }
        return pairs
    }

    /// Whose controlling terminal locates this row: the parked window's for
    /// a job, whose own tty is a private pty. Else the registry's current
    /// process, else the snapshot's.
    public static func terminalPid(
        for row: SessionSnapshot, registryPid: Int32?, parkedWindows: [String: ParkedWindow]
    ) -> Int32? {
        parkedWindows[row.key]?.entry.pid ?? registryPid ?? row.agentPid
    }

    /// A click that reached the pane counts as seeing the session, except
    /// a parked job waiting on you: the window may be on another job, and
    /// clearing the badge there would lose the one alert that matters.
    public static func focusAcknowledges(_ row: SessionSnapshot,
                                         parkedWindows: [String: ParkedWindow]) -> Bool {
        !(parkedWindows[row.key] != nil && row.state == .waiting)
    }

    public static func run(
        snapshots: [SessionSnapshot],
        registry: [Int32: ClaudeSessionRegistry.Entry],
        liveSessions: [String: ClaudeSessionRegistry.Entry] = [:],
        inferredWaiting: [String: Date] = [:],
        discovered extra: [SessionSnapshot] = [],
        acks: [String: Date],
        frozenOrder: [String]?,
        popoverVisible: Bool,
        now: Date = Date()
    ) -> Output {
        var reasons: [String: String] = [:]
        // A spare worker still fires SessionStart, so it has a snapshot as
        // well as a registry entry, but there's nothing behind it to show
        // or focus. Only Claude's: a Codex id can collide with one. The live
        // entry decides; registry files outlive their processes, so another
        // counts only for the pid this snapshot names and with no live entry.
        func isSpare(_ snapshot: SessionSnapshot) -> Bool {
            guard snapshot.provider == .claude else { return false }
            if let live = liveSessions[snapshot.sessionId] { return live.isSpare }
            guard let pid = snapshot.agentPid, let entry = registry[pid],
                  entry.sessionId == snapshot.sessionId else { return false }
            return entry.isSpare
        }
        let normalized: [SessionSnapshot] = snapshots.filter { !isSpare($0) }.map { snapshot in
            // A snapshot whose ancestor walk
            // failed has no pid at all, and one resumed into a new process
            // has a stale one; either way a pid-only lookup missed the
            // registry entirely, so a session the registry *knows* is
            // blocked produced no alert until a hook happened to arrive.
            // `reconcile` re-checks the session id, so this can't mismatch.
            // The live, identity-checked entry for this session id comes
            // first. A pid lookup is consulted only when it names this same
            // session: pids are reused, so the file at a stale pid can belong
            // to another session, and preferring it hid the right one.
            // The registry is Claude's. A Codex session whose id matched a
            // Claude entry would otherwise adopt that process's pid and
            // lose its own pane.
            let isClaude = snapshot.provider == .claude
            let live = isClaude ? liveSessions[snapshot.sessionId] : nil
            let byPid = snapshot.agentPid.flatMap { isClaude ? registry[$0] : nil }
                .flatMap { $0.sessionId == snapshot.sessionId ? $0 : nil }
            let entry = live ?? byPid
            var outcome = StateReconciler.normalize(snapshot: snapshot, entry: entry)
            if let reason = outcome.waitingFor {
                reasons[snapshot.key] = ITermFocus.humanizeReason(reason)
            }
            // The registry knows the session's current process; the snapshot
            // knows the one its last hook ran in. If they differ the session
            // moved (resumed elsewhere, its hook missed), and the recorded
            // pane is the old process's: clicking it would focus a stale tab
            // and acknowledge a session it never reached. Adopt the live pid
            // and drop the pane, so focus resolves through the live process.
            // The recorded host is the old process's too.
            // A prompt no hook reports (Codex MCP elicitations; see
            // CodexStall): the row waits from when the thread got stuck,
            // so an acknowledgement after that holds until it moves again.
            // A stall older than the latest hook is from an earlier turn: a
            // newer prompt proves the thread moved on, even before the next
            // background check clears the cached stall.
            if outcome.snapshot.state == .working, let since = inferredWaiting[snapshot.key],
               since >= outcome.snapshot.updatedAt {
                outcome.snapshot.state = .waiting
                outcome.snapshot.updatedAt = since
                reasons[snapshot.key] = inferredWaitingReason
            }
            if let live, live.pid != snapshot.agentPid {
                outcome.snapshot.agentPid = live.pid
                outcome.snapshot.terminalSessionId = nil
                outcome.snapshot.hostKind = nil
                outcome.snapshot.hostBundlePath = nil
            }
            return outcome.snapshot
        }

        // Live sessions the hooks never reported. A snapshot always wins —
        // it carries the pane id and the hook-derived state — so these are
        // added only where no row exists for that session id.
        let known = Set(normalized.map(\.key))
        let discovered: [SessionSnapshot] = liveSessions.values
            .filter { !$0.isSpare }
            .map(StateReconciler.discoveredSnapshot(from:))
            .filter { !known.contains($0.key) }
            .map { row in
                if row.state == .waiting,
                   let reason = liveSessions[row.sessionId]?.waitingFor {
                    reasons[row.key] = ITermFocus.humanizeReason(reason)
                }
                return row
            }

        // Dedupe before the counts, not after: alertCount/doneCount used to
        // be computed from a list that could still contain duplicates while
        // only `rows` was deduplicated, so a doubled session counted twice
        // in the badge.
        // Other providers' running sessions found without a hook
        // (Antigravity's presence locks); the same rule — a snapshot wins.
        let seen = known.union(discovered.map(\.key))
        let others = extra.filter { !seen.contains($0.key) }

        // One row per parked pair. The job's: its state is the current one,
        // and the window's stopped when the conversation left it. After
        // pane clearing, so a stale pane isn't carried over; before dedupe
        // and counts, so the pair counts once.
        let pairs = parkedPairs(liveSessions)
        let windowIds = Set(pairs.values.map(\.sessionId))
        var parkedWindows: [String: ParkedWindow] = [:]
        for (jobId, window) in pairs {
            let row = normalized.first { $0.provider == .claude && $0.sessionId == window.sessionId }
            parkedWindows[SessionKey.make(.claude, jobId)] =
                ParkedWindow(entry: window, pane: row?.terminalSessionId)
        }
        let all = RowOrdering.deduplicated(normalized + discovered + others).filter {
            !($0.provider == .claude && windowIds.contains($0.sessionId))
        }
        let sorted = Attention.sorted(all, acks: acks)
        var rows = sorted
        var order: [String]?
        if popoverVisible {
            let arranged = RowOrdering.arrange(sorted: sorted, frozenOrder: frozenOrder)
            rows = arranged.rows
            order = arranged.frozenOrder
        }
        return Output(
            rows: RowOrdering.deduplicated(rows),
            frozenOrder: order,
            alertCount: Attention.alertCount(all, acks: acks),
            doneCount: Attention.doneCount(all, acks: acks),
            mostUrgent: Attention.mostUrgent(all, acks: acks),
            waitingReasons: reasons,
            parkedWindows: parkedWindows
        )
    }
}
