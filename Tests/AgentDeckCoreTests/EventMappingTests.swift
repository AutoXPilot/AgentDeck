import Testing
@testable import AgentDeckCore

struct EventMappingTests {
    @Test func claudeLifecycle() {
        #expect(EventMapping.action(provider: .claude, event: "SessionStart") == .set(.ready))
        #expect(EventMapping.action(provider: .claude, event: "UserPromptSubmit") == .set(.working))
        #expect(EventMapping.action(provider: .claude, event: "PermissionRequest") == .set(.waiting))
        #expect(EventMapping.action(provider: .claude, event: "Stop") == .set(.done))
        #expect(EventMapping.action(provider: .claude, event: "StopFailure") == .set(.error))
        #expect(EventMapping.action(provider: .claude, event: "SessionEnd") == .remove)
    }

    @Test(arguments: [
        "permission_prompt", "elicitation_dialog",
        "agent_needs_input", "Permission_Prompt",
    ])
    func notificationTypesThatMeanWaiting(type: String) {
        #expect(
            EventMapping.action(provider: .claude, event: "Notification", notificationType: type)
                == .set(.waiting)
        )
    }

    @Test(arguments: [
        "auth_success", "agent_completed", "elicitation_complete", "elicitation_response",
        // an idle agent is not a blocked agent: treating it as `waiting`
        // put five idle sessions in the badge and made it meaningless
        "idle_prompt",
    ])
    func notificationTypesThatAreIgnored(type: String) {
        // agent_completed: a background task finishing must not flip the
        // main session's state — Stop owns "done"
        #expect(
            EventMapping.action(provider: .claude, event: "Notification", notificationType: type)
                == .ignore
        )
    }

    @Test func notificationWithoutTypeIgnored() {
        #expect(
            EventMapping.action(provider: .claude, event: "Notification", notificationType: nil)
                == .ignore
        )
    }

    @Test func codexSupportedEvents() {
        // verified live against codex-cli 0.145.0 (SessionEnd fires; see README)
        #expect(EventMapping.action(provider: .codex, event: "SessionStart") == .set(.ready))
        #expect(EventMapping.action(provider: .codex, event: "UserPromptSubmit") == .set(.working))
        #expect(EventMapping.action(provider: .codex, event: "Stop") == .set(.done))
        #expect(EventMapping.action(provider: .codex, event: "SessionEnd") == .remove)
        #expect(EventMapping.action(provider: .codex, event: "PermissionRequest") == .set(.waiting))
    }

    @Test func blockingClassificationDrivesLegacyRepair() {
        // used to re-judge snapshots written before idle stopped counting
        #expect(EventMapping.isBlockingNotification("permission_prompt"))
        #expect(EventMapping.isBlockingNotification("agent_needs_input"))
        #expect(EventMapping.isBlockingNotification("elicitation_dialog"))
        #expect(!EventMapping.isBlockingNotification("idle_prompt"))
        #expect(!EventMapping.isBlockingNotification("agent_completed"))
        #expect(!EventMapping.isBlockingNotification("auth_success"))
    }

    @Test func unknownEventsIgnored() {
        #expect(EventMapping.action(provider: .claude, event: "PreToolUse") == .ignore)
        #expect(EventMapping.action(provider: .codex, event: "SomeFutureEvent") == .ignore)
        #expect(EventMapping.action(provider: .claude, event: "") == .ignore)
    }
}
