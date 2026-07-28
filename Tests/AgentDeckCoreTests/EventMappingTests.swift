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

    @Test(arguments: ["permission_prompt", "idle_prompt", "elicitation_request", "Permission_Prompt"])
    func notificationTypesThatMeanWaiting(type: String) {
        #expect(
            EventMapping.action(provider: .claude, event: "Notification", notificationType: type)
                == .set(.waiting)
        )
    }

    @Test func notificationTypesThatAreIgnored() {
        #expect(
            EventMapping.action(
                provider: .claude, event: "Notification", notificationType: "auth_success"
            ) == .ignore
        )
        #expect(
            EventMapping.action(provider: .claude, event: "Notification", notificationType: nil)
                == .ignore
        )
    }

    @Test func codexSupportedEvents() {
        #expect(EventMapping.action(provider: .codex, event: "SessionStart") == .set(.ready))
        #expect(EventMapping.action(provider: .codex, event: "UserPromptSubmit") == .set(.working))
        #expect(EventMapping.action(provider: .codex, event: "Stop") == .set(.done))
    }

    @Test func unknownEventsIgnored() {
        #expect(EventMapping.action(provider: .claude, event: "PreToolUse") == .ignore)
        #expect(EventMapping.action(provider: .codex, event: "SomeFutureEvent") == .ignore)
        #expect(EventMapping.action(provider: .claude, event: "") == .ignore)
    }
}
