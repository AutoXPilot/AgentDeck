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

    @Test func maxIdleAppliesEvenToLivePids() {
        // same-user pid reuse is undetectable by probing; the idle cap is
        // the backstop that keeps zombies from being immortal
        let now = Date()
        let snap = SessionSnapshot(
            provider: .claude, sessionId: "idle", projectPath: "/",
            state: .done, event: "x",
            updatedAt: now.addingTimeInterval(-25 * 3600), agentPid: getpid()
        )
        #expect(Liveness.keysToRemove([snap], now: now, bootedAt: nil) == ["claude-idle"])
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
