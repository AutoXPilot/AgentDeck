import Foundation
import Testing
@testable import AgentDeckCore

/// Fixture tests for the stdin→snapshot path, using payload shapes recorded
/// from real claude 2.1.220 and codex-cli 0.145.0 hook invocations.
final class HookProcessorTests {
    let dir: URL
    let store: SnapshotStore

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-hookproc-\(UUID().uuidString)")
        store = SnapshotStore(directory: dir)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func payload(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    func process(
        _ provider: Provider, _ dict: [String: Any],
        env: [String: String] = [:], parentPid: pid_t? = nil
    ) -> HookAction {
        HookProcessor.process(
            provider: provider, payloadData: payload(dict),
            environment: env, parentPid: parentPid, store: store
        )
    }

    @Test func claudeUserPromptSubmitCreatesWorkingSnapshot() {
        // shape recorded from a live claude 2.1.220 UserPromptSubmit hook
        let action = process(.claude, [
            "session_id": "d047f956-a5ed-4248-8938-92685f0da7f7",
            "transcript_path": "/Users/x/.claude/projects/tmp/session.jsonl",
            "cwd": "/private/tmp",
            "permission_mode": "default",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "say ok",
        ], env: ["ITERM_SESSION_ID": "w0t4p0:B4F41D67-F1B2-4A6C-A21F-4431B718477E"])
        #expect(action == .set(.working))
        let snap = store.load(key: "claude-d047f956-a5ed-4248-8938-92685f0da7f7")
        #expect(snap?.state == .working)
        #expect(snap?.projectPath == "/private/tmp")
        #expect(snap?.terminalSessionId == "w0t4p0:B4F41D67-F1B2-4A6C-A21F-4431B718477E")
        // the prompt text must never be persisted
        let raw = String(
            decoding: try! Data(contentsOf: store.url(forKey: snap!.key)), as: UTF8.self
        )
        #expect(!raw.contains("say ok"))
    }

    @Test func missingOrEmptySessionIdIgnored() {
        #expect(process(.claude, ["hook_event_name": "Stop"]) == .ignore)
        #expect(process(.claude, ["hook_event_name": "Stop", "session_id": ""]) == .ignore)
        #expect(store.loadAll().isEmpty)
    }

    @Test func malformedPayloadIgnored() {
        let action = HookProcessor.process(
            provider: .claude, payloadData: Data("{not json".utf8),
            environment: [:], parentPid: nil, store: store
        )
        #expect(action == .ignore)
        #expect(HookProcessor.process(
            provider: .claude, payloadData: Data(),
            environment: [:], parentPid: nil, store: store
        ) == .ignore)
    }

    @Test func traversalSessionIdCannotEscapeDirectory() throws {
        let evil = "../../../../.claude/settings"
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": evil, "cwd": "/tmp",
        ])
        // whatever was written must be inside the sessions dir
        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(written.count == 1)
        #expect(!written[0].contains(".."))
        // and removal with the same evil id must not leave the dir either
        _ = process(.claude, ["hook_event_name": "SessionEnd", "session_id": evil])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func sessionEndRemovesSnapshot() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/p",
        ])
        #expect(store.load(key: "claude-s1") != nil)
        #expect(process(.claude, [
            "hook_event_name": "SessionEnd", "session_id": "s1", "reason": "other",
        ]) == .remove)
        #expect(store.load(key: "claude-s1") == nil)
    }

    @Test func stopOnlyUpdatesNeverCreates() {
        // Stop for an unknown session (e.g. racing a SessionEnd removal)
        // must not resurrect a snapshot
        #expect(process(.claude, [
            "hook_event_name": "Stop", "session_id": "gone", "cwd": "/p",
        ]) == .ignore)
        #expect(store.load(key: "claude-gone") == nil)

        // but a live session's Stop updates state
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "s2", "cwd": "/p",
        ])
        _ = process(.claude, ["hook_event_name": "Stop", "session_id": "s2"])
        #expect(store.load(key: "claude-s2")?.state == .done)
    }

    @Test func mergePreservesTerminalAndCwdAcrossEvents() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "s3", "cwd": "/proj",
        ], env: ["ITERM_SESSION_ID": "w0t0p0:GUID-1"])
        // later event arrives without env/cwd (e.g. Notification)
        _ = process(.claude, [
            "hook_event_name": "Notification", "session_id": "s3",
            "notification_type": "permission_prompt",
        ])
        let snap = store.load(key: "claude-s3")
        #expect(snap?.state == .waiting)
        #expect(snap?.terminalSessionId == "w0t0p0:GUID-1")
        #expect(snap?.projectPath == "/proj")
    }

    @Test func notificationTypeInTypeFieldAlsoWorks() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "s4", "cwd": "/p",
        ])
        _ = process(.claude, [
            "hook_event_name": "Notification", "session_id": "s4",
            "type": "agent_needs_input",
        ])
        #expect(store.load(key: "claude-s4")?.state == .waiting)
    }

    @Test func capturesSessionMetadataFromPayload() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "meta", "cwd": "/p",
            "permission_mode": "bypassPermissions", "model": "claude-fable-5",
            "effort": ["level": "high"],
        ])
        let snap = store.load(key: "claude-meta")
        #expect(snap?.permissionMode == "bypassPermissions")
        #expect(snap?.isUnsupervised == true)
        #expect(snap?.model == "claude-fable-5")
        #expect(snap?.effort == "high")
        #expect(snap?.schemaVersion == 2)
    }

    @Test func metadataSurvivesLaterEventsThatOmitIt() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "m2", "cwd": "/p",
            "permission_mode": "plan", "model": "claude-opus-5",
        ])
        _ = process(.claude, ["hook_event_name": "Stop", "session_id": "m2"])
        let snap = store.load(key: "claude-m2")
        #expect(snap?.permissionMode == "plan")
        #expect(snap?.model == "claude-opus-5")
    }

    @Test func waitingReasonRecordedThenClearedWhenUnblocked() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "w1", "cwd": "/p",
        ])
        _ = process(.claude, [
            "hook_event_name": "Notification", "session_id": "w1",
            "notification_type": "permission_prompt",
        ])
        #expect(store.load(key: "claude-w1")?.notificationType == "permission_prompt")
        // a stale reason on a non-waiting row would mislead
        _ = process(.claude, ["hook_event_name": "Stop", "session_id": "w1"])
        #expect(store.load(key: "claude-w1")?.notificationType == nil)
    }

    @Test func stopFailureRecordsErrorKind() {
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": "e1", "cwd": "/p",
        ])
        _ = process(.claude, [
            "hook_event_name": "StopFailure", "session_id": "e1", "error": "rate_limit",
        ])
        let snap = store.load(key: "claude-e1")
        #expect(snap?.state == .error)
        #expect(snap?.errorKind == "rate_limit")
    }

    @Test func sessionEndKeepsRowAliveOnClearAndResume() {
        // on /clear and resume the process keeps running — removing the row
        // would drop a live session off the deck
        for reason in ["clear", "resume"] {
            _ = process(.claude, [
                "hook_event_name": "SessionStart", "session_id": "keep", "cwd": "/p",
            ])
            let action = process(.claude, [
                "hook_event_name": "SessionEnd", "session_id": "keep", "reason": reason,
            ])
            #expect(action == .set(.ready), "reason \(reason) must not remove the row")
            #expect(store.load(key: "claude-keep") != nil)
        }
        let gone = process(.claude, [
            "hook_event_name": "SessionEnd", "session_id": "keep", "reason": "logout",
        ])
        #expect(gone == .remove)
        #expect(store.load(key: "claude-keep") == nil)
    }

    @Test func codexLifecycleFixture() {
        // shape recorded from codex-cli 0.145.0 (session_id, turn_id, model…)
        let base: [String: Any] = [
            "session_id": "019fa95a-2ebf-7a83-b3ef-418972a171aa",
            "turn_id": "t-1", "cwd": "/private/tmp", "model": "gpt-5.6-sol",
            "permission_mode": "default",
        ]
        var start = base; start["hook_event_name"] = "SessionStart"
        var stop = base; stop["hook_event_name"] = "Stop"
        var end = base; end["hook_event_name"] = "SessionEnd"
        _ = process(.codex, start)
        #expect(store.load(key: "codex-019fa95a-2ebf-7a83-b3ef-418972a171aa")?.state == .ready)
        _ = process(.codex, stop)
        #expect(store.load(key: "codex-019fa95a-2ebf-7a83-b3ef-418972a171aa")?.state == .done)
        _ = process(.codex, end)
        #expect(store.load(key: "codex-019fa95a-2ebf-7a83-b3ef-418972a171aa") == nil)
    }
}
