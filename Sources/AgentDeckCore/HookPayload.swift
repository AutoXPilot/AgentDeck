import Foundation

/// A hook payload reduced to the session metadata AgentDeck keeps, in one
/// shape whatever the provider's wire format. Conversation content
/// (`prompt`, `last_assistant_message`, `tool_input`, …) has no field here,
/// so it can't reach a snapshot by accident.
public struct NormalizedHookEvent: Equatable, Sendable {
    public var event: String
    /// Already sanitized: safe as a filename component.
    public var sessionId: String
    public var cwd: String?
    public var notificationType: String?
    public var permissionMode: String?
    public var model: String?
    public var effort: String?
    /// A bounded classification ("rate_limit", …), never free text.
    public var errorKind: String?
    /// SessionEnd's reason ("clear", "resume", "logout", …).
    public var endReason: String?
}

public enum HookPayload {
    /// The provider's adapter. nil = not a payload this event can use (bad
    /// JSON, no session id, no event name), which the helper ignores.
    ///
    /// `argvEvent`: the event named on the hook's command line, for a
    /// provider whose payload doesn't carry one (`eventNameOnArgv`).
    public static func parse(
        provider: Provider, data: Data, argvEvent: String? = nil
    ) -> NormalizedHookEvent? {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // Claude and Codex both send snake_case with the event in the
        // payload; argv is consulted only for a provider that declares it.
        let event = provider.spec.eventNameOnArgv
            ? argvEvent : payload["hook_event_name"] as? String
        guard let event, !event.isEmpty,
              let rawId = payload["session_id"] as? String, !rawId.isEmpty
        else { return nil }
        // session_id becomes a filename: sanitize or a crafted id could
        // write/delete JSON outside the sessions directory
        let sessionId = SnapshotStore.sanitizeKeyComponent(rawId)
        guard !sessionId.isEmpty else { return nil }

        let effort: String?
        if let dict = payload["effort"] as? [String: Any] {
            effort = dict["level"] as? String
        } else {
            effort = payload["effort"] as? String
        }
        return NormalizedHookEvent(
            event: event,
            sessionId: sessionId,
            cwd: payload["cwd"] as? String,
            notificationType: payload["notification_type"] as? String
                ?? payload["type"] as? String,
            permissionMode: payload["permission_mode"] as? String,
            model: payload["model"] as? String,
            effort: effort,
            errorKind: payload["error"] as? String,
            endReason: payload["reason"] as? String)
    }
}
