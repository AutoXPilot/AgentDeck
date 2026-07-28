import Foundation

/// Attention = an unacknowledged waiting/error/done event.
/// Acks are timestamps: a session re-earns attention when a newer event
/// arrives after the ack.
public enum Attention {
    public static func needsAttention(_ snapshot: SessionSnapshot, ackedAt: Date?) -> Bool {
        switch snapshot.state {
        case .waiting, .error, .done: break
        case .ready, .working: return false
        }
        guard let ackedAt else { return true }
        return snapshot.updatedAt > ackedAt
    }

    public static func count(_ snapshots: [SessionSnapshot], acks: [String: Date]) -> Int {
        snapshots.filter { needsAttention($0, ackedAt: acks[$0.key]) }.count
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
