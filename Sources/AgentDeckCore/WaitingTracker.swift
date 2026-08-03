import Foundation

/// Decides when a blocked session has gone unanswered long enough to be
/// worth interrupting the user. Pure so the escalation rules are testable
/// without a notification centre.
public struct WaitingTracker: Sendable {
    /// When each still-waiting session was first observed waiting.
    private var waitingSince: [String: Date] = [:]
    /// Episodes already announced, so one block notifies once.
    private var announced: Set<String> = []

    public init() {}

    public func waitingDuration(forKey key: String, now: Date = Date()) -> TimeInterval? {
        waitingSince[key].map { now.timeIntervalSince($0) }
    }

    /// Feeds the current world in and returns the keys that just crossed the
    /// threshold. A session that stops waiting forgets its episode, so the
    /// next block notifies again.
    public mutating func update(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        threshold: TimeInterval
    ) -> [String] {
        let blocked = snapshots.filter { $0.state == .waiting }
        let blockedKeys = Set(blocked.map(\.key))

        for key in waitingSince.keys where !blockedKeys.contains(key) {
            waitingSince[key] = nil
            announced.remove(key)
        }
        var due: [String] = []
        for snapshot in blocked {
            // Trust the snapshot's own timestamp: a session already waiting
            // when the app launches must not restart its clock at zero.
            let since = waitingSince[snapshot.key] ?? min(snapshot.updatedAt, now)
            waitingSince[snapshot.key] = since
            guard !announced.contains(snapshot.key) else { continue }
            if now.timeIntervalSince(since) >= threshold {
                announced.insert(snapshot.key)
                due.append(snapshot.key)
            }
        }
        return due
    }
}
