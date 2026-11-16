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

    @Test func matchesThatAreOnlyHiddenAreNotReportedAsNoMatch() {
        // "nothing matches" would be false: the codex row matches, hidden
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .installed], filter: "webapp",
            matchCounts: [.claude: 0, .codex: 1, .antigravity: 0], hidden: [.codex, .antigravity])
            == .providersHidden([.codex]), "names only hidden providers with rows")
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .installed], filter: "webapp",
            matchCounts: [.claude: 0, .codex: 0], hidden: [.codex])
            == .noFilterMatch(query: "webapp"))
    }

    @Test func everythingHiddenWithoutAQuerySaysSo() {
        #expect(EmptyState.determine(
            helperInstalled: false, statuses: [.claude: .missing], filter: "",
            matchCounts: [.claude: 2, .antigravity: 1], hidden: Set(Provider.allCases))
            == .providersHidden([.claude, .antigravity]), "before any hook message")
    }

    @Test func hiddenProvidersWithNoSessionsLeaveTheUsualMessage() {
        #expect(EmptyState.determine(
            helperInstalled: true, statuses: [.claude: .installed, .codex: .installed], filter: "",
            matchCounts: [.claude: 0, .codex: 0], hidden: [.codex]) == .idle)
        #expect(EmptyState.determine(
            helperInstalled: false, statuses: [.claude: .installed], filter: "",
            matchCounts: [:], hidden: [.claude]) == .coreHooksMissing)
    }
}
