import Foundation
import Testing
@testable import AgentDeckCore

struct ClaudeSessionRegistryTests {
    /// Shape recorded from a real ~/.claude/sessions/<pid>.json (claude 2.1.220).
    let realFile = """
    {"pid":89540,"sessionId":"9c64a083-c8d8-4c00-9008-6d0ea533783d",
     "cwd":"/Users/x/Code/version2","startedAt":1785417531289,
     "version":"2.1.220","kind":"interactive","entrypoint":"cli",
     "name":"V2B-1516","status":"busy","updatedAt":1785509271809,
     "statusUpdatedAt":1785509271809}
    """

    @Test func parsesRealFile() throws {
        let entry = try #require(ClaudeSessionRegistry.parse(Data(realFile.utf8)))
        #expect(entry.pid == 89540)
        #expect(entry.status == "busy")
        #expect(entry.name == "V2B-1516")
        #expect(entry.kind == "interactive")
        #expect(entry.isUserNamed)
        #expect(entry.statusUpdatedAt?.timeIntervalSince1970 == 1785509271.809)
        // cwd + startedAt are what makes this file a resume handle, not
        // just a status report
        #expect(entry.cwd == "/Users/x/Code/version2")
        #expect(entry.startedAt?.timeIntervalSince1970 == 1785417531.289)
    }

    @Test func liveSessionsFiltersDeadAndRecycledPids() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let started = Date(timeIntervalSince1970: 1_000_000)
        func write(_ name: String, pid: Int32, session: String, startedAt: Date) throws {
            let ms = startedAt.timeIntervalSince1970 * 1000
            try Data("""
            {"pid":\(pid),"sessionId":"\(session)","status":"idle",
             "cwd":"/tmp/\(session)","startedAt":\(ms)}
            """.utf8).write(to: dir.appendingPathComponent(name))
        }
        try write("1.json", pid: 101, session: "alive", startedAt: started)
        try write("2.json", pid: 102, session: "dead", startedAt: started)
        try write("3.json", pid: 103, session: "recycled", startedAt: started)

        let probe = Liveness.ProcessProbe { pid in
            switch pid {
            case 101: return started                                  // same process
            case 103: return started.addingTimeInterval(10_000)        // reused pid
            default: return nil                                        // exited
            }
        }
        let live = ClaudeSessionRegistry.liveSessions(from: dir, probe: probe)
        #expect(Set(live.keys) == ["alive"])
        #expect(live["alive"]?.cwd == "/tmp/alive",
                "the inventory must carry cwd — resume needs it")
        // registry files outlive their process; an unfiltered load would
        // show both of these forever
        #expect(ClaudeSessionRegistry.load(from: dir).count == 3)
    }

    @Test func liveSessionsPrefersTheNewerFileForADuplicateSessionId() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        try Data("""
        {"pid":201,"sessionId":"dup","status":"idle","cwd":"/old",
         "startedAt":\(old.timeIntervalSince1970 * 1000)}
        """.utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data("""
        {"pid":202,"sessionId":"dup","status":"busy","cwd":"/new",
         "startedAt":\(new.timeIntervalSince1970 * 1000)}
        """.utf8).write(to: dir.appendingPathComponent("b.json"))

        let probe = Liveness.ProcessProbe { pid in pid == 201 ? old : new }
        let live = ClaudeSessionRegistry.liveSessions(from: dir, probe: probe)
        #expect(live.count == 1)
        #expect(live["dup"]?.cwd == "/new")
    }

    @Test func parsesWaitingWithReason() throws {
        let json = """
        {"pid":40159,"sessionId":"s1","status":"waiting",
         "waitingFor":"permission prompt","name":"AgentDeck",
         "statusUpdatedAt":1785509000000}
        """
        let entry = try #require(ClaudeSessionRegistry.parse(Data(json.utf8)))
        #expect(entry.status == "waiting")
        #expect(entry.waitingFor == "permission prompt")
    }

    @Test func derivedNamesAreNotUserNamed() throws {
        let json = """
        {"pid":1,"sessionId":"s","status":"idle","name":"knowledge-e5",
         "nameSource":"derived"}
        """
        let entry = try #require(ClaudeSessionRegistry.parse(Data(json.utf8)))
        #expect(!entry.isUserNamed)
    }

    @Test func rejectsMalformedOrIncomplete() {
        #expect(ClaudeSessionRegistry.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(Data("{\"pid\":1}".utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(
            Data("{\"pid\":1,\"sessionId\":\"\",\"status\":\"idle\"}".utf8)) == nil)
    }

    @Test func loadFromMissingDirectoryIsEmpty() {
        #expect(ClaudeSessionRegistry.load(
            from: URL(fileURLWithPath: "/nonexistent/sessions")).isEmpty)
    }
}

struct StateReconcilerTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)

    func snapshot(_ state: SessionState, ageSeconds: TimeInterval = 60) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: "s1", projectPath: "/p",
            state: state, event: "x", updatedAt: now.addingTimeInterval(-ageSeconds),
            agentPid: 100
        )
    }

    func entry(_ status: String, waitingFor: String? = nil, ageSeconds: TimeInterval = 0)
        -> ClaudeSessionRegistry.Entry
    {
        ClaudeSessionRegistry.Entry(
            pid: 100, sessionId: "s1", status: status, waitingFor: waitingFor,
            statusUpdatedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    @Test func clearsStaleWaitingWhenRegistrySawTheAnswer() {
        // the exact production bug: 3 rows stuck at `waiting` for 13h
        let result = StateReconciler.reconcile(
            snapshot: snapshot(.waiting, ageSeconds: 13 * 3600), entry: entry("idle")
        )
        #expect(result.state == .ready)
        #expect(result.correctedByRegistry)
    }

    @Test func busyRegistryClearsWaitingAsWorking() {
        let result = StateReconciler.reconcile(
            snapshot: snapshot(.waiting, ageSeconds: 600), entry: entry("busy")
        )
        #expect(result.state == .working)
    }

    @Test func detectsBlockNoHookReported() {
        // the inverse bug: registry knows about a permission prompt we missed
        let result = StateReconciler.reconcile(
            snapshot: snapshot(.working, ageSeconds: 600),
            entry: entry("waiting", waitingFor: "permission prompt")
        )
        #expect(result.state == .waiting)
        #expect(result.waitingFor == "permission prompt")
        #expect(result.correctedByRegistry)
    }

    @Test func staleRegistryDoesNotOverrideNewerHook() {
        // the registry lags too — a hook observed more recently wins
        let result = StateReconciler.reconcile(
            snapshot: snapshot(.working, ageSeconds: 10),
            entry: entry("waiting", ageSeconds: 3600)
        )
        #expect(result.state == .working)
        #expect(!result.correctedByRegistry)
    }

    @Test func enrichesAgreedWaitWithReason() {
        let result = StateReconciler.reconcile(
            snapshot: snapshot(.waiting, ageSeconds: 10),
            entry: entry("waiting", waitingFor: "input needed", ageSeconds: 3600)
        )
        #expect(result.state == .waiting)
        #expect(result.waitingFor == "input needed")
    }

    @Test func ignoresEntryForADifferentSession() {
        // guards pid reuse: same pid, different session id
        var other = entry("idle")
        other.sessionId = "someone-else"
        let result = StateReconciler.reconcile(
            snapshot: snapshot(.waiting, ageSeconds: 13 * 3600), entry: other
        )
        #expect(result.state == .waiting)
        #expect(!result.correctedByRegistry)
    }

    @Test func noEntryLeavesStateAlone() {
        let result = StateReconciler.reconcile(snapshot: snapshot(.done), entry: nil)
        #expect(result.state == .done)
    }

    // MARK: - normalize(): ordering of the two corrections

    func idleWait(pid: Int32? = 100) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: "s1", projectPath: "/p",
            state: .waiting, event: "Notification",
            updatedAt: now.addingTimeInterval(-3600), agentPid: pid,
            notificationType: "idle_prompt"
        )
    }

    @Test func registryMustNotResurrectAnIdleWait() {
        // Regression: the repair ran first, then the registry was handed the
        // ORIGINAL snapshot and its `waiting` overwrote the repair — two idle
        // sessions kept showing as blocked and inflated the badge.
        let outcome = StateReconciler.normalize(
            snapshot: idleWait(), entry: entry("idle", ageSeconds: 7200)
        )
        #expect(outcome.snapshot.state == .ready)
        #expect(outcome.waitingFor == nil)
    }

    @Test func idleRepairAppliesWithoutARegistryEntry() {
        let outcome = StateReconciler.normalize(snapshot: idleWait(pid: nil), entry: nil)
        #expect(outcome.snapshot.state == .ready)
    }

    @Test func genuineBlockSurvivesNormalization() {
        var blocked = idleWait()
        blocked.notificationType = "permission_prompt"
        let outcome = StateReconciler.normalize(
            snapshot: blocked, entry: entry("waiting", waitingFor: "permission prompt")
        )
        #expect(outcome.snapshot.state == .waiting)
        #expect(outcome.waitingFor == "permission prompt")
    }

    @Test func registryCorrectionCarriesItsOwnTimestamp() {
        // A block detected by the registry AFTER the user acknowledged the
        // session must out-date the ack, or it can never earn attention.
        let ackTime = now.addingTimeInterval(-1800)
        let blockTime = now.addingTimeInterval(-120)
        var done = snapshot(.done, ageSeconds: 3600)  // hook event long ago
        done.notificationType = nil
        let blocked = ClaudeSessionRegistry.Entry(
            pid: 100, sessionId: "s1", status: "waiting",
            waitingFor: "permission prompt", statusUpdatedAt: blockTime
        )
        let outcome = StateReconciler.normalize(snapshot: done, entry: blocked)
        #expect(outcome.snapshot.state == .waiting)
        #expect(outcome.snapshot.updatedAt == blockTime,
                "corrected state must carry the observation time")
        #expect(Attention.needsAttention(outcome.snapshot, ackedAt: ackTime),
                "the new block must beat the old ack")
        // and WaitingTracker seeds from the real block time, not hook time
        var tracker = WaitingTracker()
        let due = tracker.candidates([outcome.snapshot], now: now, threshold: 300)
        #expect(due.isEmpty, "a 2-minute-old block must not escalate at a 5m threshold")
    }

    @Test func fileModifiedTimeIsUsedWhenStatusUpdatedAtIsMissing() {
        // Regression: a build that omits statusUpdatedAt made reconciliation
        // a silent no-op (registryIsNewer could never be true), so the
        // 13h-stale-waiting bug returned. observedAt falls back to file mtime.
        let blockObserved = now.addingTimeInterval(-120)
        var done = snapshot(.done, ageSeconds: 3600)
        done.notificationType = nil
        let noStamp = ClaudeSessionRegistry.Entry(
            pid: 100, sessionId: "s1", status: "waiting",
            waitingFor: "permission prompt",
            statusUpdatedAt: nil, fileModifiedAt: blockObserved
        )
        let outcome = StateReconciler.normalize(snapshot: done, entry: noStamp)
        #expect(outcome.snapshot.state == .waiting, "mtime fallback drives the correction")
        #expect(outcome.snapshot.updatedAt == blockObserved)
    }

    @Test func unchangedEntryDoesNotRearmAnAcknowledgedRow() {
        // The re-arm hazard astra caught: if the correction stamped `now`
        // every reload, an unchanged registry entry would forever out-date
        // any ack. mtime is stable until the file is rewritten, so a second
        // reload with the SAME entry produces the SAME timestamp.
        let mtime = now.addingTimeInterval(-120)
        var done = snapshot(.done, ageSeconds: 3600)
        done.notificationType = nil
        let entry = ClaudeSessionRegistry.Entry(
            pid: 100, sessionId: "s1", status: "waiting",
            statusUpdatedAt: nil, fileModifiedAt: mtime
        )
        let first = StateReconciler.normalize(snapshot: done, entry: entry).snapshot
        // user acks the corrected block
        let ack = first.updatedAt.addingTimeInterval(1)
        #expect(!Attention.needsAttention(first, ackedAt: ack))
        // next reload: feed the corrected snapshot back through the SAME entry
        let second = StateReconciler.normalize(snapshot: first, entry: entry).snapshot
        #expect(second.updatedAt == first.updatedAt, "no re-arm from an unchanged entry")
        #expect(!Attention.needsAttention(second, ackedAt: ack))
    }

    @Test func agreementWithAnOlderRegistryKeepsTheHookTime() {
        let snap = snapshot(.waiting, ageSeconds: 60)
        let agreeing = entry("waiting", waitingFor: "input needed", ageSeconds: 600)
        let outcome = StateReconciler.normalize(snapshot: snap, entry: agreeing)
        #expect(outcome.snapshot.updatedAt == snap.updatedAt,
                "nothing newer was observed; the hook time stands")
    }

    @Test func aNewerRegistryWaitIsANewWaitEvenWhenBothSayWaiting() {
        // hook wait at -600s, acknowledged at -300s; the session was
        // answered and blocked again at -60s with no hook in between. Both
        // sources say waiting, but this is a second wait, and the
        // acknowledgement of the first must not cover it.
        let snap = snapshot(.waiting, ageSeconds: 600)
        let again = entry("waiting", waitingFor: "permission prompt", ageSeconds: 60)
        let outcome = StateReconciler.normalize(snapshot: snap, entry: again)
        let ackedAt = snap.updatedAt.addingTimeInterval(300)
        #expect(outcome.snapshot.updatedAt > ackedAt)
        #expect(Attention.needsAttention(outcome.snapshot, ackedAt: ackedAt))
    }

    @Test func codexKeepsItsOwnReasonWithoutARegistry() {
        var codex = idleWait(pid: nil)
        codex.provider = .codex
        codex.notificationType = "permission_prompt"
        let outcome = StateReconciler.normalize(snapshot: codex, entry: nil)
        #expect(outcome.snapshot.state == .waiting)
        #expect(outcome.waitingFor == "permission prompt")
    }
}
