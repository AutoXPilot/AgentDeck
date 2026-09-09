import Foundation

/// Decides when a blocked session has gone unanswered long enough to be
/// worth interrupting the user. Pure so the escalation rules are testable
/// without a notification centre.
///
/// Two-phase by design: `candidates(...)` reports who is DUE without any
/// mutation, the caller applies its own gate (e.g. "still needs attention?"),
/// then `commit(...)` records what was actually posted. Consuming eligibility
/// before the caller's gate — the old single-phase design — let a suppressed
/// post permanently disarm the episode.
public struct WaitingTracker: Sendable {
    /// When each still-waiting session was first observed waiting.
    private var waitingSince: [String: Date] = [:]
    /// Last time we posted for a key, so a chatty session (183 banners in a
    /// month, one session 20×) can't re-notify inside the cooldown even
    /// across separate block episodes.
    private var lastAnnounced: [String: Date] = [:]
    /// Keys announced within the CURRENT episode (cleared when the wait ends).
    private var announcedThisEpisode: Set<String> = []

    public init() {}

    public func waitingDuration(forKey key: String, now: Date = Date()) -> TimeInterval? {
        waitingSince[key].map { now.timeIntervalSince($0) }
    }

    /// Advances episode bookkeeping and returns keys eligible to notify:
    /// blocked past `threshold`, not already announced this episode, and past
    /// `cooldown` since their last notification. Does NOT record a post —
    /// call `commit` for the keys actually delivered.
    public mutating func candidates(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        threshold: TimeInterval,
        cooldown: TimeInterval = 3600
    ) -> [String] {
        let blocked = snapshots.filter { $0.state == .waiting }
        let blockedKeys = Set(blocked.map(\.key))

        // A session that stopped waiting ends its episode (but keeps its
        // cooldown clock, which is deliberately cross-episode).
        for key in waitingSince.keys where !blockedKeys.contains(key) {
            waitingSince[key] = nil
            announcedThisEpisode.remove(key)
        }

        var due: [String] = []
        for snapshot in blocked {
            // Trust the snapshot's own timestamp: a session already waiting
            // when the app launches must not restart its clock at zero.
            let since = waitingSince[snapshot.key] ?? min(snapshot.updatedAt, now)
            waitingSince[snapshot.key] = since
            guard !announcedThisEpisode.contains(snapshot.key) else { continue }
            guard now.timeIntervalSince(since) >= threshold else { continue }
            if let last = lastAnnounced[snapshot.key],
               now.timeIntervalSince(last) < cooldown {
                continue  // within cooldown
            }
            due.append(snapshot.key)
        }
        return due
    }

    /// Record that these keys were actually notified. Marks them announced for
    /// the episode and starts their cooldown.
    public mutating func commit(_ keys: [String], now: Date = Date()) {
        for key in keys {
            announcedThisEpisode.insert(key)
            lastAnnounced[key] = now
        }
    }
}
