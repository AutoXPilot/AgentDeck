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

    @Test func firesOnceWhenThresholdCrossed() {
        var tracker = WaitingTracker()
        let fresh = [waiting("a", ageSeconds: 60)]
        #expect(tracker.update(fresh, now: now, threshold: 300).isEmpty)

        let later = now.addingTimeInterval(600)
        #expect(tracker.update(fresh, now: later, threshold: 300) == ["claude-a"])
        // already announced — no repeat
        #expect(tracker.update(fresh, now: later.addingTimeInterval(600), threshold: 300).isEmpty)
    }

    @Test func alreadyLongWaitingSessionFiresImmediately() {
        // a session blocked before the app launched must not restart its clock
        var tracker = WaitingTracker()
        let old = [waiting("a", ageSeconds: 13 * 3600)]
        #expect(tracker.update(old, now: now, threshold: 300) == ["claude-a"])
    }

    @Test func leavingWaitingResetsTheEpisode() {
        var tracker = WaitingTracker()
        let blocked = [waiting("a", ageSeconds: 3600)]
        #expect(tracker.update(blocked, now: now, threshold: 300) == ["claude-a"])

        let unblocked = [SessionSnapshot(
            provider: .claude, sessionId: "a", projectPath: "/p",
            state: .working, event: "x", updatedAt: now
        )]
        #expect(tracker.update(unblocked, now: now, threshold: 300).isEmpty)
        #expect(tracker.waitingDuration(forKey: "claude-a") == nil)

        // blocked again → notifies again
        #expect(tracker.update(blocked, now: now, threshold: 300) == ["claude-a"])
    }

    @Test func nonWaitingStatesNeverFire() {
        var tracker = WaitingTracker()
        let snaps = [SessionState.ready, .working, .done, .error].map {
            SessionSnapshot(
                provider: .claude, sessionId: "\($0.rawValue)", projectPath: "/p",
                state: $0, event: "x", updatedAt: now.addingTimeInterval(-9999)
            )
        }
        #expect(tracker.update(snaps, now: now, threshold: 1).isEmpty)
    }

    @Test func reportsHowLongSomethingHasBeenWaiting() {
        var tracker = WaitingTracker()
        _ = tracker.update([waiting("a", ageSeconds: 120)], now: now, threshold: 300)
        let duration = tracker.waitingDuration(forKey: "claude-a", now: now)
        #expect(duration.map { abs($0 - 120) < 1 } == true)
    }
}
