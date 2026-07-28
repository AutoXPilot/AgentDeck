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
    public var schemaVersion: Int
    public var provider: Provider
    public var sessionId: String
    public var projectPath: String
    public var state: SessionState
    public var event: String
    public var updatedAt: Date
    public var terminalSessionId: String?
    public var agentPid: Int32?

    public init(
        schemaVersion: Int = 1,
        provider: Provider,
        sessionId: String,
        projectPath: String,
        state: SessionState,
        event: String,
        updatedAt: Date = Date(),
        terminalSessionId: String? = nil,
        agentPid: Int32? = nil
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
    }

    public var key: String { "\(provider.rawValue)-\(sessionId)" }

    public var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }
}
