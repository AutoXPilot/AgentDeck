import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    /// Google's Antigravity CLI (`agy`).
    case antigravity

    public var displayName: String { spec.displayName }
}

/// The one place a session key is spelled: `<provider>-<session id>`.
/// Keys name snapshot files, acknowledgements, workspace entries and
/// restore reservations, so every component must build them the same way.
public enum SessionKey {
    public static func make(_ provider: Provider, _ sessionId: String) -> String {
        "\(provider.rawValue)-\(sessionId)"
    }

    /// The provider and session id, or nil for a key whose provider this
    /// build doesn't know. Session ids contain dashes, so this matches a
    /// known provider prefix rather than splitting on the first dash.
    public static func split(_ key: String) -> (provider: Provider, sessionId: String)? {
        for provider in Provider.allCases {
            let prefix = provider.spec.keyPrefix
            if key.hasPrefix(prefix), key.count > prefix.count {
                return (provider, String(key.dropFirst(prefix.count)))
            }
        }
        return nil
    }
}

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case ready
    case working
    case waiting
    case done
    case error
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var provider: Provider
    public var sessionId: String
    public var projectPath: String
    public var state: SessionState
    public var event: String
    public var updatedAt: Date
    public var terminalSessionId: String?
    public var agentPid: Int32?

    // --- schema 2: metadata the CLIs already send on every hook ---

    /// Why a session is waiting: "permission_prompt", "idle_prompt", …
    public var notificationType: String?
    /// "default" | "plan" | "acceptEdits" | "auto" | "dontAsk" | "bypassPermissions"
    public var permissionMode: String?
    public var model: String?
    /// When `model` was last *supplied by a payload* — not when the snapshot
    /// was last touched. Events that omit the model still advance
    /// `updatedAt` while carrying the old value forward, so `updatedAt`
    /// says nothing about how current the model is, and using it to rank
    /// sources let a stale model outrank a fresher one. Nil on snapshots
    /// written before this field existed.
    public var modelObservedAt: Date?
    /// Reasoning effort level, e.g. "high".
    public var effort: String?
    /// StopFailure classification: "rate_limit", "billing_error", …
    public var errorKind: String?

    // --- schema 3: where the session runs ---

    /// "terminal" | "app"; absent means unknown, which is not the same as
    /// app. A string rather than an enum so a kind added later still
    /// decodes in this build.
    public var hostKind: String?
    /// The outermost application bundle hosting the session, when known.
    public var hostBundlePath: String?

    public init(
        schemaVersion: Int = SessionSnapshot.currentSchemaVersion,
        provider: Provider,
        sessionId: String,
        projectPath: String,
        state: SessionState,
        event: String,
        updatedAt: Date = Date(),
        terminalSessionId: String? = nil,
        agentPid: Int32? = nil,
        notificationType: String? = nil,
        permissionMode: String? = nil,
        model: String? = nil,
        modelObservedAt: Date? = nil,
        effort: String? = nil,
        errorKind: String? = nil,
        hostKind: String? = nil,
        hostBundlePath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.state = state
        self.event = event
        self.updatedAt = updatedAt
        self.terminalSessionId = terminalSessionId
        self.agentPid = agentPid
        self.notificationType = notificationType
        self.permissionMode = permissionMode
        self.model = model
        self.modelObservedAt = modelObservedAt
        self.effort = effort
        self.errorKind = errorKind
        self.hostKind = hostKind
        self.hostBundlePath = hostBundlePath
    }

    public var key: String { SessionKey.make(provider, sessionId) }

    public var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    /// Permission modes where the agent acts without asking — worth flagging.
    public var isUnsupervised: Bool {
        permissionMode == "bypassPermissions" || permissionMode == "dontAsk"
    }

    // A missing `schemaVersion` must not fail the decode: pre-schema-2 files
    // would otherwise be skipped by loadAll and then deleted as "corrupt" by
    // the orphan sweep. All schema-2 fields are already optional; only this
    // one non-optional needs a default.
    // Every stored property must be listed here. An explicit CodingKeys also
    // drives the synthesized `encode(to:)`, so a property omitted from this
    // enum is silently dropped on write — which is exactly what happened to
    // `modelObservedAt`: set on every hook event, never persisted, so the
    // reader always saw nil and fell back to the behaviour it was added to
    // replace. `roundTripsEveryField` guards this.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, sessionId, projectPath, state, event
        case updatedAt, terminalSessionId, agentPid, notificationType
        case permissionMode, model, modelObservedAt, effort, errorKind
        case hostKind, hostBundlePath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        provider = try c.decode(Provider.self, forKey: .provider)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        projectPath = try c.decode(String.self, forKey: .projectPath)
        state = try c.decode(SessionState.self, forKey: .state)
        event = try c.decode(String.self, forKey: .event)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        terminalSessionId = try c.decodeIfPresent(String.self, forKey: .terminalSessionId)
        agentPid = try c.decodeIfPresent(Int32.self, forKey: .agentPid)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        modelObservedAt = try c.decodeIfPresent(Date.self, forKey: .modelObservedAt)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        errorKind = try c.decodeIfPresent(String.self, forKey: .errorKind)
        hostKind = try c.decodeIfPresent(String.self, forKey: .hostKind)
        hostBundlePath = try c.decodeIfPresent(String.self, forKey: .hostBundlePath)
    }
}
