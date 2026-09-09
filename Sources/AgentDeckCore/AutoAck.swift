import Foundation

/// Finished (`done`) sessions pile up — a heavy user routinely has 10+ — and
/// keeping them all in the attention count trains the eye to ignore it. After
/// a grace period an unacknowledged done session is auto-acknowledged: the row
/// stays in the list but drops out of the done-count and sinks in the sort.
public enum AutoAck {
    /// Keys of `done` sessions that have been finished (and unacknowledged)
    /// longer than `after`, so the caller can ack them with `now`.
    public static func expiredDoneKeys(
        _ snapshots: [SessionSnapshot],
        acks: [String: Date],
        now: Date = Date(),
        after: TimeInterval = 30 * 60
    ) -> [String] {
        snapshots.compactMap { s in
            guard s.state == .done else { return nil }
            // already acknowledged after its finish? nothing to do.
            if let acked = acks[s.key], acked >= s.updatedAt { return nil }
            return now.timeIntervalSince(s.updatedAt) >= after ? s.key : nil
        }
    }
}
