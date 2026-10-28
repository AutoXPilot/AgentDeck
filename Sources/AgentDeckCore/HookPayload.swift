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
    /// The tool a tool event is about (`ask_question`). The name only —
    /// a tool call's arguments are content and are never read.
    public var toolName: String? = nil
    /// Antigravity's Stop: whether the agent is fully idle (turn over).
    public var fullyIdle: Bool? = nil
    /// Whether the payload reported an error. Antigravity's `error` is
    /// free text, so only its presence is kept.
    public var reportedError: Bool = false
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
        if provider == .antigravity {
            return parseAntigravity(payload, argvEvent: argvEvent)
        }
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

    /// Antigravity's camelCase payload; the event comes from argv. Read by
    /// allow-list: `lastUserInput` (the user's message), `toolCall.args`
    /// and the text of `error` are content and never leave this function.
    static func parseAntigravity(
        _ payload: [String: Any], argvEvent: String?
    ) -> NormalizedHookEvent? {
        guard let event = argvEvent, !event.isEmpty,
              let rawId = payload["conversationId"] as? String, !rawId.isEmpty
        else { return nil }
        let sessionId = SnapshotStore.sanitizeKeyComponent(rawId)
        guard !sessionId.isEmpty else { return nil }
        let toolName = (payload["toolCall"] as? [String: Any])?["name"] as? String
        let workspace = (payload["workspacePaths"] as? [Any])?.first as? String
        // an empty string means no error (observed on every clean Stop)
        let reportedError = (payload["error"] as? String).map { !$0.isEmpty } ?? false
        return NormalizedHookEvent(
            event: event,
            sessionId: sessionId,
            cwd: (workspace?.isEmpty == false) ? workspace : nil,
            // the only waiting reason agy has: it asked the user something
            notificationType: event == "PreToolUse" && toolName == askQuestionTool
                ? askQuestionTool : nil,
            permissionMode: nil,
            model: payload["modelName"] as? String,
            effort: nil,
            errorKind: reportedError
                ? errorCategory(terminationReason: payload["terminationReason"] as? String) : nil,
            endReason: nil,
            toolName: toolName,
            fullyIdle: payload["fullyIdle"] as? Bool,
            reportedError: reportedError)
    }

    /// Antigravity's question tool, observed with agy 1.4.7.
    public static let askQuestionTool = "ask_question"

    /// A bounded category for a failed turn, from agy's `terminationReason`
    /// — an enum-like token (`NO_TOOL_CALL`) — never from the free-text
    /// `error`. Anything that doesn't look like such a token is "error".
    static func errorCategory(terminationReason: String?) -> String {
        guard let reason = terminationReason, !reason.isEmpty, reason.count <= 40,
              reason.unicodeScalars.allSatisfy({
                  ("A"..."Z").contains($0) || ("a"..."z").contains($0)
                      || ("0"..."9").contains($0) || $0 == "_"
              })
        else { return "error" }
        return reason.lowercased()
    }
}
