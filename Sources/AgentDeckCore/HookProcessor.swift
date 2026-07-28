import Foundation

/// The helper's hook-mode brain, extracted from the executable so the
/// payload-parsing path — the one component that must never fail loudly in
/// production — is unit-testable with recorded fixtures.
public enum HookProcessor {
    @discardableResult
    public static func process(
        provider: Provider,
        payloadData: Data,
        environment: [String: String],
        parentPid: pid_t?,
        store: SnapshotStore,
        now: Date = Date()
    ) -> HookAction {
        guard let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let event = payload["hook_event_name"] as? String,
              let rawId = payload["session_id"] as? String,
              !rawId.isEmpty
        else { return .ignore }

        // session_id becomes a filename: sanitize or a crafted id could
        // write/delete JSON outside the sessions directory
        let sessionId = SnapshotStore.sanitizeKeyComponent(rawId)
        guard !sessionId.isEmpty else { return .ignore }

        let notificationType =
            payload["notification_type"] as? String ?? payload["type"] as? String
        let action = EventMapping.action(
            provider: provider, event: event, notificationType: notificationType
        )
        let key = "\(provider.rawValue)-\(sessionId)"

        switch action {
        case .ignore:
            break
        case .remove:
            store.remove(key: key)
        case .set(let state):
            let existing = store.load(key: key)
            // Stop only ever updates: creating on Stop would resurrect a
            // session that a concurrent SessionEnd hook just removed
            if event == "Stop" && existing == nil { return .ignore }
            let terminal = environment["ITERM_SESSION_ID"] ?? existing?.terminalSessionId
            let cwd = (payload["cwd"] as? String) ?? existing?.projectPath ?? ""
            let pid = parentPid.flatMap {
                ProcessTree.findAgentAncestor(provider: provider, startingAt: $0)
            } ?? existing?.agentPid
            let snapshot = SessionSnapshot(
                provider: provider,
                sessionId: sessionId,
                projectPath: cwd,
                state: state,
                event: event,
                updatedAt: now,
                terminalSessionId: terminal,
                agentPid: pid
            )
            try? store.write(snapshot)
        }
        return action
    }
}
