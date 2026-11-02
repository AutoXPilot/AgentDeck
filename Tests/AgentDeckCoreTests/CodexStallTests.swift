import Foundation
import Testing
@testable import AgentDeckCore

/// Record shapes from a codex-cli 0.165 / daemon 0.166 rollout (keys only;
/// values synthetic). The real case: a browser `js` call waiting on an MCP
/// elicitation, followed only by a token usage record.
private func line(_ ts: String, _ type: String, _ payload: String) -> String {
    #"{"timestamp":"\#(ts)","type":"\#(type)","payload":\#(payload)}"#
}
private func call(_ ts: String, id: String, name: String = "js") -> String {
    line(ts, "response_item", #"{"type":"function_call","name":"\#(name)","call_id":"\#(id)","arguments":"SECRET-ARGS"}"#)
}
private func output(_ ts: String, id: String) -> String {
    line(ts, "response_item", #"{"type":"function_call_output","call_id":"\#(id)","output":"x"}"#)
}
private func usage(_ ts: String) -> String {
    #"{"timestamp":"\#(ts)","type":"token_usage_record","payload":null}"#
}
private func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
private let t0 = SnapshotStore.isoFractional.date(from: "2026-11-02T11:56:24.856Z")!

struct CodexStallTests {
    @Test func aToolCallWithNoOutputForTwoMinutesIsAStall() {
        let tail = data([output("2026-11-02T11:56:20.000Z", id: "a"),
                         call("2026-11-02T11:56:24.856Z", id: "b"),
                         usage("2026-11-02T11:56:24.935Z")])
        #expect(CodexStall.stalledSince(in: tail, isWholeFile: true, now: t0.addingTimeInterval(121)) == t0)
        #expect(CodexStall.stalledSince(in: tail, isWholeFile: true, now: t0.addingTimeInterval(60)) == nil)
    }

    @Test func anAnsweredCallIsNotAStall() {
        let tail = data([call("2026-11-02T11:56:24.856Z", id: "b"), output("2026-11-02T11:56:30.000Z", id: "b")])
        #expect(CodexStall.stalledSince(in: tail, isWholeFile: true, now: t0.addingTimeInterval(600)) == nil)
    }

    @Test func activityAfterTheCallIsNotAStall() {
        // the session kept writing (another item well after the call)
        let tail = data([call("2026-11-02T11:56:24.856Z", id: "b"),
                         line("2026-11-02T11:57:30.000Z", "event_msg", #"{"type":"token_count"}"#)])
        #expect(CodexStall.stalledSince(in: tail, isWholeFile: true, now: t0.addingTimeInterval(600)) == nil)
    }

    @Test func aLongShellCommandIsNotAStall() {
        let tail = data([call("2026-11-02T11:56:24.856Z", id: "b", name: "exec")])
        #expect(CodexStall.stalledSince(in: tail, isWholeFile: true, now: t0.addingTimeInterval(600)) == nil)
    }

    @Test func aFinishedTurnIsNotAStall() {
        let tail = data([call("2026-11-02T11:56:24.856Z", id: "b"),
                         line("2026-11-02T11:56:25.000Z", "event_msg", #"{"type":"task_complete"}"#)])
        #expect(CodexStall.stalledSince(in: tail, isWholeFile: true, now: t0.addingTimeInterval(600)) == nil)
    }

    @Test func findsRolloutsByTheThreadIdAtTheEndOfTheName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-stall-\(UUID().uuidString)/2026/11/01", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "01a19a81-2544-7700-a234-09859685e7db"
        let file = dir.appendingPathComponent("rollout-2026-11-01T23-25-17-\(id).jsonl")
        try Data().write(to: file)
        let root = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(CodexStall.rollouts(for: [id], in: root)[id]?.lastPathComponent == file.lastPathComponent)
        #expect(CodexStall.rollouts(for: ["01a19a81"], in: root).isEmpty)
    }
}

struct InferredWaitingPipelineTests {
    private func codex(_ state: SessionState, updated: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(provider: .codex, sessionId: "01a19a81-2544-7700-a234-09859685e7db",
                        projectPath: "/Users/me", state: state, event: "UserPromptSubmit",
                        updatedAt: Date(timeIntervalSince1970: updated))
    }

    @Test func aStalledWorkingRowWaitsAndCountsAsAnAlert() {
        let row = codex(.working, updated: 100)
        let out = SessionPipeline.run(snapshots: [row], registry: [:],
                                      inferredWaiting: [row.key: Date(timeIntervalSince1970: 500)],
                                      acks: [:], frozenOrder: nil, popoverVisible: false)
        #expect(out.rows.first?.state == .waiting)
        #expect(out.alertCount == 1)
        #expect(out.waitingReasons[row.key] == SessionPipeline.inferredWaitingReason)
    }

    @Test func anAcknowledgementAfterTheStallHoldsUntilANewOne() {
        let row = codex(.working, updated: 100)
        let ack = [row.key: Date(timeIntervalSince1970: 600)]
        let held = SessionPipeline.run(snapshots: [row], registry: [:],
                                       inferredWaiting: [row.key: Date(timeIntervalSince1970: 500)],
                                       acks: ack, frozenOrder: nil, popoverVisible: false)
        #expect(held.alertCount == 0)
        let fresh = SessionPipeline.run(snapshots: [row], registry: [:],
                                        inferredWaiting: [row.key: Date(timeIntervalSince1970: 900)],
                                        acks: ack, frozenOrder: nil, popoverVisible: false)
        #expect(fresh.alertCount == 1)
    }

    @Test func hookStatesOtherThanWorkingAreLeftAlone() {
        let row = codex(.done, updated: 100)
        let out = SessionPipeline.run(snapshots: [row], registry: [:],
                                      inferredWaiting: [row.key: Date(timeIntervalSince1970: 500)],
                                      acks: [:], frozenOrder: nil, popoverVisible: false)
        #expect(out.rows.first?.state == .done)
    }
}
