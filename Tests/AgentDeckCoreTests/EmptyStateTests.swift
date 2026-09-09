import Testing
@testable import AgentDeckCore

struct EmptyStateTests {
    @Test func filterMatchTakesPrecedenceOverEverything() {
        // even with hooks missing, an active filter explains the empty list —
        // the bug was telling a filtering user their hooks were broken
        #expect(
            EmptyState.determine(
                helperInstalled: false, claudeHooksInstalled: false,
                codexHooksInstalled: false, filter: "webapp"
            ) == .noFilterMatch(query: "webapp")
        )
    }

    @Test func coreHooksMissingWhenHelperOrClaudeAbsent() {
        #expect(EmptyState.determine(
            helperInstalled: false, claudeHooksInstalled: true,
            codexHooksInstalled: true, filter: "") == .coreHooksMissing)
        #expect(EmptyState.determine(
            helperInstalled: true, claudeHooksInstalled: false,
            codexHooksInstalled: true, filter: "") == .coreHooksMissing)
    }

    @Test func codexOnlyMissingIsItsOwnMessageNotACoreFailure() {
        // a Codex user must not be told everything's fine, nor that their
        // whole setup is broken
        #expect(EmptyState.determine(
            helperInstalled: true, claudeHooksInstalled: true,
            codexHooksInstalled: false, filter: "") == .codexHooksMissing)
    }

    @Test func idleWhenFullyInstalledAndUnfiltered() {
        #expect(EmptyState.determine(
            helperInstalled: true, claudeHooksInstalled: true,
            codexHooksInstalled: true, filter: "  ") == .idle)
    }
}
