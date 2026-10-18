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

    @Test func theFinalSetIsWhatWasRunningTogetherAtTheEnd() {
        let g = WorkspaceGeneration(bootID: "B", updatedAt: t0, entries: [
            seen("closed-this-morning", minutesAgo: 300),
            seen("shutdown-1", minutesAgo: 4),
            seen("shutdown-2", minutesAgo: 1),
            seen("shutdown-3", minutesAgo: 0),
        ])
        #expect(g.finalSet().map(\.sessionId) == ["shutdown-1", "shutdown-2", "shutdown-3"])
        #expect(g.restoreSets(live: ["claude-shutdown-2"], finished: true).first?
                    .entries.map(\.sessionId) == ["shutdown-1", "shutdown-3"],
                "running sessions aren't offered")
        #expect(WorkspaceGeneration(bootID: "E", updatedAt: t0).finalSet().isEmpty)
    }
}

struct WorkspaceRecoveryEdgeTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func seen(_ id: String, minutesAgo: Double) -> WorkspaceEntry {
        WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp",
                       lastSeen: t0.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func aSlowShutdownChainsButAnEarlierCloseDoesNot() {
        // closures 3 minutes apart for 30 minutes all chain; one closed two
        // hours before that is a deliberate close, not part of the shutdown
        var entries = (0..<10).map { seen("s\($0)", minutesAgo: Double($0) * 3) }
        entries.append(seen("this-morning", minutesAgo: 150))
        let g = WorkspaceGeneration(bootID: "B", updatedAt: t0, entries: entries)
        let offered = Set(g.finalSet().map(\.sessionId))
        #expect(offered.count == 10)
        #expect(!offered.contains("this-morning"))
    }

    @Test func twoAppInstancesDoNotEraseEachOthersEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        let a = WorkspaceStore(directory: dir)
        let b = WorkspaceStore(directory: dir)
        let e = { (id: String) in
            WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp", lastSeen: .distantPast)
        }
        try a.record(live: (1...30).map { e("s\($0)") }, bootID: "B", now: t0)
        try b.record(live: [e("from-b")], bootID: "B", now: t0 + 10)
        // a's heartbeat, a minute later, from its stale in-memory copy
        try a.record(live: (1...30).map { e("s\($0)") }, bootID: "B", now: t0 + 70)
        let ids = Set(a.loadGeneration(bootID: "B")?.entries.map(\.sessionId) ?? [])
        #expect(ids.count == 31)
        #expect(ids.contains("from-b"))
    }
}

struct ClosedSetTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func e(_ id: String) -> WorkspaceEntry {
        WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp", lastSeen: .distantPast)
    }

    func tempStore() -> WorkspaceStore {
        WorkspaceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func aQuickSessionAfterAQuitDoesNotDisplaceTheQuit() throws {
        // quit iTerm with 30 open, test the new iTerm with one quick
        // session, close it twenty minutes later: the 30 are still offered
        let store = tempStore()
        let thirty = (1...30).map { e("s\($0)") }
        try store.record(live: thirty, bootID: "B", now: t0)
        try store.record(live: [], bootID: "B", now: t0 + 5)          // iTerm quit
        try store.record(live: [e("quick")], bootID: "B", now: t0 + 60)
        try store.record(live: [], bootID: "B", now: t0 + 20 * 60)
        let g = try #require(store.loadGeneration(bootID: "B"))
        let sets = g.restoreSets(live: [], finished: false)
        #expect(sets.map(\.entries.count) == [1, 30], "newest first, both kept")
    }

    @Test func aSlowQuitStillLandsInOneSet() throws {
        let store = tempStore()
        var live = (1...10).map { e("s\($0)") }
        try store.record(live: live, bootID: "B", now: t0)
        for i in 1...10 {   // one closes every 2 minutes, for 20 minutes
            live.removeFirst()
            try store.record(live: live, bootID: "B", now: t0 + Double(i) * 120)
        }
        let g = try #require(store.loadGeneration(bootID: "B"))
        #expect(g.closedSets.count == 1)
        #expect(g.closedSets.first?.keys.count == 10)
    }

    @Test func restoringPartOfASetKeepsTheRestOffered() {
        // the bridge case: members closed at 0, 4 and 8 minutes; restoring
        // the middle one must not split the other two apart
        let set = ClosedSet(closedAt: t0, keys: ["claude-a", "claude-b", "claude-c"])
        let g = WorkspaceGeneration(bootID: "B", updatedAt: t0,
                                    entries: [e("a"), e("b"), e("c")], closedSets: [set])
        #expect(g.restoreSets(live: ["claude-b"], finished: false).first?.entries.map(\.sessionId)
                == ["a", "c"])
    }

    @Test func aFinishedBootOffersWhatWasRunningAtTheEndEvenWithoutASet() {
        // AgentDeck quit before iTerm at logout: no closure was observed,
        // but every entry's sighting froze when the boot ended
        func seen(_ id: String, minutesAgo: Double) -> WorkspaceEntry {
            WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp",
                           lastSeen: t0.addingTimeInterval(-minutesAgo * 60))
        }
        let g = WorkspaceGeneration(bootID: "B", updatedAt: t0, entries: [
            seen("this-morning", minutesAgo: 300), seen("a", minutesAgo: 1), seen("b", minutesAgo: 0),
        ])
        let sets = g.restoreSets(live: [], finished: true)
        #expect(sets.first.map { Set($0.entries.map(\.sessionId)) } == ["a", "b"])
        // restoring all of it doesn't promote the deliberate close into its place
        #expect(g.restoreSets(live: ["claude-a", "claude-b"], finished: true).isEmpty)
        #expect(g.restoreSets(live: [], finished: false).isEmpty, "a running boot has no final set")
    }

    @Test func aFreshProcessDoesNotMistakeItsStartForClosures() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        try WorkspaceStore(directory: dir).record(live: [e("a"), e("b")], bootID: "B", now: t0)
        // app restarted; the first call it makes only sets a baseline
        let restarted = WorkspaceStore(directory: dir)
        try restarted.record(live: [e("a")], bootID: "B", now: t0 + 60)
        #expect(restarted.loadGeneration(bootID: "B")?.closedSets.isEmpty == true)
        try restarted.record(live: [], bootID: "B", now: t0 + 120)
        #expect(restarted.loadGeneration(bootID: "B")?.closedSets.map(\.keys) == [["claude-a"]])
    }

    @Test func oldFilesWithoutClosedSetsStillLoad() throws {
        let json = #"{"schemaVersion":1,"bootID":"B","updatedAt":"2026-10-17T15:00:44.191Z","entries":[]}"#
        let g = try SnapshotStore.decoder().decode(WorkspaceGeneration.self, from: Data(json.utf8))
        #expect(g.closedSets.isEmpty)
    }

    @Test func concurrentWritersLoseNothing() throws {
        // two instances writing at the same time, not one after the other —
        // the earlier test only proved the merge, and passed with the lock
        // removed
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        let start = t0
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            let store = WorkspaceStore(directory: dir)
            var mine: [WorkspaceEntry] = []
            for i in 0..<40 {
                mine.append(WorkspaceEntry(provider: .claude, sessionId: "w\(worker)-\(i)",
                                           cwd: "/tmp", lastSeen: .distantPast))
                try? store.record(live: mine, bootID: "B", now: start + Double(i))
            }
        }
        let ids = WorkspaceStore(directory: dir).loadGeneration(bootID: "B")?.entries.map(\.sessionId) ?? []
        #expect(ids.count == 80)
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

    @Test func idsAreCanonicalBeforeAnyCheck() {
        let upper = entry("0B6B5A5E-6C1B-4B6F-9C55-0B1F2E3D4C5A")
        let lower = entry("0b6b5a5e-6c1b-4b6f-9c55-0b1f2e3d4c5a")
        let both = WorkspaceRestore.plan([upper, lower], facts: facts())
        #expect(both.launches.count == 1, "one conversation, one launch")
        // the registry reports lowercase ids; an uppercase entry is still open
        let open = WorkspaceRestore.plan([upper], facts: facts(live: [lower.key]))
        #expect(open.skipped.map(\.reason) == [.alreadyOpen])
    }

    @Test func pathsThatCannotBeTypedSafelyAreRefused() {
        // typed into a terminal, a control character is a keystroke: Ctrl-U
        // would erase the quoted prefix and leave the rest to run
        for bad in ["/tmp/x\u{15}touch /tmp/pwned", "/tmp/a\u{1B}[B", "/tmp/new\nline", "relative/dir"] {
            #expect(WorkspaceRestore.commandLine(for: entry(cwd: bad)) == nil, "\(bad.debugDescription)")
            let plan = WorkspaceRestore.plan([entry(cwd: bad)], facts: facts(dirs: [bad]))
            #expect(plan.skipped.map(\.reason) == [.unusableDirectory])
        }
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
        #expect(WorkspaceRestore.describeSkips(plan.skipped)
                == "Skipped: tmp (already open); tmp (already restoring); deleted (folder missing).")

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
        let e = entry("55555555-5555-5555-5555-555555555555")
        let launches = WorkspaceRestore.plan([a, b, c, d, e], facts: facts()).launches
        final class Calls: @unchecked Sendable { var windows: [String] = [] }
        let calls = Calls()
        let outcomes = WorkspaceRestore.execute(
            launches,
            stillWanted: { $0 != d },   // came up some other way meanwhile
            stagger: 0,
            run: { script, args, _ in
                if script == WorkspaceRestore.readyScript { return .success("3") }
                calls.windows.append(args[0])
                if args[1].contains("2222") { return .failure("timed out after 15s") }
                if args[1].contains("3333") { return .failure("iTerm got an error") }
                if args[1].contains("5555") {
                    return .failure("Not authorized to send Apple events to iTerm. (-1743)")
                }
                return .success("901")
            }
        )
        #expect(calls.windows == ["", "901", "901", "901"])
        #expect(outcomes[e.key] == .failed("Not authorized to send Apple events to iTerm. (-1743)"),
                "refused before anything happened, so it is safe to retry")
        #expect(outcomes[a.key] == .launched)
        #expect(outcomes[b.key] == .uncertain("timed out after 15s"))
        #expect(outcomes[c.key] == .uncertain("iTerm got an error"),
                "an error after the script started may follow a pane being created")
        #expect(outcomes[d.key] == nil, "re-checked right before launching")
    }

    @Test func nothingIsTypedUntilITermAnswers() {
        // a cold iTerm start can outlast a launch timeout; if the readiness
        // check fails, nothing was typed anywhere, so every launch is
        // reported as safely retryable and no launch script runs
        let launches = WorkspaceRestore.plan(
            [entry("11111111-1111-1111-1111-111111111111"),
             entry("22222222-2222-2222-2222-222222222222")], facts: facts()).launches
        final class Calls: @unchecked Sendable { var scripts: [String] = [] }
        let calls = Calls()
        let outcomes = WorkspaceRestore.execute(
            launches, stillWanted: { _ in true }, stagger: 0,
            run: { script, _, _ in
                calls.scripts.append(script)
                return .failure("timed out after 60s (Automation permission dialog unanswered?)")
            })
        #expect(calls.scripts == [WorkspaceRestore.readyScript])
        #expect(outcomes.values.allSatisfy {
            if case .failed = $0 { return true } else { return false }
        })
        #expect(outcomes.count == 2)
    }

    @Test func launchesWaitBetweenBatches() {
        let ids = (1...12).map { String(format: "%08d-0000-4000-8000-000000000000", $0) }
        let launches = WorkspaceRestore.plan(ids.map { entry($0) }, facts: facts()).launches
        final class Log: @unchecked Sendable { var events: [String] = [] }
        let log = Log()
        _ = WorkspaceRestore.execute(
            launches, stillWanted: { _ in true }, batchSize: 5, stagger: 0,
            run: { script, _, _ in
                if script != WorkspaceRestore.readyScript { log.events.append("L") }
                return .success("1")
            },
            awaitBatch: { log.events.append("wait\($0.count)") })
        #expect(log.events.joined(separator: " ")
                == "L L L L L wait5 L L L L L wait5 L L", "no pointless wait after the last")
    }

    @Test func onlyOsascriptsOwnCodesMeanNothingHappened() {
        #expect(WorkspaceRestore.failedBeforeAnySideEffect(
            "execution error: Not authorized to send Apple events to iTerm2. (-1743)"))
        #expect(WorkspaceRestore.failedBeforeAnySideEffect(
            "execution error: Application isn’t running. (-600)"))
        // a bare number elsewhere in the text must not make it retryable
        #expect(!WorkspaceRestore.failedBeforeAnySideEffect("window id -600 not allowed"))
        #expect(!WorkspaceRestore.failedBeforeAnySideEffect("Invalid index. (-1719)"))
    }

    @Test func theTimeoutWordingTheExecutorRecognisesIsTheRunnersOwn() {
        // execute() words a readiness timeout by this prefix; pin the
        // runner's actual message
        let outcome = ITermFocus.runAppleScript("delay 3", timeout: 0.5)
        guard case .failure(let message) = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        #expect(message.hasPrefix("timed out"))
    }
}
