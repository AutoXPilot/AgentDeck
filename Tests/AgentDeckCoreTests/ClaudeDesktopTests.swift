import Foundation
import Testing
@testable import AgentDeckCore

/// Claude Code sessions hosted by Claude Desktop: where they run, what a
/// click does, what the row says, and that restore never brings one back.
struct ClaudeDesktopTests {
    let home = "/Users/u"
    var scratch: String {
        "/Users/u/Library/Application Support/Claude/scratch-workspaces/"
            + "12116530-0000-4000-8000-000000000000/3ccfa680-0000-4000-8000-000000000000/"
            + "scratch-2026-10-19-64df10"
    }
    let inner = "/Users/u/Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app"
    let uuid = "67e51052-0000-4000-8000-000000000000"

    // MARK: host evidence

    @Test func scratchWorkspacesAreRecognisedAndNothingElse() {
        #expect(ClaudeDesktop.isScratchWorkspace(scratch, home: home))
        #expect(!ClaudeDesktop.isScratchWorkspace(
            "/Users/u/Library/Application Support/Claude/scratch-workspaces", home: home),
                "the root itself isn't a session's folder")
        #expect(!ClaudeDesktop.isScratchWorkspace("/Users/u/Code/AgentDeck", home: home))
        #expect(!ClaudeDesktop.isScratchWorkspace(
            "/Users/u/Library/Application Support/Claude/scratch-workspaces-old/x", home: home))
        #expect(!ClaudeDesktop.isScratchWorkspace(
            "/Users/u/Library/Application Support/Claude/scratch-workspaces/../../x", home: home),
                "standardized before the prefix check")
        #expect(!ClaudeDesktop.isScratchWorkspace("relative/scratch-workspaces/x", home: home))
    }

    @Test func aDesktopEntrypointMakesASessionAppHostedOnTheOuterBundle() {
        let host = ClaudeDesktop.effectiveHost(
            recorded: .unknown, transcriptEntrypoint: "claude-desktop",
            cwd: "/Users/u/Code/project", home: home)
        #expect(host == SessionHost(kind: .app, bundlePath: "/Applications/Claude.app"))
        #expect(ClaudeDesktop.isDesktopHost(host, home: home))
        // an ITERM_SESSION_ID inherited from the shell that launched Desktop
        // records terminal with no bundle; the entrypoint outweighs it
        #expect(ClaudeDesktop.effectiveHost(
            recorded: SessionHost(kind: .terminal), transcriptEntrypoint: "claude-desktop",
            cwd: "/x", home: home).kind == .app)
    }

    @Test func aScratchFolderAloneIsEnoughEvidence() {
        #expect(ClaudeDesktop.effectiveHost(
            recorded: .unknown, transcriptEntrypoint: nil, cwd: scratch, home: home)
                == SessionHost(kind: .app, bundlePath: "/Applications/Claude.app"))
    }

    @Test func aVerifiedTerminalWinsAndNoEvidenceStaysUnknown() {
        let iterm = SessionHost(kind: .terminal, bundlePath: "/Applications/iTerm.app")
        #expect(ClaudeDesktop.effectiveHost(
            recorded: iterm, transcriptEntrypoint: "claude-desktop", cwd: scratch, home: home) == iterm,
                "claude run in iTerm from inside a scratch folder is still in iTerm")
        #expect(ClaudeDesktop.effectiveHost(
            recorded: .unknown, transcriptEntrypoint: "cli", cwd: "/x", home: home) == .unknown)
        #expect(ClaudeDesktop.effectiveHost(
            recorded: .unknown, transcriptEntrypoint: nil, cwd: "/x", home: home) == .unknown,
                "unknown is not app")
    }

    @Test func theInnerBundleIsReplacedByTheOuterOne() {
        let host = ClaudeDesktop.effectiveHost(
            recorded: SessionHost(kind: .app, bundlePath: inner),
            transcriptEntrypoint: nil, cwd: "/x", home: home)
        #expect(host.bundlePath == "/Applications/Claude.app")
        // some other app host (an editor) is left alone
        let code = SessionHost(kind: .app, bundlePath: "/Applications/Visual Studio Code.app")
        #expect(ClaudeDesktop.effectiveHost(
            recorded: code, transcriptEntrypoint: nil, cwd: "/x", home: home) == code)
        #expect(!ClaudeDesktop.isDesktopHost(code, home: home))
    }

    /// Synthetic transcript tail, metadata only: a Desktop-started session
    /// with no hook snapshot. Read the way the app's refresh reads it, then
    /// resolved the way a click resolves it.
    @Test func aDesktopTranscriptFocusesClaudeAppNeverThePaneOrInnerBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-p", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"s"}"#,
            #"{"type":"user","entrypoint":"claude-desktop","isSidechain":false,"message":{"role":"user","content":"x"}}"#,
            #"{"type":"assistant","entrypoint":"claude-desktop","isSidechain":false,"message":{"role":"assistant","model":"claude-opus-5-5"}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let url = try #require(ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root))
        let entrypoint = ClaudeTranscript.latest(at: url)?.entrypoint
        #expect(entrypoint == "claude-desktop")

        let host = ClaudeDesktop.effectiveHost(
            recorded: .unknown, transcriptEntrypoint: entrypoint, cwd: "/Users/u/Code/p", home: home)
        let target = FocusResolver.resolve(
            terminalSessionId: "w0t0p0:AAAA-BBBB", owningAppBundlePath: inner, host: host)
        #expect(target == .application(bundlePath: "/Applications/Claude.app", name: "Claude"))
        #expect(FocusResolver.describe(target) == "Click to bring Claude to the front")
    }

    // MARK: row label

    @Test func theRowNamesOnlyAUserChosenNameElseTheFolder() {
        #expect(ClaudeDesktop.rowLabel(registryName: "Taxes", nameSource: "user", cwd: scratch)
                == ("Taxes", true))
        #expect(ClaudeDesktop.rowLabel(registryName: "fix-login", nameSource: "derived", cwd: scratch)
                == ("Claude Desktop · scratch 2026-10-19", false), "a generated name is from the conversation")
        #expect(ClaudeDesktop.rowLabel(registryName: "fix-login", nameSource: nil, cwd: "/Users/u/Code/AgentDeck")
                == ("Claude Desktop · AgentDeck", false), "a missing source isn't the user's")
        #expect(ClaudeDesktop.rowLabel(registryName: nil, nameSource: nil, cwd: "")
                == ("Claude Desktop", false))
    }

    @Test func onlyAScratchFolderNameIsShortened() {
        #expect(ClaudeDesktop.folderLabel("scratch-2026-10-19-64df10") == "scratch 2026-10-19")
        for kept in ["scratch-2026-10-19", "scratch-2026-1-19-64df10", "scratch-2026-10-19-zz",
                     "scratchpad", "my-scratch-2026-10-19-64df10", "scratch-2026-10-19-64df10-x"] {
            #expect(ClaudeDesktop.folderLabel(kept) == kept, "\(kept)")
        }
    }

    // MARK: capture

    func row(cwd: String = "/Users/u/Code/p", host: SessionHost = .unknown,
             pane: String? = "w0t0p0:G") -> SessionSnapshot {
        SessionSnapshot(provider: .claude, sessionId: uuid, projectPath: cwd, state: .ready,
                        event: "x", terminalSessionId: pane,
                        hostKind: host.kind?.rawValue, hostBundlePath: host.bundlePath)
    }

    func capture(_ s: SessionSnapshot, entrypoint: String? = nil) -> WorkspaceEntry? {
        WorkspaceCapture.entry(for: s, registry: nil, transcriptSessionKind: nil,
                               transcriptEntrypoint: entrypoint, codexName: nil,
                               terminal: .unknown, now: .distantPast, home: home)
    }

    @Test func captureLeavesOutEveryKindOfDesktopEvidence() {
        #expect(capture(row()) != nil, "control: an ordinary pane session is captured")
        #expect(capture(row(host: SessionHost(kind: .app, bundlePath: "/Applications/Claude.app"))) == nil)
        #expect(capture(row(cwd: scratch)) == nil, "scratch folder")
        #expect(capture(row(), entrypoint: "claude-desktop") == nil, "transcript entrypoint")
        #expect(capture(row(cwd: scratch, host: SessionHost(kind: .terminal, bundlePath: "/Applications/iTerm.app")))
                != nil, "a verified iTerm session in a scratch folder is still an iTerm session")
    }

    @Test func captureLeavesOutAnAppHostedCodexEvenWithAnInheritedPane() {
        func codex(_ host: SessionHost) -> SessionSnapshot {
            SessionSnapshot(provider: .codex, sessionId: uuid, projectPath: "/Users/u/Code/p",
                            state: .ready, event: "x", terminalSessionId: "w0t0p0:G",
                            hostKind: host.kind?.rawValue, hostBundlePath: host.bundlePath)
        }
        #expect(capture(codex(.unknown)) != nil)
        #expect(capture(codex(SessionHost(kind: .app, bundlePath: "/Applications/ChatGPT.app"))) == nil)
    }

    // MARK: restore

    func facts(appHosted: @escaping (WorkspaceEntry) -> Bool) -> WorkspaceRestore.Facts {
        .init(live: [], directoryExists: { _ in true }, conversationExists: { _ in true },
              appHosted: appHosted)
    }

    @Test func planSkipsWhatTheCurrentEvidenceSaysIsAppHosted() {
        let desk = WorkspaceEntry(provider: .claude, sessionId: uuid, cwd: "/Users/u/Code/p",
                                  lastSeen: .distantPast)
        let plan = WorkspaceRestore.plan([desk], facts: facts { _ in true })
        #expect(plan.launches.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.appHosted])
        #expect(WorkspaceRestore.describeSkips(plan.skipped) == "Skipped: p (runs inside an app).")
        #expect(WorkspaceRestore.plan([desk], facts: facts { _ in false }).launches.count == 1)
    }

    @Test func theDefaultEvidenceSkipsAScratchFolderEvenWithNoLiveFacts() {
        let real = ClaudeDesktop.scratchRoot() + "/a/b/scratch-2026-10-19-64df10"
        let desk = WorkspaceEntry(provider: .claude, sessionId: uuid, cwd: real, lastSeen: .distantPast)
        let plan = WorkspaceRestore.plan([desk], facts: .init(
            live: [], directoryExists: { _ in true }, conversationExists: { _ in true }))
        #expect(plan.skipped.map(\.reason) == [.appHosted])
    }

    /// An old-style generation, written by a build that captured Desktop
    /// sessions: it is neither offered nor restored.
    @Test func anOldGenerationsDesktopEntryIsNeitherOfferedNorRestored() throws {
        let store = WorkspaceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wsd-\(UUID().uuidString)", isDirectory: true))
        let terminalId = "44444444-0000-4000-8000-000000000000"
        let object: [String: Any] = [
            "schemaVersion": 1, "bootID": "OLD", "updatedAt": "2026-10-23T02:50:08.929Z",
            "closedSets": [],
            "entries": [
                ["provider": "claude", "sessionId": uuid, "cwd": scratch,
                 "lastSeen": "2026-10-23T02:50:08.929Z"],
                ["provider": "claude", "sessionId": terminalId, "cwd": "/Users/u/Code/p",
                 "lastSeen": "2026-10-23T02:50:08.000Z"],
            ],
        ]
        let url = store.generationURL("OLD")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let generation = try #require(store.loadGeneration(bootID: "OLD"))
        #expect(generation.entries.count == 2)

        let appHosted: (WorkspaceEntry) -> Bool = {
            ClaudeDesktop.isAppHosted($0, liveHost: nil, transcriptEntrypoint: nil, home: home)
        }
        let offered = generation.restoreSets(live: [], finished: true, excluding: appHosted)
            .flatMap(\.entries).map(\.sessionId)
        #expect(offered == [terminalId])

        let plan = WorkspaceRestore.plan(generation.entries, facts: facts(appHosted: appHosted))
        #expect(plan.skipped.map(\.entry.sessionId) == [uuid])
        #expect(plan.skipped.map(\.reason) == [.appHosted])
        #expect(plan.launches.map(\.entry.sessionId) == [terminalId])
    }

    @Test func appHostedEvidenceForAnEntry() {
        let plain = WorkspaceEntry(provider: .claude, sessionId: uuid, cwd: "/Users/u/Code/p",
                                   lastSeen: .distantPast)
        #expect(!ClaudeDesktop.isAppHosted(plain, liveHost: nil, transcriptEntrypoint: nil, home: home))
        #expect(ClaudeDesktop.isAppHosted(plain, liveHost: nil, transcriptEntrypoint: "claude-desktop", home: home))
        #expect(ClaudeDesktop.isAppHosted(
            plain, liveHost: SessionHost(kind: .app, bundlePath: inner), transcriptEntrypoint: nil, home: home))
        var codex = plain
        codex.provider = .codex
        codex.cwd = scratch
        #expect(!ClaudeDesktop.isAppHosted(codex, liveHost: nil, transcriptEntrypoint: nil, home: home),
                "Claude Desktop evidence describes Claude sessions only")
    }
}
