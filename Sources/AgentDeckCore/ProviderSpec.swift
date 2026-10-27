import Foundation

/// Everything that differs between agent providers, in one table, so a
/// provider is added by writing a row rather than by finding every
/// `== .claude ? … : …` in the codebase. What stays per-provider on
/// purpose — Claude's registry and transcripts, Codex's thread database,
/// the event mapping — lives in its own type and is reached through the
/// provider, not through this table.
public struct ProviderSpec: Sendable {
    public let provider: Provider
    public let displayName: String
    /// Two letters on the row badge and in the header count.
    public let badge: String
    public let tint: ProviderTint
    /// nil = this provider has no hooks AgentDeck installs.
    public let hooks: HookConfigSpec?
    /// Whether the provider is set up on this Mac at all. An inapplicable
    /// provider is never offered an install, and its config is never
    /// created.
    public let applicability: Applicability
    /// The hook command names the event on argv (`<helper> <provider>
    /// <Event>`) because the payload doesn't carry it.
    public let eventNameOnArgv: Bool
    public let executableMatch: ExecutableMatch
    /// Resume needs a UUID; anything else opens a picker or a search.
    public let sessionIdIsUUID: Bool
    public let resume: ResumeStrategy
    /// Whether the conversation behind an entry still exists; nil = can't
    /// tell, in which case restore goes ahead rather than refusing.
    public let conversationExists: @Sendable (WorkspaceEntry) -> Bool?
    public let running: RunningStrategy
    /// A `Stop` for a session with no snapshot is dropped rather than
    /// creating one. Right for a provider whose SessionEnd can race its
    /// Stop (the Stop would resurrect the session SessionEnd just removed);
    /// wrong for one with no SessionEnd, where a missed start would leave
    /// the session invisible.
    public let stopUpdatesOnly: Bool

    /// `<provider>-` — the prefix of every session key.
    public var keyPrefix: String { provider.rawValue + "-" }

    public static let all: [Provider: ProviderSpec] = [
        .claude: ProviderSpec(
            provider: .claude, displayName: "Claude", badge: "CL", tint: .orange,
            hooks: HookConfigSpec(
                fileURL: { ClaudeConfig.current.appendingPathComponent("settings.json") },
                format: .claudeSettings,
                events: [
                    "SessionStart", "UserPromptSubmit", "PermissionRequest",
                    "Notification", "Stop", "StopFailure", "SessionEnd",
                ],
                policyGated: true,
                installNote: nil),
            applicability: .always,
            eventNameOnArgv: false,
            executableMatch: .claude,
            sessionIdIsUUID: true,
            resume: .shell(WorkspaceRestore.claudeCommandLine),
            conversationExists: { entry in
                ClaudeTranscript.url(sessionId: entry.sessionId, projectPath: entry.cwd) != nil
            },
            running: .claudeRegistry,
            stopUpdatesOnly: true),
        .codex: ProviderSpec(
            provider: .codex, displayName: "Codex", badge: "CX", tint: .teal,
            hooks: HookConfigSpec(
                fileURL: {
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".codex/hooks.json")
                },
                format: .codexHooks,
                // Verified against codex-cli 0.145.0: SessionStart/
                // UserPromptSubmit/Stop/SessionEnd all fire (SessionEnd's
                // timeout is clamped to 3s). PermissionRequest is accepted
                // without warning; firing not yet observed (exec mode never
                // prompts) — registered so interactive approvals surface as
                // "waiting" if/when codex emits it.
                events: ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"],
                policyGated: false,
                installNote: "codex will ask to trust the changed hooks on next launch"),
            applicability: .requiresHomeDirectory(".codex"),
            eventNameOnArgv: false,
            executableMatch: .codex,
            sessionIdIsUUID: true,
            resume: .shell(WorkspaceRestore.codexCommandLine),
            conversationExists: { entry in CodexThreads.exists(id: entry.sessionId) },
            running: .trustworthyPid(processScan: true),
            stopUpdatesOnly: true),
    ]

    public static func of(_ provider: Provider) -> ProviderSpec {
        // every case has a row; ProviderSpecTests guards it
        all[provider]!
    }
}

extension Provider {
    public var spec: ProviderSpec { ProviderSpec.of(self) }
}

/// A colour token; the app maps it to a real colour, so the core stays free
/// of UI frameworks.
public enum ProviderTint: Sendable { case orange, teal }

public struct HookConfigSpec: Sendable {
    public enum Format: Sendable {
        /// `{"hooks": {Event: [{hooks: [{type, command, timeout}]}]}}` in
        /// Claude's settings.json.
        case claudeSettings
        /// The same shape in Codex's hooks.json.
        case codexHooks
    }

    /// Read when needed: Claude's follows CLAUDE_CONFIG_DIR.
    public let fileURL: @Sendable () -> URL
    public let format: Format
    public let events: [String]
    /// The organization's Claude Code policy can refuse user hooks.
    public let policyGated: Bool
    /// Printed after an install that changed the file.
    public let installNote: String?
}

public enum Applicability: Sendable, Equatable {
    case always
    /// Applicable only if this directory under the home folder exists.
    case requiresHomeDirectory(String)

    public func isApplicable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        switch self {
        case .always:
            return true
        case .requiresHomeDirectory(let relative):
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(relative).path)
        }
    }
}

/// How a restored session's command line is built.
public enum ResumeStrategy: Sendable {
    /// (entry, permission modes the policy refuses) → the line, or nil if
    /// the entry can't be resumed safely.
    case shell(@Sendable (WorkspaceEntry, Set<String>) -> String?)
    case none
}

/// What counts as evidence that a session is running.
public enum RunningStrategy: Sendable, Equatable {
    /// Claude's own session registry names a live process for it.
    case claudeRegistry
    /// A snapshot pid that passes the identity check; with `processScan`,
    /// also a running agent process whose arguments name the session (a
    /// resumed Codex runs no hook until its first message).
    case trustworthyPid(processScan: Bool)
}

/// Whether a process is plausibly a provider's agent. The predicates are
/// pure so they can be pinned with fixtures; ProcessTree does the reading.
public enum ExecutableMatch: Sendable, Equatable {
    /// Path or name contains "claude" — the binary is named after its
    /// version (`versions/2.1.220`), so p_comm alone reads "2.1.220" — or a
    /// node/bun runtime for wrapper-hosted installs.
    case claude
    /// Path or name contains "codex".
    case codex
    /// The executable's file name is exactly this. For a short name, a
    /// substring rule would match unrelated binaries (`strategy`, `agyx`).
    case exactBasename(String)

    static func isJSRuntime(_ lowerName: String) -> Bool {
        lowerName == "node" || lowerName == "bun"
    }

    /// For the ancestor walk from a hook. `depth` is how far above the
    /// starting process this one is. The node/bun fallback applies only
    /// above the start: the start pid is the hook's own short-lived shell,
    /// and matching it as "node" would record a pid the liveness sweep
    /// deletes at once.
    public func matchesAncestor(name: String, path: String?, depth: Int) -> Bool {
        let lowerName = name.lowercased()
        let lowerPath = path?.lowercased() ?? ""
        switch self {
        case .claude:
            let pathMatch = lowerName.contains("claude") || lowerPath.contains("claude")
            return pathMatch || (depth > 0 && Self.isJSRuntime(lowerName))
        case .codex:
            return lowerName.contains("codex") || lowerPath.contains("codex")
        case .exactBasename(let base):
            return Self.basename(path) == base || (path == nil && name == base)
        }
    }

    /// For a recorded pid. A reused pid is almost always something else — a
    /// shell, a helper — which is what this rejects; it is not proof of
    /// identity. `argvMentions` is asked only for a node/bun runtime, which
    /// counts only if it is running Claude's script: any long-lived node
    /// process that inherited a session's pid would otherwise keep that row
    /// forever.
    public func looksLikeAgent(
        name: String, path: String?, argvMentions: (String) -> Bool
    ) -> Bool {
        let lowerName = name.lowercased()
        let lowerPath = path?.lowercased() ?? ""
        switch self {
        case .claude:
            if lowerName.contains("claude") || lowerPath.contains("claude") { return true }
            guard Self.isJSRuntime(lowerName) else { return false }
            return argvMentions("claude")
        case .codex:
            return lowerName.contains("codex") || lowerPath.contains("codex")
        case .exactBasename(let base):
            return Self.basename(path) == base || (path == nil && name == base)
        }
    }

    static func basename(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}
