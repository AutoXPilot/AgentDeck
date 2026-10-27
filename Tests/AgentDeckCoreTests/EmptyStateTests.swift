import Testing
@testable import AgentDeckCore

struct EmptyStateTests {
    @Test func filterMatchTakesPrecedenceOverEverything() {
        // even with hooks missing, an active filter explains the empty list —
        // the bug was telling a filtering user their hooks were broken
        #expect(
            EmptyState.determine(
                helperInstalled: false, statuses: [.claude: .missing, .codex: .missing], filter: "webapp"
            ) == .noFilterMatch(query: "webapp")
        )
    }

    @Test func coreHooksMissingWhenHelperOrClaudeAbsent() {
        #expect(EmptyState.determine(
            helperInstalled: false, statuses: [.claude: .installed, .codex: .installed], filter: "")
            == .coreHooksMissing)
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .missing, .codex: .installed], filter: "")
            == .coreHooksMissing)
    }

    @Test func codexOnlyMissingIsItsOwnMessageNotACoreFailure() {
        // a Codex user must not be told everything's fine, nor that their
        // whole setup is broken
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .installed, .codex: .missing], filter: "")
            == .secondaryHooksMissing([.codex]))
    }

    @Test func idleWhenFullyInstalledAndUnfiltered() {
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .installed, .codex: .installed], filter: "  ") == .idle)
    }

    @Test func policyBlockedHooksAreNotReportedAsBroken() {
        // a managed Mac: hooks off by policy, no Codex. Nothing to fix, so
        // don't tell the user to install anything.
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .blockedByPolicy, .codex: .notApplicable], filter: "")
            == .hooksBlockedByPolicy)
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .installed, .codex: .notApplicable], filter: "")
            == .idle, "no Codex on this Mac isn't a missing install")
    }

    @Test func policyBlockedClaudeWinsOverAMissingHelper() {
        // a managed Mac never runs the helper, so a missing one isn't a
        // problem to report there
        #expect(EmptyState.determine(
            helperInstalled: false, statuses: [.claude: .blockedByPolicy, .codex: .missing],
            filter: "") == .hooksBlockedByPolicy)
    }
}
