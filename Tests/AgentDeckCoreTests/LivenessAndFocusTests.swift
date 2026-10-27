import Darwin
import Foundation
import Testing
@testable import AgentDeckCore

struct LivenessAndFocusTests {
    func exitedProcessPid() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    @Test func currentProcessIsAlive() {
        #expect(Liveness.isAlive(pid: getpid()))
    }

    @Test func anotherUsersProcessCountsAsDead() {
        // pid 1 (root launchd) exists but is not ours; claude/codex always
        // run as the current user, so EPERM means a recycled pid — dead
        #expect(!Liveness.isAlive(pid: 1))
    }

    @Test func exitedProcessIsDead() throws {
        #expect(!Liveness.isAlive(pid: try exitedProcessPid()))
    }

    @Test func invalidPidsAreDead() {
        #expect(!Liveness.isAlive(pid: 0))
        #expect(!Liveness.isAlive(pid: -5))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A probe where each pid has an explicit start time (nil = dead).
    func probe(_ starts: [Int32: Date]) -> Liveness.ProcessProbe {
        Liveness.ProcessProbe { starts[$0] }
    }

    func snap(_ id: String, pid: Int32?, updated: Date, state: SessionState = .working)
        -> SessionSnapshot
    {
        SessionSnapshot(
            provider: .claude, sessionId: id, projectPath: "/",
            state: state, event: "x", updatedAt: updated, agentPid: pid
        )
    }

    @Test func aConfirmedLiveSessionKeepsItsSnapshot() {
        // Aging out a snapshot whose session is demonstrably still running
        // no longer hides it — discovery re-adds the row — but it strips
        // the pane id and hook state, so the row silently stops being
        // clickable. The downgrade is invisible: same key, same position,
        // acks intact.
        let stale = snap("s", pid: nil, updated: now.addingTimeInterval(-48 * 3600))
        #expect(Liveness.keysToRemove([stale], now: now, bootedAt: nil,
                                      probe: probe([:])) == ["claude-s"])
        #expect(Liveness.keysToRemove([stale], now: now, bootedAt: nil,
                                      confirmedLive: ["claude-s"],
                                      probe: probe([:])).isEmpty)
        // a different session being live protects nothing
        #expect(Liveness.keysToRemove([stale], now: now, bootedAt: nil,
                                      confirmedLive: ["claude-other"],
                                      probe: probe([:])) == ["claude-s"])
    }

    @Test func confirmationDoesNotProtectCodexRows() {
        // the registry is Claude's; a Codex session id must not be
        // protected by a same-named Claude entry
        let codex = SessionSnapshot(
            provider: .codex, sessionId: "s", projectPath: "/",
            state: .working, event: "x",
            updatedAt: now.addingTimeInterval(-48 * 3600)
        )
        #expect(Liveness.keysToRemove([codex], now: now, bootedAt: nil,
                                      confirmedLive: ["claude-s"],
                                      probe: probe([:])) == ["codex-s"])
        // evidence keyed to the Codex session itself does protect it
        #expect(Liveness.keysToRemove([codex], now: now, bootedAt: nil,
                                      confirmedLive: ["codex-s"],
                                      probe: probe([:])).isEmpty)
    }

    @Test func keysToRemoveByIdentityAndIdle() {
        let live = snap("alive", pid: 100, updated: now)               // started before update
        let dead = snap("dead", pid: 200, updated: now)                // no start time
        let freshNoPid = snap("fresh-nopid", pid: nil, updated: now)
        let staleNoPid = snap("stale-nopid", pid: nil,
                              updated: now.addingTimeInterval(-48 * 3600))
        let starts: [Int32: Date] = [100: now.addingTimeInterval(-600)]
        let removed = Set(Liveness.keysToRemove(
            [live, dead, freshNoPid, staleNoPid],
            now: now, bootedAt: nil, probe: probe(starts)
        ))
        #expect(removed == ["claude-dead", "claude-stale-nopid"])
    }

    @Test func recycledPidIsDetectedByStartTime() {
        // the exact hazard the boot guard used to (imperfectly) cover: pid is
        // ALIVE, but its process started AFTER the snapshot recorded it — so
        // it's a different process that reused the number.
        let s = snap("recycled", pid: 100, updated: now.addingTimeInterval(-3600),
                     state: .waiting)
        let reused = probe([100: now.addingTimeInterval(-60)])  // started 59 min later
        #expect(Liveness.keysToRemove([s], now: now, bootedAt: nil, probe: reused)
            == ["claude-recycled"])
        // same pid, original process (started before the snapshot) survives
        let original = probe([100: now.addingTimeInterval(-7200)])
        #expect(Liveness.keysToRemove([s], now: now, bootedAt: nil, probe: original).isEmpty)
    }

    @Test func loginItemRaceSurvivesClockDrift() {
        // Regression for the KERN_BOOTTIME false-delete: a session started
        // right after login has updatedAt ≈ boot; a forward clock drift used
        // to delete it. Identity (start time ≤ update) has no such failure.
        let s = snap("login", pid: 100, updated: now, state: .waiting)
        let startedAtLogin = probe([100: now.addingTimeInterval(-5)])  // 5s before first hook
        // even with bootedAt drifted forward PAST the snapshot, the live,
        // identity-verified pid keeps the session
        #expect(Liveness.keysToRemove(
            [s], now: now, bootedAt: now.addingTimeInterval(30), probe: startedAtLogin
        ).isEmpty)
    }

    @Test func liveSessionSurvivesTheIdleCapThatKillsPidlessOnes() {
        // A session BLOCKED on the user emits no events; it must not be
        // deleted for going quiet. Its pid started long ago (before the
        // 30h-old update), so identity holds.
        let live = snap("live", pid: 100, updated: now.addingTimeInterval(-30 * 3600),
                        state: .waiting)
        let pidless = snap("pidless", pid: nil,
                           updated: now.addingTimeInterval(-30 * 3600), state: .waiting)
        let starts = probe([100: now.addingTimeInterval(-40 * 3600)])
        let removed = Set(Liveness.keysToRemove(
            [live, pidless], now: now, bootedAt: nil, probe: starts))
        #expect(removed == ["claude-pidless"], "a live waiting session must survive")
    }

    @Test func aVerifiedLiveAgentIsNotExpiredForBeingQuiet() {
        // Codex has no registry to vouch for it: a session waiting for input
        // over a long weekend used to lose its row at seven days, and then
        // be offered for restore while still running
        var quiet = snap("quiet", pid: 100,
                         updated: now.addingTimeInterval(-8 * 24 * 3600), state: .waiting)
        quiet.provider = .codex
        let starts = probe([100: now.addingTimeInterval(-9 * 24 * 3600)])
        #expect(Liveness.keysToRemove([quiet], now: now, bootedAt: nil, probe: starts).isEmpty)
    }

    @Test func aClearedConversationsRowGoesOnceTheRegistryNamesTheNewOne() {
        // /clear: the process runs on as session B; A's snapshot still
        // carries the pid, which is alive and is claude, so nothing else
        // would ever remove it
        let old = snap("A", pid: 100, updated: now.addingTimeInterval(-300), state: .done)
        let fresh = snap("B", pid: 100, updated: now.addingTimeInterval(-5), state: .ready)
        let registryB = ClaudeSessionRegistry.Entry(
            pid: 100, sessionId: "B", status: "idle", statusUpdatedAt: now.addingTimeInterval(-60))
        let starts = probe([100: now.addingTimeInterval(-3600)])
        let removed = Liveness.keysToRemove([old, fresh], now: now, bootedAt: nil,
                                            liveByPid: [100: registryB], probe: starts)
        #expect(removed == ["claude-A"])
        // a new session's first hook can beat its registry rewrite: B is
        // kept even while the registry still names A
        let registryA = ClaudeSessionRegistry.Entry(
            pid: 100, sessionId: "A", status: "idle", statusUpdatedAt: now.addingTimeInterval(-60))
        #expect(Liveness.keysToRemove([fresh], now: now, bootedAt: nil,
                                      liveByPid: [100: registryA], probe: starts).isEmpty)
    }

    @Test func aLivePidThatIsNotTheAgentIsRemoved() {
        // started in time, so the start-time check alone would accept it
        let reused = snap("reused", pid: 100, updated: now.addingTimeInterval(-60), state: .done)
        let notAgent = Liveness.ProcessProbe(
            startTime: { _ in self.now.addingTimeInterval(-30) },
            isAgent: { _, _ in false })
        #expect(Liveness.keysToRemove([reused], now: now, bootedAt: nil, probe: notAgent)
                == ["claude-reused"])
    }

    @Test func systemProbeReadsRealStartTimes() {
        // the real probe: our own process is alive with a start time in the past
        #expect(Liveness.ProcessProbe.system.startTime(getpid()) != nil)
        #expect(Liveness.ProcessProbe.system.startTime(0) == nil)
    }

    @Test func bootTimeIsSane() throws {
        let boot = try #require(Liveness.bootTime())
        #expect(boot < Date())
        #expect(boot > Date(timeIntervalSince1970: 0))
    }

    @Test func revealURLKeepsFullSessionIdWithEncodedColon() {
        // regression: a bare GUID is silently ignored by iTerm — the full
        // "wXtYpZ:GUID" form (colon percent-encoded) is what focuses a pane
        let url = ITermFocus.revealURL(
            terminalSessionId: "w0t2p1:9E223F41-B4B0-4A5C-ABCD-000000000000"
        )
        #expect(
            url?.absoluteString
                == "iterm2:///reveal?sessionid=w0t2p1%3A9E223F41-B4B0-4A5C-ABCD-000000000000"
        )
    }

    @Test func revealURLWithBareGuid() {
        #expect(
            ITermFocus.revealURL(terminalSessionId: "ABC-123")?.absoluteString
                == "iterm2:///reveal?sessionid=ABC-123"
        )
    }

    @Test func revealURLEncodesUnexpectedCharacters() {
        #expect(
            ITermFocus.revealURL(terminalSessionId: "w0:has space&x=1")?.absoluteString
                == "iterm2:///reveal?sessionid=w0%3Ahas%20space%26x%3D1"
        )
    }

    @Test func sanitizeTitleDropsOnlyUnbalancedQuotes() {
        // codex-cli emits a stray quote in its terminal title; the provider
        // suffix is then stripped too (see sanitizeTitleStripsDuplicatedDecoration)
        #expect(ITermFocus.sanitizeTitle("Code (codex\")") == "Code")
        #expect(ITermFocus.sanitizeTitle("knowledge (codex\")") == "knowledge")
        // balanced quotes are intentional — keep them
        #expect(ITermFocus.sanitizeTitle("run \"make test\"") == "run \"make test\"")
        #expect(ITermFocus.sanitizeTitle("  padded  ") == "padded")
    }

    @Test func sanitizeTitleStripsDuplicatedDecoration() {
        // the row already shows provider + state; the glyph and "(claude)"
        // suffix just push every title right and waste ~90pt of a 360pt row
        #expect(ITermFocus.sanitizeTitle("✳ V2B-1488 (claude)") == "V2B-1488")
        #expect(ITermFocus.sanitizeTitle("⠂ AgentDeck (sourcekit-lsp)")
            == "AgentDeck (sourcekit-lsp)", "only provider suffixes are dropped")
        #expect(ITermFocus.sanitizeTitle("Code (codex\")") == "Code")
        #expect(ITermFocus.sanitizeTitle("plain title") == "plain title")
        #expect(ITermFocus.sanitizeTitle("✳ ") == "")
    }

    @Test func humanizeReasonReadsLikeEnglish() {
        #expect(ITermFocus.humanizeReason("permission_prompt") == "needs permission")
        #expect(ITermFocus.humanizeReason("idle_prompt") == "idle")
        #expect(ITermFocus.humanizeReason("agent_needs_input") == "subagent needs input")
        #expect(ITermFocus.humanizeReason("elicitation_dialog") == "needs input")
        #expect(ITermFocus.humanizeReason("sandbox request") == "sandbox request")
        #expect(ITermFocus.humanizeReason("something_new") == "something new")
    }

    @Test func parseSessionNamesSanitizesTitles() {
        let names = ITermFocus.parseSessionNames("GUID-1\t/dev/ttys001\tCode (codex\")")
        #expect(names["GUID-1"] == "Code")
    }

    @Test func parseSessionNamesHandlesRealAndMalformedLines() {
        let output = """
        C4EB7622-AAAA\t/dev/ttys000\t✳ infra (claude)
        B4F41D67-BBBB\t/dev/ttys001\t⠂ Claude-session-watcher (caffeinate)
        no-tab-in-this-line
        \t/dev/ttys002\tname-without-guid
        GUID-ONLY\t\t
        """
        let names = ITermFocus.parseSessionNames(output)
        #expect(names == [
            "C4EB7622-AAAA": "infra",
            "B4F41D67-BBBB": "Claude-session-watcher (caffeinate)",
        ])
        #expect(ITermFocus.parseSessionNames("").isEmpty)
    }

    @Test func sessionListMapsTTYsToPanes() {
        // a title containing a tab must not shift the fields
        let list = ITermFocus.parseSessionList(
            "G-1\t/dev/ttys018\twith\ttab\nG-2\t/dev/ttys030\t\nG-3\t\tno tty\n"
        )
        #expect(list.guidByTTY == ["ttys018": "G-1", "ttys030": "G-2"])
        #expect(list.names["G-1"] == "with\ttab")
        #expect(list.names["G-2"] == nil, "an empty title is still a pane")
        #expect(list.names["G-3"] == "no tty")
    }

    @Test func argumentsAreSearchedButNotTheEnvironment() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        child.environment = ["MARKER": "claude-in-the-environment"]
        try child.run()
        defer { child.terminate() }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(ProcessTree.argumentsMention("5", pid: child.processIdentifier))
        #expect(!ProcessTree.argumentsMention("claude", pid: child.processIdentifier),
                "only arguments count; an env var mentioning claude must not")
        #expect(!ProcessTree.looksLikeAgent(child.processIdentifier, provider: .claude))
    }

    @Test func aRunningCodexIsFoundByTheThreadIdInItsArguments() throws {
        // a fake "codex" (a compiled sleeper named codex) started the way a
        // restore starts one: `codex resume <id>`
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codexprobe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("s.c"), bin = dir.appendingPathComponent("codex")
        try "#include <unistd.h>\nint main(void){sleep(20);return 0;}\n"
            .write(to: src, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [src.path, "-o", bin.path]
        try cc.run(); cc.waitUntilExit()
        try #require(cc.terminationStatus == 0)
        let id = "01a1abcd-1234-7000-8000-00000000beef"
        let p = Process()
        p.executableURL = bin
        p.arguments = ["resume", id]
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(ProcessTree.codexThreadsRunning([id, "01a1abcd-0000-7000-8000-000000000000"]) == [id])
        #expect(ProcessTree.codexThreadsRunning([id.uppercased()]) == [id], "ids compared case-insensitively")
        p.terminate(); p.waitUntilExit()
        #expect(ProcessTree.codexThreadsRunning([id]).isEmpty, "gone once it exits")
    }

    @Test func aProcessOnATerminalHasItsTTYRead() throws {
        // `script` runs its child on a fresh pseudo-terminal, so this works
        // with or without one for the test runner itself (CI has none) —
        // and an implementation that always returned nil now fails
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        script.arguments = ["-q", "/dev/null", "/bin/sleep", "5"]
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        try script.run()
        defer { script.terminate() }
        var child: Int32?
        let deadline = Date().addingTimeInterval(3)
        while child == nil, Date() < deadline {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", String(script.processIdentifier), "sleep"]
            let out = Pipe()
            pgrep.standardOutput = out
            try pgrep.run()
            pgrep.waitUntilExit()
            child = Int32(String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            if child == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        let pid = try #require(child, "script's child never appeared")
        let tty = try #require(ProcessTree.controllingTTY(of: pid))
        #expect(tty.hasPrefix("tty"))
        #expect(ProcessTree.controllingTTY(of: -1) == nil)
    }

    @Test func sessionGUIDExtraction() {
        #expect(ITermFocus.sessionGUID(from: "w0t2p1:ABC-123") == "ABC-123")
        #expect(ITermFocus.sessionGUID(from: "ABC-123") == "ABC-123")
        #expect(ITermFocus.sessionGUID(from: "w0t0p0:") == nil)
        #expect(ITermFocus.sessionGUID(from: "") == nil)
        #expect(ITermFocus.sessionGUID(from: nil) == nil)
    }

    @Test func revealURLNilForEmptyInputs() {
        #expect(ITermFocus.revealURL(terminalSessionId: nil) == nil)
        #expect(ITermFocus.revealURL(terminalSessionId: "") == nil)
        #expect(ITermFocus.revealURL(terminalSessionId: "w0t0p0:") == nil)
    }

    @Test func processTreeResolvesOwnAncestry() throws {
        let info = try #require(ProcessTree.nameAndParent(of: getpid()))
        #expect(!info.name.isEmpty)
    }

    @Test func launchPathReadsArgvZero() throws {
        let own = try #require(ProcessTree.launchPath(of: getpid()))
        #expect(own.hasPrefix("/"))
        // a pid that cannot exist has no argv
        #expect(ProcessTree.launchPath(of: 0) == nil)
    }

    @Test func executablePathSurvivesTheBinaryBeingDeleted() throws {
        // The real condition, not a hypothetical: Claude Code installs each
        // release as `versions/<version>` and prunes old ones on update, so
        // a long-running session executes a binary that no longer exists
        // and proc_pidpath returns ENOENT. Losing the path loses pid
        // attribution, which drops the snapshot from the 7-day live cap to
        // the 24-hour idle one — deleting exactly the sessions worth
        // keeping. Observed live on a session running since July.
        //
        // The fixture is compiled here rather than copied from /bin. A copy
        // of a system binary is SIGKILLed within a fraction of a second of
        // starting, and the test only ever passed by reading the path
        // before the kill landed — about four runs in five.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("agentdeck-fixture-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("sleeper.c")
        let copy = dir.appendingPathComponent("sleeper")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [source.path, "-o", copy.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0, "couldn't compile the fixture")

        let child = Process()
        child.executableURL = copy
        try child.run()
        defer { child.terminate() }

        // Delete only once the child is past startup: unlinking an
        // executable while its process is still starting can get it
        // SIGKILLed (measured: 13 of 20 died when deleted immediately, none
        // after 300ms). Production prunes a binary hours into a session.
        var buf = [CChar](repeating: 0, count: 4096)
        let execDeadline = Date().addingTimeInterval(2)
        while proc_pidpath(child.processIdentifier, &buf, UInt32(buf.count)) <= 0,
              Date() < execDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.3)
        try #require(child.isRunning,
                     "the fixture process died before its binary was deleted")

        try fm.removeItem(at: copy)   // the update that prunes the old build
        #expect(!fm.fileExists(atPath: copy.path))

        let resolved = ProcessTree.executablePath(of: child.processIdentifier)
        #expect(resolved != nil, "a deleted binary must not cost us the pid")
        #expect(resolved?.hasSuffix(copy.lastPathComponent) == true)
    }
}
