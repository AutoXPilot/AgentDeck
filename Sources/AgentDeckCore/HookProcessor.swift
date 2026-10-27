import Foundation

/// The helper's hook-mode brain, extracted from the executable so the
/// payload-parsing path — the one component that must never fail loudly in
/// production — is unit-testable with recorded fixtures.
public enum HookProcessor {
    /// Fields carried on every hook payload that describe the session rather
    /// than its content. Conversation content (`prompt`,
    /// `last_assistant_message`, `tool_input`, …) is never read.
    static func metadata(from payload: [String: Any]) -> (
        notificationType: String?, permissionMode: String?,
        model: String?, effort: String?, errorKind: String?
    ) {
        let effort: String?
        if let dict = payload["effort"] as? [String: Any] {
            effort = dict["level"] as? String
        } else {
            effort = payload["effort"] as? String
        }
        return (
            notificationType: payload["notification_type"] as? String
                ?? payload["type"] as? String,
            permissionMode: payload["permission_mode"] as? String,
            model: payload["model"] as? String,
            effort: effort,
            errorKind: payload["error"] as? String
        )
    }

    /// The pane to record. A hook that reports none carries the last one
    /// forward — except where that pane can't be this session's any more:
    /// the session now runs in an app (a GUI has no pane; a conversation
    /// resumed inside Claude Desktop would otherwise keep focusing the
    /// iTerm tab it left), or both readings are known and the host changed.
    /// An unknown reading, or a snapshot from before hosts were recorded,
    /// keeps today's carry-forward.
    static func carriedPane(
        envPane: String?, existing: SessionSnapshot?, observedHost: SessionHost
    ) -> String? {
        if let envPane { return envPane }
        guard let carried = existing?.terminalSessionId else { return nil }
        if observedHost.kind == .app { return nil }
        if let now = observedHost.kind, let before = existing?.host.kind,
           now != before || observedHost.bundlePath != existing?.hostBundlePath {
            return nil
        }
        return carried
    }

    @discardableResult
    public static func process(
        provider: Provider,
        payloadData: Data,
        environment: [String: String],
        parentPid: pid_t?,
        store: SnapshotStore,
        host: SessionHost? = nil,
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

        let meta = metadata(from: payload)
        let action = EventMapping.action(
            provider: provider,
            event: event,
            notificationType: meta.notificationType,
            endReason: payload["reason"] as? String
        )
        let key = SessionKey.make(provider, sessionId)

        // Serialize the whole load-merge-write/remove for this key so a `Stop`
        // and a racing `SessionEnd` for the same session can't resurrect a
        // just-removed snapshot (load and delete were previously unordered).
        // no lock, no write: dropping one event beats racing another
        // writer for this session (see withKeyLock)
        return (try? store.withKeyLock(key) {
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
                let envPane = environment["ITERM_SESSION_ID"]
                // Where the session runs, read from its process ancestry on
                // every event. Injected by tests.
                let observedHost = host ?? parentPid.map {
                    HostClassifier.classify(
                        ancestorBundlePaths: ProcessTree.ancestorBundlePaths(startingAt: $0),
                        terminalSessionId: envPane, transcriptEntrypoint: nil)
                } ?? .unknown
                let terminal = carriedPane(
                    envPane: envPane, existing: existing, observedHost: observedHost)
                // an unknown reading keeps what was recorded (raw, so a kind
                // a newer build wrote survives)
                let hostKind = observedHost.kind?.rawValue ?? existing?.hostKind
                let hostBundlePath = observedHost.kind != nil
                    ? observedHost.bundlePath : existing?.hostBundlePath
                // cwd fallback chain ends at the short session id so a
                // Notification-before-SessionStart can't render a blank row
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
                    agentPid: pid,
                    // only meaningful while waiting; stale reasons would mislead
                    notificationType: state == .waiting
                        ? (meta.notificationType ?? existing?.notificationType) : nil,
                    permissionMode: meta.permissionMode ?? existing?.permissionMode,
                    model: meta.model ?? existing?.model,
                    // only a payload that actually carried a model refreshes
                    // this; carrying the old value forward must not make it
                    // look newly observed
                    modelObservedAt: meta.model != nil ? now : existing?.modelObservedAt,
                    effort: meta.effort ?? existing?.effort,
                    errorKind: state == .error ? meta.errorKind : nil,
                    hostKind: hostKind,
                    hostBundlePath: hostBundlePath
                )
                try? store.write(snapshot)
            }
            return action
        }) ?? .ignore
    }
}
