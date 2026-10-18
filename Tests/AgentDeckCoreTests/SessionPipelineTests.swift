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

    @Test func liveSessionsWithNoSnapshotBecomeRows() {
        // The 15-rows-for-36-live-sessions bug: the pipeline only ever saw
        // the registry through snapshot.agentPid, so a session the hooks
        // never reported had no row at all — including one blocked on the
        // user since August.
        let snapshots = [snap("known", .working, pid: 1)]
        let live = [
            "known": entry(pid: 1, id: "known", "busy"),
            "unseen-idle": entry(pid: 9, id: "unseen-idle", "idle"),
            "unseen-block": entry(pid: 10, id: "unseen-block", "waiting",
                                  waitingFor: "permission prompt"),
        ]
        let out = SessionPipeline.run(
            snapshots: snapshots, registry: [1: live["known"]!],
            liveSessions: live, acks: [:], frozenOrder: nil,
            popoverVisible: false, now: now
        )
        #expect(Set(out.rows.map(\.sessionId))
                == ["known", "unseen-idle", "unseen-block"])
        // a session with a snapshot must not be duplicated by discovery
        #expect(out.rows.filter { $0.sessionId == "known" }.count == 1)
        // discovery can report a block the hooks never saw
        let blocked = try? #require(out.rows.first { $0.sessionId == "unseen-block" })
        #expect(blocked?.state == .waiting)
        #expect(out.waitingReasons["claude-unseen-block"] != nil)
        #expect(out.alertCount == 1)
    }

    @Test func discoveredRowsCarryTheirDirectoryAndNotTheClock() {
        let observed = now.addingTimeInterval(-9_000)
        var e = entry(pid: 7, id: "s", "idle")
        e.cwd = "/Users/t/Code/version2"
        e.statusUpdatedAt = observed
        let out = SessionPipeline.run(
            snapshots: [], registry: [:], liveSessions: ["s": e],
            acks: [:], frozenOrder: nil, popoverVisible: false, now: now
        )
        let row = try? #require(out.rows.first)
        #expect(row?.projectPath == "/Users/t/Code/version2",
                "cwd is what makes a discovered row resumable")
        // using `now` here would re-arm acks on every single reload
        #expect(row?.updatedAt == observed)
        #expect(row?.agentPid == 7)
    }

    @Test func aSnapshotAlwaysBeatsDiscovery() {
        // the snapshot carries the pane id and hook-derived state; the
        // registry entry knows neither
        let withPane = SessionSnapshot(
            provider: .claude, sessionId: "s", projectPath: "/real",
            state: .done, event: "Stop", updatedAt: now,
            terminalSessionId: "w0t0p0:GUID", agentPid: 5
        )
        var e = entry(pid: 5, id: "s", "idle")
        e.cwd = "/from-registry"
        let out = SessionPipeline.run(
            snapshots: [withPane], registry: [:], liveSessions: ["s": e],
            acks: [:], frozenOrder: nil, popoverVisible: false, now: now
        )
        #expect(out.rows.count == 1)
        #expect(out.rows[0].state == .done, "discovery must not fake away a completion")
        #expect(out.rows[0].terminalSessionId == "w0t0p0:GUID")
        #expect(out.rows[0].projectPath == "/real")
    }

    @Test func discoveryNeverInventsDoneOrError() {
        // `.done`/`.error` are hook-only facts; a status of idle is not a
        // finished turn
        for status in ["idle", "busy", "shell", "waiting", "something-new"] {
            let e = entry(pid: 3, id: "s", status)
            let out = SessionPipeline.run(
                snapshots: [], registry: [:], liveSessions: ["s": e],
                acks: [:], frozenOrder: nil, popoverVisible: false, now: now
            )
            let state = out.rows.first?.state
            #expect(state != .done && state != .error, "status \(status) produced \(state!)")
        }
    }

    @Test func aBlockIsFoundEvenWhenTheSnapshotHasNoPid() {
        // Reconciliation used to look the registry up only through
        // snapshot.agentPid. A snapshot whose ancestor walk failed has no
        // pid at all — which is routine, since a pruned claude binary
        // breaks the walk — so the registry was never consulted and a
        // session it *knew* was blocked raised no alert.
        let noPid = snap("s", .working, pid: nil, ageSeconds: 600)
        var live = entry(pid: 77, id: "s", "waiting", waitingFor: "permission prompt")
        live.statusUpdatedAt = now.addingTimeInterval(-60)   // newer than the snapshot
        let out = SessionPipeline.run(
            snapshots: [noPid], registry: [:], liveSessions: ["s": live],
            acks: [:], frozenOrder: nil, popoverVisible: false, now: now
        )
        #expect(out.rows.count == 1)
        #expect(out.rows[0].state == .waiting)
        #expect(out.alertCount == 1)
        #expect(out.waitingReasons["claude-s"] != nil)
    }

    @Test func aReusedPidCannotHideTheRightRegistryEntry() {
        // the snapshot still carries pid 5, which now belongs to another
        // session; this session lives on as pid 9 and is blocked
        let stale = snap("mine", .working, pid: 5, ageSeconds: 600)
        let other = entry(pid: 5, id: "someone-else", "idle")
        let mine = entry(pid: 9, id: "mine", "waiting", waitingFor: "permission prompt", ageSeconds: 30)
        let out = SessionPipeline.run(
            snapshots: [stale], registry: [5: other, 9: mine],
            liveSessions: ["mine": mine, "someone-else": other],
            acks: [:], frozenOrder: nil, popoverVisible: false, now: now)
        #expect(out.rows.first { $0.sessionId == "mine" }?.state == .waiting)
        #expect(out.waitingReasons["claude-mine"] != nil)
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
            snapshots: [snap("dup", .waiting, notif: "permission_prompt"),
                        snap("dup", .waiting, notif: "permission_prompt")],
            registry: [:], acks: [:],
            frozenOrder: nil, popoverVisible: false, now: now
        )
        #expect(out.rows.count == 1)
        // deduped before counting: one blocked session is one in the badge
        #expect(out.alertCount == 1)
    }
}
