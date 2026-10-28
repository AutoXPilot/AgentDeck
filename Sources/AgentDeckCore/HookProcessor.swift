import Foundation

/// The helper's hook-mode brain, extracted from the executable so the
/// payload-parsing path — the one component that must never fail loudly in
/// production — is unit-testable with recorded fixtures.
public enum HookProcessor {
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

    /// Parse, then store. The helper's entry point.
    @discardableResult
    public static func process(
        provider: Provider,
        payloadData: Data,
        argvEvent: String? = nil,
        environment: [String: String],
        parentPid: pid_t?,
        store: SnapshotStore,
        host: SessionHost? = nil,
        now: Date = Date()
    ) -> HookAction {
        guard let event = HookPayload.parse(
            provider: provider, data: payloadData, argvEvent: argvEvent) else { return .ignore }
        return apply(event, provider: provider, environment: environment,
                     parentPid: parentPid, store: store, host: host, now: now)
    }

    /// The store step: map the event to an action and apply it to the
    /// session's snapshot under its lock.
    @discardableResult
    public static func apply(
        _ e: NormalizedHookEvent,
        provider: Provider,
        environment: [String: String],
        parentPid: pid_t?,
        store: SnapshotStore,
        host: SessionHost? = nil,
        now: Date = Date()
    ) -> HookAction {
        let event = e.event
        let sessionId = e.sessionId
        let action = EventMapping.action(for: e, provider: provider)
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
                // Stop only ever updates where a SessionEnd can race it:
                // creating on Stop would resurrect a session that a
                // concurrent SessionEnd hook just removed
                if event == "Stop" && existing == nil && provider.spec.stopUpdatesOnly {
                    return .ignore
                }
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
                let cwd = e.cwd ?? existing?.projectPath ?? ""
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
                        ? (e.notificationType ?? existing?.notificationType) : nil,
                    permissionMode: e.permissionMode ?? existing?.permissionMode,
                    model: e.model ?? existing?.model,
                    // only a payload that actually carried a model refreshes
                    // this; carrying the old value forward must not make it
                    // look newly observed
                    modelObservedAt: e.model != nil ? now : existing?.modelObservedAt,
                    effort: e.effort ?? existing?.effort,
                    errorKind: state == .error ? e.errorKind : nil,
                    hostKind: hostKind,
                    hostBundlePath: hostBundlePath
                )
                try? store.write(snapshot)
            }
            return action
        }) ?? .ignore
    }
}
