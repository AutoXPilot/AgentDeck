import Foundation
import Testing
@testable import AgentDeckCore

struct WaitingTrackerTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)

    func waiting(_ id: String, ageSeconds: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: id, projectPath: "/p",
            state: .waiting, event: "x", updatedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    /// candidates + commit in one step, the common case.
    func fire(
        _ tracker: inout WaitingTracker, _ snaps: [SessionSnapshot],
        now: Date, threshold: TimeInterval, cooldown: TimeInterval = 3600
    ) -> [String] {
        let due = tracker.candidates(snaps, now: now, threshold: threshold, cooldown: cooldown)
        tracker.commit(due, now: now)
        return due
    }

    @Test func firesOnceWhenThresholdCrossed() {
        var tracker = WaitingTracker()
        let fresh = [waiting("a", ageSeconds: 60)]
        #expect(fire(&tracker, fresh, now: now, threshold: 300).isEmpty)

        let later = now.addingTimeInterval(600)
        #expect(fire(&tracker, fresh, now: later, threshold: 300) == ["claude-a"])
        // already announced this episode — no repeat
        #expect(fire(&tracker, fresh, now: later.addingTimeInterval(600), threshold: 300).isEmpty)
    }

    @Test func alreadyLongWaitingSessionFiresImmediately() {
        var tracker = WaitingTracker()
        let old = [waiting("a", ageSeconds: 13 * 3600)]
        #expect(fire(&tracker, old, now: now, threshold: 300) == ["claude-a"])
    }

    @Test func suppressedPostDoesNotDisarmTheEpisode() {
        // the two-phase point: candidates reports due, but if the caller does
        // NOT commit (e.g. the session was acknowledged), a later reload can
        // still fire once the ack is cleared — the old design lost this.
        var tracker = WaitingTracker()
        let old = [waiting("a", ageSeconds: 3600)]
        let due = tracker.candidates(old, now: now, threshold: 300)
        #expect(due == ["claude-a"])
        // caller suppresses (does not commit)
        let laterDue = tracker.candidates(old, now: now.addingTimeInterval(10), threshold: 300)
        #expect(laterDue == ["claude-a"], "still eligible until actually posted")
    }

    @Test func cooldownSuppressesAcrossEpisodes() {
        // a session that blocks, resolves, and re-blocks within the cooldown
        // must not notify twice — the flapping fix.
        var tracker = WaitingTracker()
        let blocked = [waiting("a", ageSeconds: 3600)]
        #expect(fire(&tracker, blocked, now: now, threshold: 300, cooldown: 3600) == ["claude-a"])

        // resolves (episode ends)
        let working = [SessionSnapshot(provider: .claude, sessionId: "a", projectPath: "/p",
                                       state: .working, event: "x", updatedAt: now)]
        _ = fire(&tracker, working, now: now.addingTimeInterval(60), threshold: 300)

        // re-blocks 5 min later — inside the 1h cooldown → silent
        let reblocked = [SessionSnapshot(provider: .claude, sessionId: "a", projectPath: "/p",
                                         state: .waiting, event: "x", updatedAt: now)]
        #expect(fire(&tracker, reblocked, now: now.addingTimeInterval(400),
                     threshold: 300, cooldown: 3600).isEmpty)

        // but past the cooldown it notifies again
        #expect(fire(&tracker, reblocked, now: now.addingTimeInterval(3700),
                     threshold: 300, cooldown: 3600) == ["claude-a"])
    }

    @Test func leavingWaitingResetsTheEpisode() {
        var tracker = WaitingTracker()
        let blocked = [waiting("a", ageSeconds: 3600)]
        #expect(fire(&tracker, blocked, now: now, threshold: 300, cooldown: 0) == ["claude-a"])

        let unblocked = [SessionSnapshot(
            provider: .claude, sessionId: "a", projectPath: "/p",
            state: .working, event: "x", updatedAt: now
        )]
        #expect(fire(&tracker, unblocked, now: now, threshold: 300).isEmpty)
        #expect(tracker.waitingDuration(forKey: "claude-a") == nil)

        // blocked again with cooldown disabled → notifies again
        #expect(fire(&tracker, blocked, now: now, threshold: 300, cooldown: 0) == ["claude-a"])
    }

    @Test func thresholdChangeMidEpisodeIsHonored() {
        // start with a long threshold (not due), then shorten it
        var tracker = WaitingTracker()
        let s = [waiting("a", ageSeconds: 600)]  // 10 min blocked
        #expect(fire(&tracker, s, now: now, threshold: 3600).isEmpty)  // 60m threshold
        #expect(fire(&tracker, s, now: now, threshold: 300) == ["claude-a"])  // 5m threshold
    }

    @Test func backwardClockDoesNotFireEarly() {
        var tracker = WaitingTracker()
        let s = [waiting("a", ageSeconds: 60)]
        _ = tracker.candidates(s, now: now, threshold: 300)
        // clock steps backward: elapsed goes negative, must not cross threshold
        #expect(fire(&tracker, s, now: now.addingTimeInterval(-1000), threshold: 300).isEmpty)
    }

    @Test func nonWaitingStatesNeverFire() {
        var tracker = WaitingTracker()
        let snaps = [SessionState.ready, .working, .done, .error].map {
            SessionSnapshot(
                provider: .claude, sessionId: "\($0.rawValue)", projectPath: "/p",
                state: $0, event: "x", updatedAt: now.addingTimeInterval(-9999)
            )
        }
        #expect(fire(&tracker, snaps, now: now, threshold: 1).isEmpty)
    }

    @Test func reportsHowLongSomethingHasBeenWaiting() {
        var tracker = WaitingTracker()
        _ = tracker.candidates([waiting("a", ageSeconds: 120)], now: now, threshold: 300)
        let duration = tracker.waitingDuration(forKey: "claude-a", now: now)
        #expect(duration.map { abs($0 - 120) < 1 } == true)
    }
}

struct AutoAckTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)

    func done(_ id: String, ageSeconds: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(provider: .claude, sessionId: id, projectPath: "/p",
                        state: .done, event: "Stop", updatedAt: now.addingTimeInterval(-ageSeconds))
    }

    @Test func expiresDoneAfterGrace() {
        let fresh = done("fresh", ageSeconds: 600)      // 10 min
        let old = done("old", ageSeconds: 40 * 60)       // 40 min
        let keys = AutoAck.expiredDoneKeys([fresh, old], acks: [:], now: now, after: 30 * 60)
        #expect(keys == ["claude-old"])
    }

    @Test func neverTouchesWaitingOrError() {
        let waiting = SessionSnapshot(provider: .claude, sessionId: "w", projectPath: "/p",
                                      state: .waiting, event: "x",
                                      updatedAt: now.addingTimeInterval(-9999))
        let error = SessionSnapshot(provider: .claude, sessionId: "e", projectPath: "/p",
                                    state: .error, event: "x",
                                    updatedAt: now.addingTimeInterval(-9999))
        #expect(AutoAck.expiredDoneKeys([waiting, error], acks: [:], now: now).isEmpty)
    }

    @Test func respectsExistingAck() {
        let s = done("d", ageSeconds: 40 * 60)
        // already acked after it finished → nothing to do
        let acks = ["claude-d": s.updatedAt.addingTimeInterval(1)]
        #expect(AutoAck.expiredDoneKeys([s], acks: acks, now: now).isEmpty)
        // an ack from BEFORE this finish doesn't count
        let stale = ["claude-d": s.updatedAt.addingTimeInterval(-100)]
        #expect(AutoAck.expiredDoneKeys([s], acks: stale, now: now) == ["claude-d"])
    }
}
