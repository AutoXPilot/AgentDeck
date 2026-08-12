import Foundation
import Testing
@testable import AgentDeckCore

/// End-to-end tests for the derivation that used to live as untested glue
/// in the app target — where a mis-ordering shipped to production.
struct SessionPipelineTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)

    func snap(
        _ id: String, _ state: SessionState, pid: Int32? = nil,
        notif: String? = nil, ageSeconds: TimeInterval = 60
    ) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: id, projectPath: "/p/\(id)",
            state: state, event: "x",
            updatedAt: now.addingTimeInterval(-ageSeconds),
            agentPid: pid, notificationType: notif
        )
    }

    func entry(
        pid: Int32, id: String, _ status: String,
        waitingFor: String? = nil, ageSeconds: TimeInterval = 0
    ) -> ClaudeSessionRegistry.Entry {
        ClaudeSessionRegistry.Entry(
            pid: pid, sessionId: id, status: status, waitingFor: waitingFor,
            statusUpdatedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    @Test func fullDerivationOrdering() {
        // one of everything: an idle fake-wait, a registry-cleared wait,
        // a registry-detected block, a genuine hook wait, a worker
        let snapshots = [
            snap("idle", .waiting, notif: "idle_prompt", ageSeconds: 7200),
            snap("cleared", .waiting, pid: 1, notif: "permission_prompt",
                 ageSeconds: 7200),
            snap("hidden-block", .working, pid: 2, ageSeconds: 1200),
            snap("real-wait", .waiting, pid: 3, notif: "permission_prompt",
                 ageSeconds: 300),
            snap("worker", .working, pid: 4, ageSeconds: 30),
        ]
        let registry: [Int32: ClaudeSessionRegistry.Entry] = [
            1: entry(pid: 1, id: "cleared", "idle", ageSeconds: 600),
            2: entry(pid: 2, id: "hidden-block", "waiting",
                     waitingFor: "permission prompt", ageSeconds: 120),
            3: entry(pid: 3, id: "real-wait", "waiting",
                     waitingFor: "permission prompt", ageSeconds: 200),
            4: entry(pid: 4, id: "worker", "busy", ageSeconds: 10),
        ]
        let out = SessionPipeline.run(
            snapshots: snapshots, registry: registry, acks: [:],
            frozenOrder: nil, popoverVisible: false, now: now
        )
        let states = Dictionary(
            uniqueKeysWithValues: out.rows.map { ($0.sessionId, $0.state) }
        )
        #expect(states["idle"] == .ready, "idle nudge is not a block")
        #expect(states["cleared"] == .ready, "registry saw the answer")
        #expect(states["hidden-block"] == .waiting, "registry-only block surfaces")
        #expect(states["real-wait"] == .waiting)
        #expect(states["worker"] == .working)
        #expect(out.alertCount == 2)
        #expect(out.mostUrgent == .waiting)
        #expect(out.waitingReasons["claude-hidden-block"] == "needs permission",
                "reasons arrive humanized")
        // blocked rows sort first
        #expect(Set(out.rows.prefix(2).map(\.sessionId)) == ["hidden-block", "real-wait"])
    }

    @Test func ackedSessionRegainsAttentionWhenRegistryFindsANewBlock() {
        // The escaped bug: correction carried a stale timestamp, so the ack
        // permanently outdated it and the badge stayed at zero.
        let ackedAt = now.addingTimeInterval(-1800)
        let done = snap("s", .done, pid: 9, ageSeconds: 3600)
        let blocked = entry(pid: 9, id: "s", "waiting",
                            waitingFor: "permission prompt", ageSeconds: 60)
        let out = SessionPipeline.run(
            snapshots: [done], registry: [9: blocked],
            acks: ["claude-s": ackedAt],
            frozenOrder: nil, popoverVisible: false, now: now
        )
        #expect(out.alertCount == 1, "new block must beat the old ack")
        #expect(out.rows[0].state == .waiting)
        #expect(out.rows[0].updatedAt > ackedAt)
    }

    @Test func frozenOrderRespectedWhilePopoverVisible() {
        let a = snap("a", .ready, ageSeconds: 10)
        let b = snap("b", .waiting, notif: "permission_prompt", ageSeconds: 10)
        let out = SessionPipeline.run(
            snapshots: [a, b], registry: [:], acks: [:],
            frozenOrder: ["claude-a", "claude-b"],  // a first, despite b blocking
            popoverVisible: true, now: now
        )
        #expect(out.rows.map(\.sessionId) == ["a", "b"])
        #expect(out.frozenOrder == ["claude-a", "claude-b"])
        // counts ignore the freeze
        #expect(out.alertCount == 1)
    }

    @Test func duplicateFilesCannotProduceDuplicateRows() {
        let out = SessionPipeline.run(
            snapshots: [snap("dup", .ready), snap("dup", .done)],
            registry: [:], acks: [:],
            frozenOrder: nil, popoverVisible: false, now: now
        )
        #expect(out.rows.count == 1)
    }
}
