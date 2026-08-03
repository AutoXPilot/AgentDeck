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
}
