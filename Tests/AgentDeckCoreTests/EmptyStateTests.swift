import Testing
@testable import AgentDeckCore

struct EmptyStateTests {
    @Test func filterMatchTakesPrecedenceOverEverything() {
        // even with hooks missing, an active filter explains the empty list —
        // the bug was telling a filtering user their hooks were broken
        #expect(
            EmptyState.determine(
                helperInstalled: false, claude: .missing, codex: .missing, filter: "webapp"
            ) == .noFilterMatch(query: "webapp")
        )
    }

    @Test func coreHooksMissingWhenHelperOrClaudeAbsent() {
        #expect(EmptyState.determine(
            helperInstalled: false, claude: .installed, codex: .installed, filter: "")
            == .coreHooksMissing)
        #expect(EmptyState.determine(
            helperInstalled: true, claude: .missing, codex: .installed, filter: "")
            == .coreHooksMissing)
    }

    @Test func codexOnlyMissingIsItsOwnMessageNotACoreFailure() {
        // a Codex user must not be told everything's fine, nor that their
        // whole setup is broken
        #expect(EmptyState.determine(
            helperInstalled: true, claude: .installed, codex: .missing, filter: "")
            == .codexHooksMissing)
    }

    @Test func idleWhenFullyInstalledAndUnfiltered() {
        #expect(EmptyState.determine(
            helperInstalled: true, claude: .installed, codex: .installed, filter: "  ") == .idle)
    }

    @Test func policyBlockedHooksAreNotReportedAsBroken() {
        // a managed Mac: hooks off by policy, no Codex. Nothing to fix, so
        // don't tell the user to install anything.
        #expect(EmptyState.determine(
            helperInstalled: true, claude: .blockedByPolicy, codex: .notApplicable, filter: "")
            == .hooksBlockedByPolicy)
        #expect(EmptyState.determine(
            helperInstalled: true, claude: .installed, codex: .notApplicable, filter: "")
            == .idle, "no Codex on this Mac isn't a missing install")
    }
}
