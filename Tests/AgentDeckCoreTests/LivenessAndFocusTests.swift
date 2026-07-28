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

    @Test func launchdIsAliveEvenThoughNotOurs() {
        #expect(Liveness.isAlive(pid: 1), "pid 1 exists; EPERM must count as alive")
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
        let removed = Set(Liveness.keysToRemove(snaps, now: now))
        #expect(removed == ["claude-dead", "codex-stale-nopid"])
    }

    @Test func revealURLExtractsGuidPart() {
        let url = ITermFocus.revealURL(
            terminalSessionId: "w0t2p1:9E223F41-B4B0-4A5C-ABCD-000000000000"
        )
        #expect(
            url?.absoluteString
                == "iterm2:///reveal?sessionid=9E223F41-B4B0-4A5C-ABCD-000000000000"
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
                == "iterm2:///reveal?sessionid=has%20space%26x%3D1"
        )
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
