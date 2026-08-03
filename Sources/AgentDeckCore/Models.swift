import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
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
    public static let currentSchemaVersion = 2

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
    /// Reasoning effort level, e.g. "high".
    public var effort: String?
    /// StopFailure classification: "rate_limit", "billing_error", …
    public var errorKind: String?

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
        effort: String? = nil,
        errorKind: String? = nil
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
        self.effort = effort
        self.errorKind = errorKind
    }

    public var key: String { "\(provider.rawValue)-\(sessionId)" }

    public var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    /// Permission modes where the agent acts without asking — worth flagging.
    public var isUnsupervised: Bool {
        permissionMode == "bypassPermissions" || permissionMode == "dontAsk"
    }
}
