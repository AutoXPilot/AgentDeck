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

    /// Keys seen at least once, so a session that was already blocked
    /// before this tracker existed can be distinguished from one that
    /// became blocked while we were watching.
    private var seen: Set<String> = []

    public init() {}

    /// What has to survive a relaunch. Without it every restart forgot the
    /// cooldowns and re-announced each long-blocked session (seen: the same
    /// session notified after each of three relaunches in two days).
    public struct Memory: Codable, Equatable, Sendable {
        public var lastAnnounced: [String: Date] = [:]
        /// For announced episodes, when that episode began — a wait still
        /// open with the same start is the same episode, already announced.
        public var announcedEpisodes: [String: Date] = [:]
        public init() {}
    }

    private var announcedEpisodeStart: [String: Date] = [:]
    /// Not waiting at the last look; the episode ends if it misses again.
    private var missedOnce: Set<String> = []

    public init(memory: Memory) {
        lastAnnounced = memory.lastAnnounced
        announcedEpisodeStart = memory.announcedEpisodes
    }

    /// Bounded: cooldowns older than a day can't affect anything.
    public func memory(now: Date = Date()) -> Memory {
        var m = Memory()
        let horizon = now.addingTimeInterval(-24 * 3600)
        m.lastAnnounced = lastAnnounced.filter { $0.value > horizon }
        m.announcedEpisodes = announcedEpisodeStart.filter {
            announcedThisEpisode.contains($0.key)
        }
        return m
    }

    /// Treat the currently-blocked sessions as already handled, without
    /// posting anything.
    ///
    /// Needed because `candidates` deliberately trusts a snapshot's own
    /// timestamp so a session already waiting at launch doesn't restart its
    /// clock at zero — which is right for a restart, but means the first
    /// run after a change that makes *new* sessions visible would escalate
    /// every one of them at once. On one real machine that was two sessions
    /// blocked since August, both firing the moment the feature shipped.
    ///
    /// This starts their cooldown rather than marking the episode
    /// announced, so a session that stays blocked still notifies later —
    /// it just doesn't all arrive in the first second.
    public mutating func suppressExistingBacklog(
        _ snapshots: [SessionSnapshot], now: Date = Date()
    ) {
        for snapshot in snapshots where snapshot.state == .waiting {
            guard !seen.contains(snapshot.key) else { continue }
            seen.insert(snapshot.key)
            waitingSince[snapshot.key] = min(snapshot.updatedAt, now)
            lastAnnounced[snapshot.key] = now
        }
    }

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
        // cooldown clock, which is deliberately cross-episode) — once it
        // has been seen not waiting twice in a row. Ending it on a single
        // miss let one reload where the row briefly wasn't waiting (a
        // registry file caught mid-write) re-arm the episode, and a session
        // blocked all evening was announced again every hour on the hour.
        for key in waitingSince.keys where !blockedKeys.contains(key) {
            if missedOnce.contains(key) {
                waitingSince[key] = nil
                announcedThisEpisode.remove(key)
                announcedEpisodeStart[key] = nil
                missedOnce.remove(key)
            } else {
                missedOnce.insert(key)
            }
        }
        missedOnce.formIntersection(waitingSince.keys)
        missedOnce.subtract(blockedKeys)

        for snapshot in blocked { seen.insert(snapshot.key) }

        var due: [String] = []
        for snapshot in blocked {
            // Trust the snapshot's own timestamp: a session already waiting
            // when the app launches must not restart its clock at zero.
            let observed = min(snapshot.updatedAt, now)
            var since = waitingSince[snapshot.key] ?? observed
            if observed > since {
                // The wait carries a newer start than the one being tracked:
                // answered and blocked again between two looks, which the
                // registry reports as a new wait. A new episode, so it can
                // be announced; the cooldown still applies.
                since = observed
                announcedThisEpisode.remove(snapshot.key)
                announcedEpisodeStart[snapshot.key] = nil
            }
            if waitingSince[snapshot.key] == nil,
               announcedEpisodeStart[snapshot.key] == since {
                // announced before a relaunch; still the same wait
                announcedThisEpisode.insert(snapshot.key)
            }
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
            announcedEpisodeStart[key] = waitingSince[key]
        }
    }
}
