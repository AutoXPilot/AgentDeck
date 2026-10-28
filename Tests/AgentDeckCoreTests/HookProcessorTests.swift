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
        // .json snapshots only — a per-key .lock dotfile also lives here now
        func snapshots() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".json") }
        }
        let evil = "../../../../.claude/settings"
        _ = process(.claude, [
            "hook_event_name": "SessionStart", "session_id": evil, "cwd": "/tmp",
        ])
        // whatever was written must be inside the sessions dir
        let written = try snapshots()
        #expect(written.count == 1)
        #expect(!written[0].contains(".."))
        // and removal with the same evil id must not leave a snapshot behind
        _ = process(.claude, ["hook_event_name": "SessionEnd", "session_id": evil])
        #expect(try snapshots().isEmpty)
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
        #expect(snap?.schemaVersion == SessionSnapshot.currentSchemaVersion)
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

    // MARK: host

    let iTermHost = SessionHost(kind: .terminal, bundlePath: "/Applications/iTerm.app")
    let desktopHost = SessionHost(kind: .app, bundlePath: "/Applications/Claude.app")

    func hosted(_ event: String, host: SessionHost?, env: [String: String] = [:]) {
        HookProcessor.process(
            provider: .claude,
            payloadData: payload(["session_id": "h1", "hook_event_name": event, "cwd": "/p"]),
            environment: env, parentPid: nil, store: store, host: host)
    }

    @Test func theHostIsRecorded() {
        hosted("SessionStart", host: iTermHost, env: ["ITERM_SESSION_ID": "w0t0p0:PANE"])
        let snap = store.load(key: "claude-h1")
        #expect(snap?.hostKind == "terminal")
        #expect(snap?.hostBundlePath == "/Applications/iTerm.app")
    }

    @Test func anAppHostWithoutAPaneDropsTheOldPane() {
        // the conversation was resumed inside an app: the iTerm tab it
        // came from is no longer where it is
        hosted("SessionStart", host: iTermHost, env: ["ITERM_SESSION_ID": "w0t0p0:PANE"])
        hosted("UserPromptSubmit", host: desktopHost)
        let snap = store.load(key: "claude-h1")
        #expect(snap?.terminalSessionId == nil)
        #expect(snap?.hostKind == "app")
        #expect(snap?.hostBundlePath == "/Applications/Claude.app")
    }

    @Test func aChangedTerminalHostWithoutAPaneDropsTheOldPane() {
        hosted("SessionStart", host: iTermHost, env: ["ITERM_SESSION_ID": "w0t0p0:PANE"])
        hosted("UserPromptSubmit",
               host: SessionHost(kind: .terminal, bundlePath: "/Applications/Ghostty.app"))
        #expect(store.load(key: "claude-h1")?.terminalSessionId == nil)
    }

    @Test func anUnknownOrSameHostKeepsCarryingThePane() {
        hosted("SessionStart", host: iTermHost, env: ["ITERM_SESSION_ID": "w0t0p0:PANE"])
        hosted("UserPromptSubmit", host: iTermHost)
        #expect(store.load(key: "claude-h1")?.terminalSessionId == "w0t0p0:PANE")
        hosted("Stop", host: .unknown)
        let snap = store.load(key: "claude-h1")
        #expect(snap?.terminalSessionId == "w0t0p0:PANE")
        #expect(snap?.hostKind == "terminal", "an unknown reading keeps the recorded host")
    }

    @Test func aSnapshotFromBeforeHostsKeepsItsPane() {
        // written by an older helper: no host fields
        try? store.write(SessionSnapshot(
            provider: .claude, sessionId: "h1", projectPath: "/p", state: .ready,
            event: "SessionStart", terminalSessionId: "w0t0p0:PANE"))
        hosted("UserPromptSubmit", host: iTermHost)
        #expect(store.load(key: "claude-h1")?.terminalSessionId == "w0t0p0:PANE")
    }

    @Test func anAppHostWithAPaneInTheEnvironmentRecordsBoth() {
        // inherited ITERM_SESSION_ID: recorded, but focus ignores it for an
        // app host (FocusResolver)
        hosted("SessionStart", host: desktopHost, env: ["ITERM_SESSION_ID": "w0t0p0:INHERITED"])
        let snap = store.load(key: "claude-h1")
        #expect(snap?.terminalSessionId == "w0t0p0:INHERITED")
        #expect(snap?.host.kind == .app)
    }

    @Test func anAppHostDropsAPaneCarriedFromBeforeHostsWereRecorded() {
        // no recorded host to compare against: the app reading alone is
        // enough, because an app has no pane
        try? store.write(SessionSnapshot(
            provider: .claude, sessionId: "h1", projectPath: "/p", state: .ready,
            event: "SessionStart", terminalSessionId: "w0t0p0:PANE"))
        hosted("UserPromptSubmit", host: desktopHost)
        #expect(store.load(key: "claude-h1")?.terminalSessionId == nil)
    }

    // MARK: parsing

    @Test func parsingKeepsMetadataAndNothingElse() throws {
        let e = try #require(HookPayload.parse(provider: .claude, data: payload([
            "session_id": "a/b", "hook_event_name": "StopFailure", "cwd": "/p",
            "permission_mode": "plan", "model": "claude-opus-5",
            "effort": ["level": "high"], "error": "rate_limit", "reason": "other",
            "prompt": "secret prompt", "last_assistant_message": "secret reply",
            "tool_input": ["command": "secret"], "notification_type": "permission_prompt",
        ])))
        #expect(e.event == "StopFailure")
        #expect(e.sessionId == SnapshotStore.sanitizeKeyComponent("a/b"))
        #expect(e.cwd == "/p" && e.permissionMode == "plan" && e.model == "claude-opus-5")
        #expect(e.effort == "high" && e.errorKind == "rate_limit" && e.endReason == "other")
        #expect(e.notificationType == "permission_prompt")
        // content can't be carried: no field holds it
        #expect(!String(describing: e).contains("secret"))
    }

    @Test func parsingRejectsWhatCannotBeKeyed() {
        #expect(HookPayload.parse(provider: .codex, data: Data("{".utf8)) == nil)
        #expect(HookPayload.parse(provider: .codex, data: payload(["session_id": "x"])) == nil)
        #expect(HookPayload.parse(provider: .codex,
                                  data: payload(["hook_event_name": "Stop"])) == nil)
        // the snake_case providers take the event from the payload, not argv
        #expect(HookPayload.parse(provider: .claude,
                                  data: payload(["session_id": "x"]), argvEvent: "Stop") == nil)
        #expect(HookPayload.parse(provider: .claude, data: payload(
            ["session_id": "x", "hook_event_name": "Stop"]), argvEvent: "SessionStart")?.event
            == "Stop")
    }

    @Test func stopNeverCreatesForClaudeOrCodex() {
        for provider in [Provider.claude, .codex] {
            #expect(provider.spec.stopUpdatesOnly, "both have a SessionEnd that can race Stop")
            #expect(process(provider, ["hook_event_name": "Stop", "session_id": "nobody"]) == .ignore)
        }
        #expect(store.loadAll().isEmpty)
    }
}
