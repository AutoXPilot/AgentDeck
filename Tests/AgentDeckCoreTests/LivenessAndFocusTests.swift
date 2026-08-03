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

    @Test func keysToRemove() throws {
        let deadPid = try exitedProcessPid()
        let now = Date()
        let snaps = [
            SessionSnapshot(provider: .claude, sessionId: "alive", projectPath: "/",
                            state: .working, event: "x", agentPid: getpid()),
            SessionSnapshot(provider: .claude, sessionId: "dead", projectPath: "/",
                            state: .working, event: "x", agentPid: deadPid),
            SessionSnapshot(provider: .codex, sessionId: "fresh-nopid", projectPath: "/",
                            state: .done, event: "x", updatedAt: now),
            SessionSnapshot(provider: .codex, sessionId: "stale-nopid", projectPath: "/",
                            state: .done, event: "x",
                            updatedAt: now.addingTimeInterval(-48 * 3600)),
        ]
        let removed = Set(Liveness.keysToRemove(snaps, now: now, bootedAt: nil))
        #expect(removed == ["claude-dead", "codex-stale-nopid"])
    }

    @Test func snapshotsFromBeforeBootAreRemovedEvenWithLivePid() {
        let now = Date()
        let snap = SessionSnapshot(
            provider: .claude, sessionId: "preboot", projectPath: "/",
            state: .waiting, event: "x",
            updatedAt: now.addingTimeInterval(-3600), agentPid: getpid()
        )
        // pid is alive (it's us) but the snapshot predates boot: pid recycled
        let removed = Liveness.keysToRemove(
            [snap], now: now, bootedAt: now.addingTimeInterval(-60)
        )
        #expect(removed == ["claude-preboot"])
        // and kept when it postdates boot
        #expect(Liveness.keysToRemove(
            [snap], now: now, bootedAt: now.addingTimeInterval(-7200)
        ).isEmpty)
    }

    @Test func liveSessionSurvivesTheIdleCapThatKillsPidlessOnes() {
        // Regression for a production bug: a session BLOCKED on the user
        // emits no events at all, so the 24h idle cap deleted live sessions
        // (5 of them, verified on a real machine) and they could never
        // return. Live pids now get the long backstop instead.
        let now = Date()
        func snapshot(id: String, pid: Int32?, hoursOld: Double) -> SessionSnapshot {
            SessionSnapshot(
                provider: .claude, sessionId: id, projectPath: "/",
                state: .waiting, event: "x",
                updatedAt: now.addingTimeInterval(-hoursOld * 3600), agentPid: pid
            )
        }
        let live = snapshot(id: "live", pid: getpid(), hoursOld: 30)
        let pidless = snapshot(id: "pidless", pid: nil, hoursOld: 30)
        let removed = Set(Liveness.keysToRemove([live, pidless], now: now, bootedAt: nil))
        #expect(removed == ["claude-pidless"], "a live waiting session must survive")
    }

    @Test func livePidsStillExpireAtTheLongBackstop() {
        // same-user pid reuse is undetectable by probing, so the cap still
        // exists — just far beyond any plausible wait
        let now = Date()
        let ancient = SessionSnapshot(
            provider: .claude, sessionId: "ancient", projectPath: "/",
            state: .done, event: "x",
            updatedAt: now.addingTimeInterval(-8 * 24 * 3600), agentPid: getpid()
        )
        #expect(Liveness.keysToRemove([ancient], now: now, bootedAt: nil) == ["claude-ancient"])
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
        // codex-cli emits a stray quote in its terminal title
        #expect(ITermFocus.sanitizeTitle("Code (codex\")") == "Code (codex)")
        #expect(ITermFocus.sanitizeTitle("knowledge (codex\")") == "knowledge (codex)")
        // balanced quotes are intentional — keep them
        #expect(ITermFocus.sanitizeTitle("run \"make test\"") == "run \"make test\"")
        #expect(ITermFocus.sanitizeTitle("✳ V2B-1488 (claude)") == "✳ V2B-1488 (claude)")
        #expect(ITermFocus.sanitizeTitle("  padded  ") == "padded")
    }

    @Test func parseSessionNamesSanitizesTitles() {
        let names = ITermFocus.parseSessionNames("GUID-1\tCode (codex\")")
        #expect(names["GUID-1"] == "Code (codex)")
    }

    @Test func parseSessionNamesHandlesRealAndMalformedLines() {
        let output = """
        C4EB7622-AAAA\t✳ infra (claude)
        B4F41D67-BBBB\t⠂ Claude-session-watcher (caffeinate)
        no-tab-in-this-line
        \tname-without-guid
        GUID-ONLY\t
        """
        let names = ITermFocus.parseSessionNames(output)
        #expect(names == [
            "C4EB7622-AAAA": "✳ infra (claude)",
            "B4F41D67-BBBB": "⠂ Claude-session-watcher (caffeinate)",
        ])
        #expect(ITermFocus.parseSessionNames("").isEmpty)
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
}
