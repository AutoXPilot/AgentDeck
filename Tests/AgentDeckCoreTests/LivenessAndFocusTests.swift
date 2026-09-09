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

    @Test func livePidsStillExpireAtTheLongBackstop() {
        let ancient = snap("ancient", pid: 100,
                           updated: now.addingTimeInterval(-8 * 24 * 3600), state: .done)
        let starts = probe([100: now.addingTimeInterval(-9 * 24 * 3600)])
        #expect(Liveness.keysToRemove([ancient], now: now, bootedAt: nil, probe: starts)
            == ["claude-ancient"])
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
        let names = ITermFocus.parseSessionNames("GUID-1\tCode (codex\")")
        #expect(names["GUID-1"] == "Code")
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
            "C4EB7622-AAAA": "infra",
            "B4F41D67-BBBB": "Claude-session-watcher (caffeinate)",
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
