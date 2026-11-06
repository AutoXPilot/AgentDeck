import Darwin
import Foundation
import Testing
@testable import AgentDeckCore

/// Real-process tests for the ancestor walk. Note the tests themselves run
/// UNDER a claude session in development, so assertions compare against the
/// exact spawned pid — an ambient claude ancestor further up the chain would
/// yield a different pid and fail the test if path matching broke.
final class AncestorTests {
    /// A sleeper named like the agent — matching must key off the executable
    /// *path* because claude's p_comm is its version number (the binary is
    /// ~/.local/share/claude/versions/2.1.220).
    func spawnMimic(named name: String) throws -> Process {
        let p = Process()
        p.executableURL = try ProcessFixtures.sleeper(named: name)
        try p.run()
        return p
    }

    @Test func findsClaudeByExecutablePath() throws {
        let p = try spawnMimic(named: "claude")
        defer { p.terminate() }
        let found = ProcessTree.findAgentAncestor(
            provider: .claude, startingAt: p.processIdentifier
        )
        #expect(found == p.processIdentifier)
    }

    @Test func findsCodexByExecutablePath() throws {
        let p = try spawnMimic(named: "codex-mimic")
        defer { p.terminate() }
        let found = ProcessTree.findAgentAncestor(
            provider: .codex, startingAt: p.processIdentifier
        )
        #expect(found == p.processIdentifier)
    }

    @Test func unrelatedProcessItselfDoesNotMatch() throws {
        let p = try spawnMimic(named: "plainproc")
        defer { p.terminate() }
        // The walk legitimately ascends past plainproc and MAY find an
        // ambient agent higher up (these tests run under claude or codex
        // during development), so asserting nil would be environment-
        // dependent. The property under test is only that plainproc itself
        // never matches.
        for provider in Provider.allCases {
            let found = ProcessTree.findAgentAncestor(
                provider: provider, startingAt: p.processIdentifier
            )
            #expect(found != p.processIdentifier,
                    "\(provider.rawValue) matched an unrelated binary name")
        }
    }
}
