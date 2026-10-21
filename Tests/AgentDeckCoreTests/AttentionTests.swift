import Foundation
import Testing
@testable import AgentDeckCore

struct AttentionTests {
    func snap(_ id: String, _ state: SessionState, updated: Date = Date()) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: id, projectPath: "/p/\(id)",
            state: state, event: "x", updatedAt: updated
        )
    }

    @Test func attentionStates() {
        #expect(Attention.needsAttention(snap("a", .waiting), ackedAt: nil))
        #expect(Attention.needsAttention(snap("a", .done), ackedAt: nil))
        #expect(Attention.needsAttention(snap("a", .error), ackedAt: nil))
        #expect(!Attention.needsAttention(snap("a", .working), ackedAt: nil))
        #expect(!Attention.needsAttention(snap("a", .ready), ackedAt: nil))
    }

    @Test func acknowledgmentSilencesUntilNewerEvent() {
        let event = Date(timeIntervalSince1970: 1000)
        let s = snap("a", .waiting, updated: event)
        #expect(!Attention.needsAttention(s, ackedAt: Date(timeIntervalSince1970: 1001)))
        #expect(Attention.needsAttention(s, ackedAt: Date(timeIntervalSince1970: 999)))
    }

    @Test func badgeCountsBlockingStatesOnly() {
        // regression: `done` used to be counted, so the badge was never zero
        // and a 13h block went unnoticed among finished sessions
        let snaps = [
            snap("a", .waiting), snap("b", .working), snap("c", .done),
            snap("d", .error), snap("e", .ready),
        ]
        #expect(Attention.alertCount(snaps, acks: [:]) == 2)
        #expect(Attention.doneCount(snaps, acks: [:]) == 1)
        #expect(
            Attention.alertCount(snaps, acks: ["claude-a": Date().addingTimeInterval(60)]) == 1
        )
    }

    @Test func doneAloneLeavesTheBadgeEmpty() {
        let snaps = [snap("c", .done), snap("d", .done)]
        #expect(Attention.alertCount(snaps, acks: [:]) == 0)
        #expect(Attention.doneCount(snaps, acks: [:]) == 2)
    }

    @Test func mostUrgentPrefersErrorThenWaitingThenDone() {
        #expect(Attention.mostUrgent([snap("a", .done), snap("b", .waiting)], acks: [:]) == .waiting)
        #expect(Attention.mostUrgent([snap("a", .waiting), snap("b", .error)], acks: [:]) == .error)
        #expect(Attention.mostUrgent([snap("a", .done)], acks: [:]) == .done)
        #expect(Attention.mostUrgent([snap("a", .working)], acks: [:]) == nil)
        // acknowledged items don't drive the glyph
        let acked = ["claude-a": Date().addingTimeInterval(60)]
        #expect(Attention.mostUrgent([snap("a", .waiting)], acks: acked) == nil)
    }

    @Test func sortOrder() {
        let now = Date()
        let snaps = [
            snap("ready", .ready, updated: now.addingTimeInterval(-60)),
            snap("working", .working, updated: now.addingTimeInterval(-30)),
            snap("ackedDone", .done, updated: now.addingTimeInterval(-10)),
            snap("err", .error, updated: now.addingTimeInterval(-500)),
            snap("waiting", .waiting, updated: now.addingTimeInterval(-900)),
            snap("done", .done, updated: now.addingTimeInterval(-700)),
        ]
        let acks = ["claude-ackedDone": now]
        let order = Attention.sorted(snaps, acks: acks).map(\.sessionId)
        // needs-you first by severity, however old; the rest newest first
        #expect(order == ["waiting", "err", "done", "ackedDone", "working", "ready"])
    }

    @Test func aRecentlyFinishedSessionIsNotBuriedUnderOldIdleOnes() {
        // done an hour ago, auto-acknowledged after 30 minutes; the other
        // has been idle for two months
        let now = Date()
        let finished = snap("finished", .done, updated: now.addingTimeInterval(-3600))
        let idle = snap("idle", .ready, updated: now.addingTimeInterval(-60 * 86400))
        let order = Attention.sorted([idle, finished], acks: ["claude-finished": now - 1800])
            .map(\.sessionId)
        #expect(order == ["finished", "idle"])
    }

    @Test func sortTieBreaksOnRecency() {
        let now = Date()
        let older = snap("older", .working, updated: now.addingTimeInterval(-100))
        let newer = snap("newer", .working, updated: now)
        let order = Attention.sorted([older, newer], acks: [:]).map(\.sessionId)
        #expect(order == ["newer", "older"])
    }
}
