import Foundation

/// Turns remembered sessions into launches. Deciding is pure and tested;
/// the app only gathers the facts and runs what comes back (the
/// `SessionPipeline` precedent).
public enum WorkspaceRestore {
    public enum SkipReason: Equatable, Sendable {
        case alreadyOpen
        /// Launched by an earlier restore and not yet visible as running.
        case alreadyRestoring
        case missingDirectory
        case missingConversation
        /// Not a session UUID. Resuming by anything else opens an
        /// interactive picker or searches by name, which is the failure
        /// restore exists to prevent.
        case invalidSessionId

        public var phrase: String {
            switch self {
            case .alreadyOpen: return "already open"
            case .alreadyRestoring: return "already restoring"
            case .missingDirectory: return "folder missing"
            case .missingConversation: return "conversation not found"
            case .invalidSessionId: return "no session id"
            }
        }
    }

    public struct Launch: Equatable, Sendable {
        public var entry: WorkspaceEntry
        /// Typed into a fresh login shell, which does the parsing.
        public var commandLine: String
    }

    public struct Plan: Equatable, Sendable {
        public var launches: [Launch] = []
        public var skipped: [(entry: WorkspaceEntry, reason: SkipReason)] = []

        public static func == (a: Plan, b: Plan) -> Bool {
            a.launches == b.launches
                && a.skipped.map(\.entry) == b.skipped.map(\.entry)
                && a.skipped.map(\.reason) == b.skipped.map(\.reason)
        }

        /// "3 already open, 1 folder missing"
        public var skipSummary: String {
            var counts: [(SkipReason, Int)] = []
            for (_, reason) in skipped {
                if let i = counts.firstIndex(where: { $0.0 == reason }) {
                    counts[i].1 += 1
                } else {
                    counts.append((reason, 1))
                }
            }
            return counts.map { "\($0.1) \($0.0.phrase)" }.joined(separator: ", ")
        }
    }

    /// What has to be true about the machine, gathered by the caller.
    public struct Facts {
        /// Session keys running now.
        public var live: Set<String>
        public var inFlight: Set<String>
        public var directoryExists: (String) -> Bool
        /// nil = can't tell (e.g. Codex's database unreadable); the launch
        /// goes ahead rather than being refused on missing evidence.
        public var conversationExists: (WorkspaceEntry) -> Bool?

        public init(
            live: Set<String>, inFlight: Set<String> = [],
            directoryExists: @escaping (String) -> Bool = WorkspaceRestore.isEnterableDirectory,
            conversationExists: @escaping (WorkspaceEntry) -> Bool?
        ) {
            self.live = live
            self.inFlight = inFlight
            self.directoryExists = directoryExists
            self.conversationExists = conversationExists
        }
    }

    public static func plan(_ entries: [WorkspaceEntry], facts: Facts) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.key).inserted {
            let reason: SkipReason?
            if facts.live.contains(entry.key) {
                reason = .alreadyOpen
            } else if facts.inFlight.contains(entry.key) {
                reason = .alreadyRestoring
            } else if !facts.directoryExists(entry.cwd) {
                reason = .missingDirectory
            } else if facts.conversationExists(entry) == false {
                reason = .missingConversation
            } else {
                reason = nil
            }
            if let reason {
                plan.skipped.append((entry, reason))
            } else if let line = commandLine(for: entry) {
                plan.launches.append(Launch(entry: entry, commandLine: line))
            } else {
                plan.skipped.append((entry, .invalidSessionId))
            }
        }
        return plan
    }

    /// Claude's `--permission-mode` choices (claude --help, 2.1.302).
    /// Anything else is dropped rather than passed through.
    public static let claudePermissionModes: Set<String> = [
        "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan",
    ]

    /// Built from the session id, never from a recorded command. The id
    /// must parse as a UUID; the directory is the only free text, and it is
    /// shell-quoted. The workspace file is effectively an execution
    /// manifest, so this is the whole of what it can make a shell do.
    ///
    /// No `exec`: when the agent exits the pane drops back to a shell
    /// instead of closing.
    public static func commandLine(for entry: WorkspaceEntry) -> String? {
        guard let uuid = UUID(uuidString: entry.sessionId) else { return nil }
        let id = uuid.uuidString.lowercased()
        let cd = "cd -- \(shellQuote(entry.cwd))"
        switch entry.provider {
        case .claude:
            var line = "\(cd) && claude --resume \(id)"
            if let mode = entry.permissionMode, claudePermissionModes.contains(mode) {
                line += " --permission-mode \(mode)"
            }
            return line
        case .codex:
            // Approval flags are not restored: Codex's are spread over
            // several options with no single recorded mode to map back,
            // and guessing wrong in the permissive direction is worse.
            return "\(cd) && codex resume \(id)"
        }
    }

    /// POSIX single-quoting: everything literal, `'` written as `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `cd` needs search permission, not just existence.
    public static func isEnterableDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue && access(path, X_OK) == 0
    }

    // MARK: Execution

    public enum Outcome: Equatable, Sendable {
        case launched
        case failed(String)
        /// The script timed out. Panes may exist — a timeout is not a
        /// failure, and retrying it could double-launch the session.
        case uncertain
    }

    /// Opens a pane and types the command into its login shell. iTerm's
    /// own `command` parameter is not used: it does not run a shell
    /// (`cd X && …` produced a dead session and a hung script when tried),
    /// whereas the user's shell parses the line exactly as if typed.
    ///
    /// argv: target window id ("" for a new window), command line.
    /// Returns the window id so later launches land in the same window.
    public static let launchScript = """
    on run argv
        set targetWindow to item 1 of argv
        set cmd to item 2 of argv
        tell application "iTerm2"
            set w to missing value
            if targetWindow is not "" then
                try
                    set w to (first window whose id is (targetWindow as integer))
                end try
            end if
            if w is missing value then
                set w to (create window with default profile)
                set s to current session of w
            else
                tell w to set t to (create tab with default profile)
                set s to current session of t
            end if
            tell s to write text cmd
            return (id of w) as text
        end tell
    end run
    """

    public typealias ScriptRunner = @Sendable (_ script: String, _ args: [String]) -> ITermFocus.ScriptOutcome

    /// Launches one after another into a single new window, re-checking
    /// each entry immediately before its launch. Blocking; run off the
    /// main thread.
    public static func execute(
        _ launches: [Launch],
        stillWanted: (WorkspaceEntry) -> Bool,
        stagger: TimeInterval = 0.4,
        run: ScriptRunner = { script, args in
            ITermFocus.runAppleScript(script, arguments: args, timeout: 15)
        },
        progress: (WorkspaceEntry, Outcome) -> Void = { _, _ in }
    ) -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        var window = ""
        for (i, launch) in launches.enumerated() {
            guard stillWanted(launch.entry) else { continue }
            if i > 0, stagger > 0 { Thread.sleep(forTimeInterval: stagger) }
            let outcome: Outcome
            switch run(launchScript, [window, launch.commandLine]) {
            case .success(let id):
                outcome = .launched
                if !id.isEmpty { window = id }
            case .failure(let message) where message.hasPrefix("timed out"):
                outcome = .uncertain
            case .failure(let message):
                outcome = .failed(message)
            }
            outcomes[launch.entry.key] = outcome
            progress(launch.entry, outcome)
        }
        return outcomes
    }
}
