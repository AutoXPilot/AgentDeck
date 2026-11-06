import Foundation

/// The whole snapshots→UI derivation as one pure function. This ordering is
/// load-bearing (a mis-ordering here shipped a production bug when it lived
/// as untested app-target glue), so it lives in the core where every hop is
/// under test. The app's reload() should contain no decisions: read files,
/// call this, assign the output, perform the removals it was told about.
public enum SessionPipeline {
    public static let inferredWaitingReason = "may need you (no hook reports this prompt)"

    public struct Output: Sendable {
        public var rows: [SessionSnapshot]
        public var frozenOrder: [String]?
        public var alertCount: Int
        public var doneCount: Int
        public var mostUrgent: SessionState?
        public var waitingReasons: [String: String]
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
        let all = RowOrdering.deduplicated(normalized + discovered + others)
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
            waitingReasons: reasons
        )
    }
}
