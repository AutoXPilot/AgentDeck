import Foundation

/// The whole snapshots→UI derivation as one pure function. This ordering is
/// load-bearing (a mis-ordering here shipped a production bug when it lived
/// as untested app-target glue), so it lives in the core where every hop is
/// under test. The app's reload() should contain no decisions: read files,
/// call this, assign the output, perform the removals it was told about.
public enum SessionPipeline {
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
        acks: [String: Date],
        frozenOrder: [String]?,
        popoverVisible: Bool,
        now: Date = Date()
    ) -> Output {
        var reasons: [String: String] = [:]
        let normalized: [SessionSnapshot] = snapshots.map { snapshot in
            let entry = snapshot.agentPid.flatMap { registry[$0] }
            let outcome = StateReconciler.normalize(
                snapshot: snapshot, entry: entry, now: now
            )
            if let reason = outcome.waitingFor {
                reasons[snapshot.key] = ITermFocus.humanizeReason(reason)
            }
            return outcome.snapshot
        }

        let sorted = Attention.sorted(normalized, acks: acks)
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
            alertCount: Attention.alertCount(normalized, acks: acks),
            doneCount: Attention.doneCount(normalized, acks: acks),
            mostUrgent: Attention.mostUrgent(normalized, acks: acks),
            waitingReasons: reasons
        )
    }
}
