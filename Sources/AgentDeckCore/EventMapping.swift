import Foundation

public enum HookAction: Equatable, Sendable {
    case set(SessionState)
    case remove
    case ignore
}

/// Maps provider lifecycle hook events to session-state actions.
///
/// Claude events verified against code.claude.com/docs/en/hooks (2026-07).
/// Codex ships a subset (no SessionEnd, no StopFailure); its sessions are
/// removed by the PID liveness sweep instead.
public enum EventMapping {
    /// Notification types that mean "a human needs to look at this".
    /// agent_needs_input = a background/subagent task blocked on the user.
    /// Deliberately NOT here: agent_completed (a background task finishing
    /// must not flip the main session's state — Stop owns "done"), and
    /// elicitation_complete/_response (those mean the wait resolved).
    static let waitingNotificationPrefixes = [
        "permission", "idle", "elicitation_dialog", "agent_needs",
    ]

    public static func action(
        provider: Provider,
        event: String,
        notificationType: String? = nil
    ) -> HookAction {
        switch event {
        case "SessionStart":
            return .set(.ready)
        case "UserPromptSubmit":
            return .set(.working)
        case "PermissionRequest":
            return .set(.waiting)
        case "Notification":
            guard let type = notificationType?.lowercased() else { return .ignore }
            let waiting = waitingNotificationPrefixes.contains { type.hasPrefix($0) }
            return waiting ? .set(.waiting) : .ignore
        case "Stop":
            return .set(.done)
        case "StopFailure":
            return .set(.error)
        case "SessionEnd":
            return .remove
        default:
            return .ignore
        }
    }
}
