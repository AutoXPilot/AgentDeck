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

final class AntigravityPresenceTests {
    let dir: URL
    var presence: URL { dir.appendingPathComponent("presence") }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-agy-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("presence"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func lockFile(_ id: String) -> URL {
        let url = presence.appendingPathComponent("\(id).lock")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// Holds an exclusive flock as agy does; a separate open file, so the
    /// probe's lock conflicts with it even in this process.
    func hold(_ url: URL) -> Int32 {
        let fd = open(url.path, O_RDONLY)
        precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    @Test func onlyAHeldLockIsARunningConversation() {
        let liveId = "C3F378F8-90E1-43EA-875A-A49794F32B55"
        let live = lockFile(liveId)
        _ = lockFile("5b9afd2c-1029-42c8-971d-db7e6213cac0")   // left behind by a closed session
        _ = lockFile("not-a-uuid")
        let fd = hold(live)
        let running = AntigravityState.runningConversations(directory: dir)
        #expect(running.map(\.conversationId) == [liveId.lowercased()])
        // released: no longer running
        close(fd)
        #expect(AntigravityState.runningConversations(directory: dir).isEmpty)
    }

    /// The lock file is reused across runs, so its creation date can be
    /// weeks old; the conversation database's mtime says when it was last
    /// active.
    @Test func aDiscoveredRowsAgeComesFromTheConversationNotTheLockFile() throws {
        let id = "c3f378f8-90e1-43ea-875a-a49794f32b55"
        let lock = lockFile(id)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: lock.path)
        let fd = hold(lock)
        defer { close(fd) }
        #expect(AntigravityState.runningConversations(directory: dir).first?.since == old,
                "no database: the lock's creation is all there is")
        let conversations = dir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let db = conversations.appendingPathComponent("\(id).db")
        FileManager.default.createFile(atPath: db.path, contents: nil)
        let active = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: active], ofItemAtPath: db.path)
        #expect(AntigravityState.runningConversations(directory: dir).first?.since == active)
    }

    @Test func probingNeverCreatesOrChangesALockFile() throws {
        let missing = presence.appendingPathComponent("7e0c2b8a-1111-4222-8333-944455556666.lock")
        #expect(!AntigravityState.isLockHeld(missing))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let url = lockFile("7e0c2b8a-1111-4222-8333-944455556667")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(!AntigravityState.isLockHeld(url))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(after[.size] as? Int == 0)
        // the probe released its own lock: agy can still take it exclusively
        let fd = hold(url)
        close(fd)
    }

    @Test func aFolderIsUsedOnlyWhenOneWorkspaceNamesTheConversation() {
        let a = "c3f378f8-90e1-43ea-875a-a49794f32b55"
        let b = "5b9afd2c-1029-42c8-971d-db7e6213cac0"
        let cache = try! JSONSerialization.data(withJSONObject: [
            "/Users/x": a.uppercased(),
            "/Users/x/one": b, "/Users/x/two": b,
            "relative/path": "7e0c2b8a-1111-4222-8333-944455556666",
            "/Users/x/bad": "not-a-uuid",
        ])
        #expect(AntigravityState.unambiguousWorkspaces(fromCache: cache) == [a: "/Users/x"])
        #expect(AntigravityState.unambiguousWorkspaces(fromCache: Data("[]".utf8)).isEmpty)
    }

    @Test func discoveredRowsCarryOnlyWhatIsKnown() {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = AntigravityState.discoveredSnapshots(
            [.init(conversationId: "a", since: since), .init(conversationId: "b", since: nil)],
            workspaces: ["a": "/Users/x/code"])
        #expect(rows.map(\.key) == ["antigravity-a", "antigravity-b"])
        #expect(rows[0].projectPath == "/Users/x/code" && rows[1].projectPath == "")
        #expect(rows.allSatisfy { $0.agentPid == nil && $0.terminalSessionId == nil })
        #expect(rows.allSatisfy { $0.state == .ready && $0.model == nil })
        #expect(rows[0].updatedAt == since, "never the scan time")
        // no folder, no restore entry
        #expect(WorkspaceCapture.entry(for: rows[1], registry: nil, transcriptSessionKind: nil,
                                       codexName: nil, terminal: .unknown, now: since) == nil)
    }

    @Test func aHookSnapshotBeatsDiscoveryInThePipeline() {
        let hook = SessionSnapshot(provider: .antigravity, sessionId: "a", projectPath: "/p",
                                   state: .working, event: "PreInvocation")
        let found = AntigravityState.discoveredSnapshots(
            [.init(conversationId: "a", since: nil), .init(conversationId: "b", since: nil)],
            workspaces: [:])
        let out = SessionPipeline.run(snapshots: [hook], registry: [:], discovered: found,
                                      acks: [:], frozenOrder: nil, popoverVisible: false)
        #expect(out.rows.count == 2)
        #expect(out.rows.first { $0.sessionId == "a" }?.state == .working)
        #expect(out.rows.contains { $0.key == "antigravity-b" })
    }

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

struct AntigravityLivenessTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func agy(_ id: String, pid: Int32? = nil, age: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(provider: .antigravity, sessionId: id, projectPath: "/p", state: .done,
                        event: "Stop", updatedAt: now.addingTimeInterval(-age), agentPid: pid)
    }

    @Test func aHeldLockProtectsTheRowAndReleasingItRestoresNormalExpiry() {
        let probe = Liveness.ProcessProbe { _ in nil }
        let stale = agy("a", age: 48 * 3600)
        #expect(Liveness.keysToRemove([stale], now: now, bootedAt: nil,
                                      confirmedLive: ["antigravity-a"], probe: probe).isEmpty)
        #expect(Liveness.keysToRemove([stale], now: now, bootedAt: nil,
                                      confirmedLive: [], probe: probe) == ["antigravity-a"])
        // a recent pid-less row stays until the normal idle cap
        #expect(Liveness.keysToRemove([agy("b", age: 600)], now: now, bootedAt: nil,
                                      confirmedLive: [], probe: probe).isEmpty)
    }

    @Test func presenceIsEvidenceForAgyOnly() {
        let evidence = RunningEvidence(
            claudeRegistryLive: [],
            presenceLive: ["antigravity-a", "claude-c", "codex-x"],
            pidTrusted: { pid, _, _ in pid == 100 },
            processScan: { _, _ in Issue.record("agy is never scanned"); return [] })
        let keys = evidence.runningKeys(rows: [agy("p", pid: 100, age: 0), agy("d", pid: 5, age: 0)])
        #expect(keys == ["antigravity-a", "antigravity-p"])
        #expect(evidence.runningKeys(rows: [], scanning: ["antigravity-z"]) == ["antigravity-a"])
        func entry(_ id: String) -> WorkspaceEntry {
            WorkspaceEntry(provider: .antigravity, sessionId: id, cwd: "/p", lastSeen: now)
        }
        #expect(evidence.isRunning(entry("a"), snapshot: nil))
        #expect(evidence.isRunning(entry("p"), snapshot: agy("p", pid: 100, age: 0)))
        #expect(!evidence.isRunning(entry("d"), snapshot: agy("d", pid: 5, age: 0)))
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
