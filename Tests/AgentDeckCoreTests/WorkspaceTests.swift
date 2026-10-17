import Foundation
import Testing
@testable import AgentDeckCore

struct WorkspaceStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func tempStore(keep: Int = 5) -> WorkspaceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        return WorkspaceStore(directory: dir, keepGenerations: keep)
    }

    func entry(_ id: String, cwd: String = "/tmp", provider: Provider = .claude) -> WorkspaceEntry {
        WorkspaceEntry(provider: provider, sessionId: id, cwd: cwd, lastSeen: .distantPast)
    }

    @Test func closingSessionsNeverShrinksTheGeneration() throws {
        // The failure both reviewers predicted: a writer that mirrors the
        // live set empties itself as panes close during shutdown, then the
        // next login overwrites it with nothing.
        let store = tempStore()
        try store.record(live: [entry("a"), entry("b"), entry("c")], bootID: "B1", now: t0)
        try store.record(live: [entry("a"), entry("b")], bootID: "B1", now: t0 + 120)
        try store.record(live: [entry("a")], bootID: "B1", now: t0 + 240)
        try store.record(live: [], bootID: "B1", now: t0 + 360)
        let onDisk = try #require(store.loadGeneration(bootID: "B1"))
        #expect(Set(onDisk.entries.map(\.sessionId)) == ["a", "b", "c"])
        // and a fresh store (an app restart) sees the same thing
        let reopened = WorkspaceStore(directory: store.directory)
        try reopened.record(live: [], bootID: "B1", now: t0 + 400)
        #expect(reopened.loadGeneration(bootID: "B1")?.entries.count == 3)
    }

    @Test func aLoginWithNothingRunningKeepsThePreviousBoot() throws {
        let store = tempStore(keep: 1)
        try store.record(live: [entry("a")], bootID: "B1", now: t0)
        // several empty boots in a row must not push B1 out of the ring
        for boot in ["B2", "B3", "B4"] {
            #expect(try store.record(live: [], bootID: boot, now: t0 + 60) == false)
        }
        #expect(store.generations().map(\.bootID) == ["B1"])
    }

    @Test func theRingKeepsOnlyRecentBoots() throws {
        let store = tempStore(keep: 2)
        for (i, boot) in ["B1", "B2", "B3", "B4"].enumerated() {
            try store.record(live: [entry("s\(i)")], bootID: boot, now: t0 + Double(i) * 3600)
        }
        #expect(store.generations().map(\.bootID) == ["B4", "B3", "B2"])
    }

    @Test func lastSeenIsThrottledButFactChangesAreNot() throws {
        let store = tempStore()
        #expect(try store.record(live: [entry("a")], bootID: "B", now: t0))
        #expect(try store.record(live: [entry("a")], bootID: "B", now: t0 + 10) == false,
                "a reload every few seconds must not rewrite the file each time")
        #expect(try store.record(live: [entry("a")], bootID: "B", now: t0 + 61))
        #expect(try store.record(live: [entry("a", cwd: "/moved")], bootID: "B", now: t0 + 62))
        #expect(store.loadGeneration(bootID: "B")?.entries.first?.cwd == "/moved")
    }

    @Test func filesAreOwnerOnly() throws {
        let store = tempStore()
        try store.record(live: [entry("a")], bootID: "B", now: t0)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: store.generationURL("B").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unreadableFilesAreSkippedNotDeleted() throws {
        let store = tempStore()
        try store.record(live: [entry("a")], bootID: "B", now: t0)
        let junk = store.generationsDirectory.appendingPathComponent("future.json")
        try Data("{\"schemaVersion\": 99}".utf8).write(to: junk)
        #expect(store.generations().count == 1)
        try store.record(live: [entry("b")], bootID: "C", now: t0 + 60)
        #expect(FileManager.default.fileExists(atPath: junk.path))
    }

    @Test func bootIDsCannotEscapeTheDirectory() {
        let store = tempStore()
        #expect(store.generationURL("../../evil").deletingLastPathComponent()
                == store.generationsDirectory)
    }

    @Test func namedWorkspacesRoundTrip() throws {
        let store = tempStore()
        let a = NamedWorkspace(name: "givzey", savedAt: t0, entries: [entry("x")])
        let b = NamedWorkspace(name: "Personal", savedAt: t0, entries: [entry("y")])
        try store.save(a)
        try store.save(b)
        // a second save under the same name is a second workspace
        try store.save(NamedWorkspace(name: "givzey", savedAt: t0 + 1, entries: []))
        #expect(store.named().map(\.name) == ["givzey", "givzey", "Personal"])
        try store.deleteNamed(id: a.id)
        #expect(store.named().contains { $0.id == a.id } == false)
        #expect(store.named().first { $0.id == b.id } == b)
    }

    @Test func theCurrentBootIDIsReadable() {
        let id = WorkspaceStore.currentBootID()
        #expect(id != nil && !id!.isEmpty)
        #expect(WorkspaceStore.currentBootID() == id, "stable within a boot")
    }
}

struct WorkspaceRecoveryTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func seen(_ id: String, minutesAgo: Double) -> WorkspaceEntry {
        WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp",
                       lastSeen: t0.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func offersWhatWasRunningTogetherAtTheEnd() {
        let g = WorkspaceGeneration(bootID: "B", updatedAt: t0, entries: [
            seen("closed-this-morning", minutesAgo: 300),
            seen("shutdown-1", minutesAgo: 6),
            seen("shutdown-2", minutesAgo: 1),
            seen("shutdown-3", minutesAgo: 0),
        ])
        #expect(g.recentlyClosed(live: []).map(\.sessionId)
                == ["shutdown-1", "shutdown-2", "shutdown-3"])
        #expect(g.recentlyClosed(live: ["claude-shutdown-2"]).map(\.sessionId)
                == ["shutdown-1", "shutdown-3"], "running sessions aren't offered")
        #expect(WorkspaceGeneration(bootID: "E", updatedAt: t0).recentlyClosed(live: []).isEmpty)
    }
}

struct WorkspaceRestoreTests {
    let uuid = "0B6B5A5E-6C1B-4B6F-9C55-0B1F2E3D4C5A"

    func entry(_ id: String? = nil, cwd: String = "/tmp", provider: Provider = .claude,
               mode: String? = nil) -> WorkspaceEntry {
        WorkspaceEntry(provider: provider, sessionId: id ?? uuid, cwd: cwd,
                       permissionMode: mode, lastSeen: .distantPast)
    }

    func facts(live: Set<String> = [], inFlight: Set<String> = [],
               dirs: Set<String> = ["/tmp"], conversation: Bool? = true) -> WorkspaceRestore.Facts {
        .init(live: live, inFlight: inFlight,
              directoryExists: { dirs.contains($0) },
              conversationExists: { _ in conversation })
    }

    @Test func alwaysConstructsAResumeFromTheId() {
        #expect(WorkspaceRestore.commandLine(for: entry())
                == "cd -- '/tmp' && claude --resume 0b6b5a5e-6c1b-4b6f-9c55-0b1f2e3d4c5a")
        #expect(WorkspaceRestore.commandLine(for: entry(provider: .codex))
                == "cd -- '/tmp' && codex resume 0b6b5a5e-6c1b-4b6f-9c55-0b1f2e3d4c5a")
    }

    @Test func aNonUUIDIdIsRefusedNotSearched() {
        // `claude --resume <name>` is a search term and opens a picker;
        // anything else could be shell syntax
        for bad in ["", "Home-value", "x; rm -rf ~", "$(id)"] {
            #expect(WorkspaceRestore.commandLine(for: entry(bad)) == nil)
        }
        let plan = WorkspaceRestore.plan([entry("Home-value")], facts: facts())
        #expect(plan.launches.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.invalidSessionId])
    }

    @Test func onlyKnownPermissionModesPassThrough() {
        #expect(WorkspaceRestore.commandLine(for: entry(mode: "bypassPermissions"))?
                .hasSuffix(" --permission-mode bypassPermissions") == true)
        for mode in ["default", "plan; touch /tmp/x", "--evil"] {
            #expect(WorkspaceRestore.commandLine(for: entry(mode: mode))?
                    .contains("--permission-mode") == false, "\(mode)")
        }
    }

    @Test func quotingSurvivesARealShell() throws {
        // the only free text in the command; checked against /bin/zsh itself
        // rather than against what the quoting is supposed to produce
        let paths = ["/tmp/a b", "/tmp/it's", "/tmp/$HOME `id` $(id)", "/tmp/new\nline",
                     "/tmp/back\\slash", "/tmp/'''", "-rf"]
        for path in paths {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-fc", "printf %s \(WorkspaceRestore.shellQuote(path))"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let echoed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(echoed == path)
        }
    }

    @Test func preflightReportsEachProblemDistinctly() {
        let open = entry("11111111-1111-1111-1111-111111111111")
        let busy = entry("22222222-2222-2222-2222-222222222222")
        let gone = entry("33333333-3333-3333-3333-333333333333", cwd: "/deleted")
        let fine = entry("44444444-4444-4444-4444-444444444444")
        let plan = WorkspaceRestore.plan([open, busy, gone, fine, fine], facts: facts(
            live: [open.key], inFlight: [busy.key]))
        #expect(plan.launches.map(\.entry) == [fine], "duplicates launch once")
        #expect(plan.skipped.map(\.reason) == [.alreadyOpen, .alreadyRestoring, .missingDirectory])
        #expect(plan.skipSummary == "1 already open, 1 already restoring, 1 folder missing")

        let missing = WorkspaceRestore.plan([fine], facts: facts(conversation: false))
        #expect(missing.skipped.map(\.reason) == [.missingConversation])
        let unknown = WorkspaceRestore.plan([fine], facts: facts(conversation: nil))
        #expect(unknown.launches.count == 1, "no evidence is not evidence of absence")
    }

    @Test func executionReusesOneWindowAndTreatsTimeoutAsUncertain() {
        let a = entry("11111111-1111-1111-1111-111111111111")
        let b = entry("22222222-2222-2222-2222-222222222222")
        let c = entry("33333333-3333-3333-3333-333333333333")
        let d = entry("44444444-4444-4444-4444-444444444444")
        let launches = WorkspaceRestore.plan([a, b, c, d], facts: facts()).launches
        final class Calls: @unchecked Sendable { var windows: [String] = [] }
        let calls = Calls()
        let outcomes = WorkspaceRestore.execute(
            launches,
            stillWanted: { $0 != d },   // came up some other way meanwhile
            stagger: 0,
            run: { _, args in
                calls.windows.append(args[0])
                if args[1].contains("2222") { return .failure("timed out after 15s") }
                if args[1].contains("3333") { return .failure("iTerm got an error") }
                return .success("901")
            }
        )
        #expect(calls.windows == ["", "901", "901"])
        #expect(outcomes[a.key] == .launched)
        #expect(outcomes[b.key] == .uncertain)
        #expect(outcomes[c.key] == .failed("iTerm got an error"))
        #expect(outcomes[d.key] == nil, "re-checked right before launching")
    }

    @Test func theTimeoutWordingTheExecutorRecognisesIsTheRunnersOwn() {
        // execute() classifies by prefix; pin the runner's actual message
        let outcome = ITermFocus.runAppleScript("delay 3", timeout: 0.5)
        guard case .failure(let message) = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        #expect(message.hasPrefix("timed out"))
    }
}
