import Foundation

/// Attention = an unacknowledged waiting/error/done event.
/// Acks are timestamps: a session re-earns attention when a newer event
/// arrives after the ack.
public enum Attention {
    /// Whether the row belongs in the attention group at all (drives the row
    /// tint and the sort order).
    public static func needsAttention(_ snapshot: SessionSnapshot, ackedAt: Date?) -> Bool {
        switch snapshot.state {
        case .waiting, .error, .done: break
        case .ready, .working: return false
        }
        guard let ackedAt else { return true }
        return snapshot.updatedAt > ackedAt
    }

    /// States that actually BLOCK you and belong in the menu-bar badge.
    ///
    /// `done` is deliberately excluded: finished sessions linger for hours,
    /// so counting them kept the badge permanently non-zero and trained the
    /// eye to ignore it — which is how a 13-hour block went unnoticed.
    public static func isBlocking(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.state == .waiting || snapshot.state == .error
    }

    /// The menu-bar badge count: unacknowledged waiting/error only.
    public static func alertCount(_ snapshots: [SessionSnapshot], acks: [String: Date]) -> Int {
        snapshots.filter { isBlocking($0) && needsAttention($0, ackedAt: acks[$0.key]) }.count
    }

    /// Finished-but-unacknowledged; surfaced as a muted secondary number.
    public static func doneCount(_ snapshots: [SessionSnapshot], acks: [String: Date]) -> Int {
        snapshots.filter { $0.state == .done && needsAttention($0, ackedAt: acks[$0.key]) }.count
    }

    /// The most urgent unacknowledged state present, for the menu-bar glyph.
    public static func mostUrgent(
        _ snapshots: [SessionSnapshot], acks: [String: Date]
    ) -> SessionState? {
        let unacked = snapshots.filter { needsAttention($0, ackedAt: acks[$0.key]) }
        if unacked.contains(where: { $0.state == .error }) { return .error }
        if unacked.contains(where: { $0.state == .waiting }) { return .waiting }
        if unacked.contains(where: { $0.state == .done }) { return .done }
        return nil
    }

    /// Unacknowledged waiting/error/done first (in that severity order),
    /// then working, ready, and finally acknowledged attention states.
    /// Ties break on most-recent activity.
    public static func sorted(
        _ snapshots: [SessionSnapshot], acks: [String: Date]
    ) -> [SessionSnapshot] {
        func rank(_ s: SessionSnapshot) -> Int {
            let attention = needsAttention(s, ackedAt: acks[s.key])
            switch (attention, s.state) {
            case (true, .waiting): return 0
            case (true, .error): return 1
            case (true, .done): return 2
            case (_, .working): return 10
            case (_, .ready): return 11
            default: return 12  // acknowledged waiting/error/done
            }
        }
        return snapshots.sorted {
            let (ra, rb) = (rank($0), rank($1))
            if ra != rb { return ra < rb }
            return $0.updatedAt > $1.updatedAt
        }
    }
}
