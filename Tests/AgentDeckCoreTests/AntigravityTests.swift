import Darwin
import Foundation
import Testing
@testable import AgentDeckCore

/// Payload shapes recorded from agy 1.4.7 hook invocations (metadata-only
/// probe; content fields replaced by distinctive synthetic strings).
enum AgyFixture {
    static let id = "c3f378f8-90e1-43ea-875a-a49794f32b55"
    /// Stand-ins for content: the user's message, tool arguments and the
    /// free-text error. None may reach a snapshot, a normalized event, or
    /// a log.
    static let userText = "ZEBRA-PROMPT-7731 please refactor the payroll module"
    static let argsText = "ZEBRA-ARGS-4410 rm -rf ~/secret-project"
    static let errorText = "ZEBRA-ERROR-9902 model said something private"
    static let secrets = ["ZEBRA-PROMPT-7731", "ZEBRA-ARGS-4410", "ZEBRA-ERROR-9902"]

    static func base(_ extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = [
            "conversationId": id,
            "workspacePaths": ["/Users/x/code/payroll"],
            "modelName": "gemini-4-argon-medium",
            "transcriptPath": "/Users/x/.gemini/antigravity-cli/conversations/t.jsonl",
            "artifactDirectoryPath": "/Users/x/.gemini/antigravity-cli/brain/\(id)",
            "lastUserInput": userText,
        ]
        p.merge(extra) { _, new in new }
        return p
    }

    static func invocation(_ n: Int) -> [String: Any] {
        base(["invocationNum": n, "initialNumSteps": 3])
    }

    static func tool(_ name: String, error: String? = nil) -> [String: Any] {
        var p = base(["stepIdx": 4, "toolCall": ["name": name, "args": ["command": argsText]]])
        if let error { p["error"] = error }
        return p
    }

    static func stop(fullyIdle: Bool, error: String = "", reason: String = "NO_TOOL_CALL") -> [String: Any] {
        base(["executionNum": 1, "fullyIdle": fullyIdle, "terminationReason": reason,
              "error": error])
    }

    static func data(_ p: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: p)
    }
}

final class AntigravityHookTests {
    let dir: URL
    let store: SnapshotStore
    let key = SessionKey.make(.antigravity, AgyFixture.id)

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-agy-\(UUID().uuidString)")
        store = SnapshotStore(directory: dir)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func send(_ event: String?, _ payload: [String: Any],
              env: [String: String] = ["ITERM_SESSION_ID": "w0t1p0:AAAA-BBBB"]) -> HookAction {
        HookProcessor.process(
            provider: .antigravity, payloadData: AgyFixture.data(payload), argvEvent: event,
            environment: env, parentPid: nil, store: store, host: .unknown)
    }

    func storedText() throws -> String {
        String(decoding: try Data(contentsOf: store.url(forKey: key)), as: UTF8.self)
    }

    @Test func theAdapterReadsCamelCaseAndArgvAndNothingElse() throws {
        let e = try #require(HookPayload.parse(
            provider: .antigravity,
            data: AgyFixture.data(AgyFixture.tool("ask_question", error: AgyFixture.errorText)),
            argvEvent: "PostToolUse"))
        #expect(e.event == "PostToolUse")
        #expect(e.sessionId == AgyFixture.id)
        #expect(e.cwd == "/Users/x/code/payroll")
        #expect(e.model == "gemini-4-argon-medium")
        #expect(e.toolName == "ask_question")
        #expect(e.reportedError)
        let described = String(describing: e)
        for secret in AgyFixture.secrets { #expect(!described.contains(secret), "\(secret)") }
    }

    @Test func withoutAnArgvEventThePayloadIsIgnored() {
        #expect(send(nil, AgyFixture.invocation(0)) == .ignore)
        #expect(send("", AgyFixture.invocation(0)) == .ignore)
        // a payload-borne event name means nothing for agy
        var named = AgyFixture.invocation(0)
        named["hook_event_name"] = "PreInvocation"
        #expect(send(nil, named) == .ignore)
        #expect(store.loadAll().isEmpty)
        #expect(HookPayload.parse(provider: .antigravity,
                                  data: AgyFixture.data(["workspacePaths": ["/p"]]),
                                  argvEvent: "Stop") == nil, "no conversation id")
    }

    @Test func theFirstEventCreatesTheRowWithItsMetadata() throws {
        // SessionStart never fired in the probe; PreInvocation comes first
        #expect(send("PreInvocation", AgyFixture.invocation(0)) == .set(.working))
        let snap = try #require(store.load(key: key))
        #expect(snap.key == "antigravity-\(AgyFixture.id)")
        #expect(snap.projectPath == "/Users/x/code/payroll")
        #expect(snap.model == "gemini-4-argon-medium")
        #expect(snap.terminalSessionId == "w0t1p0:AAAA-BBBB")
        #expect(snap.permissionMode == nil)
    }

    @Test func aMissedStartStillGetsARowFromStop() {
        // Claude drops a Stop for an unknown session (SessionEnd race); agy
        // has no SessionEnd, and no SessionStart, so Stop must create
        #expect(send("Stop", AgyFixture.stop(fullyIdle: true)) == .set(.done))
        #expect(store.load(key: key)?.state == .done)
    }

    @Test func aQuestionIsAskedThenAnsweredThenTheTurnEnds() throws {
        send("PreInvocation", AgyFixture.invocation(0))
        send("PreToolUse", AgyFixture.tool("run_command"))
        send("PostToolUse", AgyFixture.tool("run_command"))
        #expect(store.load(key: key)?.state == .working, "other tools change nothing")

        #expect(send("PreToolUse", AgyFixture.tool("ask_question")) == .set(.waiting))
        let waiting = try #require(store.load(key: key))
        #expect(waiting.state == .waiting && waiting.notificationType == "ask_question")
        // the pipeline keeps it blocking, with a readable reason
        let out = SessionPipeline.run(snapshots: [waiting], registry: [:], acks: [:],
                                      frozenOrder: nil, popoverVisible: false)
        #expect(out.rows.first?.state == .waiting)
        #expect(out.alertCount == 1)
        #expect(out.waitingReasons[key] == "asked you a question")

        #expect(send("PostToolUse", AgyFixture.tool("ask_question")) == .set(.working))
        #expect(store.load(key: key)?.notificationType == nil)
        // several invocations per turn; only Stop ends it
        #expect(send("PostInvocation", AgyFixture.invocation(0)) == .ignore)
        send("PreInvocation", AgyFixture.invocation(1))
        send("PostInvocation", AgyFixture.invocation(1))
        #expect(store.load(key: key)?.state == .working)
        #expect(send("Stop", AgyFixture.stop(fullyIdle: true)) == .set(.done))
        #expect(store.load(key: key)?.state == .done)
    }

    @Test func anErrorOutranksIdleAndKeepsOnlyACategory() throws {
        send("PreInvocation", AgyFixture.invocation(0))
        #expect(send("Stop", AgyFixture.stop(
            fullyIdle: true, error: AgyFixture.errorText, reason: "MODEL_ERROR")) == .set(.error))
        let snap = try #require(store.load(key: key))
        #expect(snap.state == .error)
        #expect(snap.errorKind == "model_error")
        // a reason that isn't an enum-like token is not kept either
        send("PreInvocation", AgyFixture.invocation(1))
        send("Stop", AgyFixture.stop(fullyIdle: true, error: "x", reason: "ZEBRA free text!"))
        #expect(store.load(key: key)?.errorKind == "error")
    }

    @Test func aStopThatIsNotIdleIsIgnored() {
        send("PreInvocation", AgyFixture.invocation(0))
        #expect(send("Stop", AgyFixture.stop(fullyIdle: false)) == .ignore)
        #expect(store.load(key: key)?.state == .working)
        // an empty error string is no error
        #expect(send("Stop", AgyFixture.stop(fullyIdle: true, error: "")) == .set(.done))
    }

    @Test func sessionStartIsReadyIfANewerAgyEverFiresIt() {
        #expect(send("SessionStart", AgyFixture.base()) == .set(.ready))
    }

    /// Privacy guard: the user's message, tool arguments and error text
    /// arrive on every event; none may appear in the stored file.
    @Test func theStoredSnapshotNeverHoldsContent() throws {
        let sequence: [(String, [String: Any])] = [
            ("SessionStart", AgyFixture.base()),
            ("PreInvocation", AgyFixture.invocation(0)),
            ("PreToolUse", AgyFixture.tool("ask_question")),
            ("PostToolUse", AgyFixture.tool("ask_question", error: AgyFixture.errorText)),
            ("PostInvocation", AgyFixture.invocation(0)),
            ("Stop", AgyFixture.stop(fullyIdle: true, error: AgyFixture.errorText,
                                     reason: "MODEL_ERROR")),
        ]
        for (event, payload) in sequence {
            send(event, payload)
            let text = try storedText()
            for secret in AgyFixture.secrets {
                #expect(!text.contains(secret), "\(event) stored \(secret)")
            }
        }
    }
}

struct AntigravityMappingTests {
    func e(_ event: String, tool: String? = nil, idle: Bool? = nil, error: Bool = false)
        -> NormalizedHookEvent
    {
        NormalizedHookEvent(event: event, sessionId: "s", toolName: tool, fullyIdle: idle,
                            reportedError: error)
    }

    @Test func theTable() {
        func act(_ x: NormalizedHookEvent) -> HookAction {
            EventMapping.action(for: x, provider: .antigravity)
        }
        #expect(act(e("SessionStart")) == .set(.ready))
        #expect(act(e("PreInvocation")) == .set(.working))
        #expect(act(e("PostInvocation")) == .ignore)
        #expect(act(e("PreToolUse", tool: "ask_question")) == .set(.waiting))
        #expect(act(e("PostToolUse", tool: "ask_question")) == .set(.working))
        #expect(act(e("PreToolUse", tool: "run_command")) == .ignore)
        #expect(act(e("PreToolUse")) == .ignore)
        #expect(act(e("Stop", idle: true)) == .set(.done))
        #expect(act(e("Stop", idle: false)) == .ignore)
        #expect(act(e("Stop")) == .ignore)
        #expect(act(e("Stop", idle: true, error: true)) == .set(.error))
        #expect(act(e("Stop", idle: false, error: true)) == .set(.error))
        // Claude's names mean nothing here
        #expect(act(e("UserPromptSubmit")) == .ignore)
        #expect(act(e("SessionEnd")) == .ignore)
        // and agy's table doesn't leak into Claude's
        #expect(EventMapping.action(for: e("PreInvocation"), provider: .claude) == .ignore)
    }
}

final class AntigravityInstallerTests {
    let dir: URL
    let helperPath = "/Stable/Application Support/AgentDeck/bin/agentdeck-hook"
    let installer: HookInstaller
    let url: URL

    /// Tony's real set's shape (`auto-approve-all`, matcher "*").
    nonisolated(unsafe) static let userSet: [String: Any] = [
        "PreToolUse": [[
            "matcher": "*",
            "hooks": [["type": "command", "command": "/Users/x/bin/approve.sh", "timeout": 5]],
        ]]
    ]

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-agy-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HookInstaller(helperPath: helperPath)
        url = dir.appendingPathComponent("hooks.json")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func write(_ obj: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]).write(to: url)
    }

    func read() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func q(_ event: String) -> String {
        "'\(helperPath)' antigravity \(event)"
    }

    @Test func installAddsOneSetAndLeavesTheUsersSetEqual() throws {
        try write(["auto-approve-all": Self.userSet])
        #expect(try installer.install(.antigravity, fileURL: url))
        let root = try read()
        let theirs = try #require(root["auto-approve-all"], "the user's set survives")
        #expect(HookInstaller.jsonEqual(theirs, Self.userSet))
        #expect(Set(root.keys) == ["auto-approve-all", "agentdeck"])
        let set = try #require(root["agentdeck"] as? [String: Any])
        for event in ["SessionStart", "PreInvocation", "PostInvocation", "Stop"] {
            let handlers = try #require(set[event] as? [[String: Any]])
            #expect(handlers.count == 1)
            #expect(handlers[0]["type"] as? String == "command")
            #expect(handlers[0]["command"] as? String == q(event))
        }
        for event in ["PreToolUse", "PostToolUse"] {
            let groups = try #require(set[event] as? [[String: Any]])
            #expect(groups.count == 1 && groups[0]["matcher"] as? String == "ask_question")
            let hooks = try #require(groups[0]["hooks"] as? [[String: Any]])
            #expect(hooks.first?["command"] as? String == q(event))
        }
        #expect(installer.isInstalled(provider: .antigravity, in: url))
        // a backup of the original bytes was taken
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("hooks.json.agentdeck-") && $0.hasSuffix(".bak") }
        #expect(backups.count == 1)
    }

    @Test func installIsIdempotent() throws {
        try write(["auto-approve-all": Self.userSet])
        #expect(try installer.install(.antigravity, fileURL: url))
        let first = try Data(contentsOf: url)
        #expect(try installer.install(.antigravity, fileURL: url) == false)
        #expect(try Data(contentsOf: url) == first)
    }

    @Test func aMissingFileIsCreatedWithOnlyOurSet() throws {
        #expect(try installer.install(.antigravity, fileURL: url))
        #expect(try Set(read().keys) == ["agentdeck"])
    }

    @Test func aForeignSetWithOurNameIsRefusedAndNothingIsWritten() throws {
        let theirs: [String: Any] = [
            "Stop": [["type": "command", "command": "/usr/bin/say finished"]]
        ]
        try write(["auto-approve-all": Self.userSet, "agentdeck": theirs])
        let before = try Data(contentsOf: url)
        #expect(throws: InstallerError.self) { try self.installer.install(.antigravity, fileURL: self.url) }
        #expect(try Data(contentsOf: url) == before)
        #expect(!installer.isInstalled(provider: .antigravity, in: url))
        // a set naming our helper is ours, and is repaired in place
        try write(["agentdeck": ["Stop": [["type": "command", "command": q("Stop")]]]])
        #expect(try installer.install(.antigravity, fileURL: url))
        #expect(installer.isInstalled(provider: .antigravity, in: url))
    }

    @Test func aSymlinkedConfigStaysASymlink() throws {
        let real = dir.appendingPathComponent("real-hooks.json")
        try JSONSerialization.data(withJSONObject: ["auto-approve-all": Self.userSet]).write(to: real)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        #expect(try installer.install(.antigravity, fileURL: url))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(installer.isInstalled(provider: .antigravity, in: real))
    }

    /// Structural health: each condition below must read as not installed.
    @Test func isInstalledChecksStructureNotMentions() throws {
        func mutated(_ change: (inout [String: Any]) -> Void) throws -> Bool {
            try write(["agentdeck": installer.canonicalHookSet(for: .antigravity)])
            var root = try read()
            var set = try #require(root["agentdeck"] as? [String: Any])
            change(&set)
            root["agentdeck"] = set
            try write(root)
            return installer.isInstalled(provider: .antigravity, in: url)
        }
        #expect(try mutated { _ in }, "the canonical set is installed")
        #expect(try mutated { $0["enabled"] = true })
        #expect(try mutated { $0["enabled"] = false } == false, "disabled")
        #expect(try mutated { $0["PostInvocation"] = nil } == false, "a missing event")
        #expect(try mutated {
            $0["PreInvocation"] = [["type": "command", "command": self.q("Stop")]]
        } == false, "the wrong event on argv")
        #expect(try mutated {
            $0["Stop"] = [["type": "command", "command": "'\(self.helperPath)' antigravity"]]
        } == false, "no event on argv")
        #expect(try mutated {
            $0["PreToolUse"] = [["matcher": "*", "hooks": [
                ["type": "command", "command": self.q("PreToolUse")]]]]
        } == false, "the wrong matcher")
        #expect(try mutated {
            $0["PostToolUse"] = [["type": "command", "command": self.q("PostToolUse")]]
        } == false, "a tool event outside a matcher group")
        // a mention of the helper elsewhere doesn't count
        try write(["auto-approve-all": ["Stop": [["type": "command", "command": q("Stop")]]]])
        #expect(!installer.isInstalled(provider: .antigravity, in: url))
    }

    @Test func claudeAndCodexInstallsAreUnchanged() throws {
        // the event-on-argv form is agy's alone
        #expect(installer.command(for: .claude, event: "Stop") == "'\(helperPath)' claude")
        #expect(installer.command(for: .codex, event: "Stop") == "'\(helperPath)' codex")
    }

    /// Against a copy of the real file, when there is one: the user's own
    /// sets survive JSON-equal. The real file is only read.
    @Test func aCopyOfTheRealConfigKeepsEveryOtherSet() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/hooks.json")
        guard let original = try? Data(contentsOf: real),
              let parsed = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              parsed["agentdeck"] == nil else { return }
        try original.write(to: url)
        #expect(try installer.install(.antigravity, fileURL: url))
        let after = try read()
        for (name, value) in parsed {
            let kept = try #require(after[name], "\(name) survives")
            #expect(HookInstaller.jsonEqual(kept, value), "\(name)")
        }
        #expect(try Data(contentsOf: real) == original, "the real file is untouched")
    }
}

final class AntigravityConversationTests {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdeck-agy-state-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func conversationExistenceIsTheDatabaseFileOnly() throws {
        let id = "c3f378f8-90e1-43ea-875a-a49794f32b55"
        #expect(AntigravityState.conversationExists(id: id, directory: dir) == nil,
                "no conversations folder: can't tell")
        let conversations = dir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        #expect(AntigravityState.conversationExists(id: id, directory: dir) == false)
        FileManager.default.createFile(
            atPath: conversations.appendingPathComponent("\(id).db").path, contents: nil)
        #expect(AntigravityState.conversationExists(id: id.uppercased(), directory: dir) == true)
        #expect(AntigravityState.conversationExists(id: "../../etc/passwd", directory: dir) == false)
    }
}

struct AntigravityCaptureTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func agy(_ id: String, pid: Int32? = nil, age: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(provider: .antigravity, sessionId: id, projectPath: "/p", state: .done,
                        event: "Stop", updatedAt: now.addingTimeInterval(-age), agentPid: pid)
    }

    @Test func captureKeepsATerminalAgySessionWithAFolderAndNoName() {
        func capture(_ s: SessionSnapshot, terminal: WorkspaceCapture.Terminal = .unknown) -> WorkspaceEntry? {
            WorkspaceCapture.entry(for: s, registry: nil, transcriptSessionKind: nil,
                                   codexName: "should-not-be-used", terminal: terminal, now: now)
        }
        var s = agy("c3f378f8-90e1-43ea-875a-a49794f32b55", age: 0)
        s.terminalSessionId = "w0t0p0:G"
        s.permissionMode = "bypassPermissions"
        let e = capture(s)
        #expect(e?.provider == .antigravity && e?.cwd == "/p")
        #expect(e?.displayName == nil && e?.permissionMode == nil)
        #expect(capture(s, terminal: .elsewhere) == nil)
        var app = s
        app.hostKind = "app"
        #expect(capture(app) == nil)
        var noFolder = s
        noFolder.projectPath = ""
        #expect(capture(noFolder) == nil)
    }
}
