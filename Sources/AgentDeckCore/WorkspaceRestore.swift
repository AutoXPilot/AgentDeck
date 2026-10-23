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
        /// Relative, or containing a control character. The command is
        /// typed into a terminal, where a control character is a keystroke
        /// — Ctrl-U erases the line — so no amount of shell quoting makes
        /// one safe.
        case unusableDirectory
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
            case .unusableDirectory: return "unusable folder path"
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
        /// Permission modes the organization's policy refuses.
        public var refusedPermissionModes: Set<String>

        public init(
            live: Set<String>, inFlight: Set<String> = [],
            directoryExists: @escaping (String) -> Bool = WorkspaceRestore.isEnterableDirectory,
            conversationExists: @escaping (WorkspaceEntry) -> Bool?,
            refusedPermissionModes: Set<String> = []
        ) {
            self.refusedPermissionModes = refusedPermissionModes
            self.live = live
            self.inFlight = inFlight
            self.directoryExists = directoryExists
            self.conversationExists = conversationExists
        }
    }

    public static func plan(_ entries: [WorkspaceEntry], facts: Facts) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        // canonical ids before any lookup: "ABC…" and "abc…" resume the
        // same conversation, so they must not pass dedupe or the live
        // check as two different sessions
        for entry in entries.map(canonical) where seen.insert(entry.key).inserted {
            let reason: SkipReason?
            if UUID(uuidString: entry.sessionId) == nil {
                reason = .invalidSessionId
            } else if !isTypeableDirectory(entry.cwd) {
                reason = .unusableDirectory
            } else if facts.live.contains(entry.key) {
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
            } else if let line = commandLine(
                for: entry, refusedPermissionModes: facts.refusedPermissionModes) {
                plan.launches.append(Launch(entry: entry, commandLine: line))
            } else {
                plan.skipped.append((entry, .invalidSessionId))
            }
        }
        return plan
    }

    /// "Skipped: knowledge-86, research (folder missing); Home-value
    /// (already open)." Names, not just counts, so the user knows which
    /// sessions to bring back by hand.
    public static func describeSkips(
        _ skipped: [(entry: WorkspaceEntry, reason: SkipReason)]
    ) -> String {
        var groups: [(SkipReason, [String])] = []
        for (entry, reason) in skipped {
            if let i = groups.firstIndex(where: { $0.0 == reason }) {
                groups[i].1.append(entry.label)
            } else {
                groups.append((reason, [entry.label]))
            }
        }
        return "Skipped: " + groups.map { reason, labels in
            let shown = labels.prefix(4).joined(separator: ", ")
                + (labels.count > 4 ? " +\(labels.count - 4) more" : "")
            return "\(shown) (\(reason.phrase))"
        }.joined(separator: "; ") + "."
    }

    public static func canonical(_ entry: WorkspaceEntry) -> WorkspaceEntry {
        guard let uuid = UUID(uuidString: entry.sessionId) else { return entry }
        var e = entry
        e.sessionId = uuid.uuidString.lowercased()
        return e
    }

    static func isTypeableDirectory(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
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
    /// A recorded mode the policy refuses is left off, so the session
    /// starts in the default mode instead of Claude Code refusing to start.
    public static func commandLine(
        for entry: WorkspaceEntry, refusedPermissionModes: Set<String> = []
    ) -> String? {
        guard let uuid = UUID(uuidString: entry.sessionId),
              isTypeableDirectory(entry.cwd) else { return nil }
        let id = uuid.uuidString.lowercased()
        let cd = "cd -- \(shellQuote(entry.cwd))"
        switch entry.provider {
        case .claude:
            var line = "\(cd) && claude --resume \(id)"
            if let mode = entry.permissionMode, claudePermissionModes.contains(mode),
               !refusedPermissionModes.contains(mode) {
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
        /// The command was typed into a new pane. Not proof the session
        /// is running: the caller confirms that from the registry.
        case launched
        /// Refused before anything could happen, so retrying is safe.
        case failed(String)
        /// Timed out, or failed somewhere the pane may already exist or
        /// the text may already be typed. Retrying could start the same
        /// conversation twice.
        case uncertain(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Opens a pane and types the command into its login shell. iTerm's
    /// own `command` parameter is not used: it does not run a shell
    /// (`cd X && …` produced a dead session and a hung script when tried),
    /// whereas the user's shell parses the line exactly as if typed.
    ///
    /// argv: target window id ("" for a new window), command line.
    ///
    /// Reports which side of the typing it got to, because that is what
    /// decides whether a retry is safe: "untyped <code> <message>" if it
    /// failed before anything was typed (at worst an empty tab is left),
    /// "typed <window id>" once the command was sent. Any other outcome —
    /// an error while typing, a timeout — may have sent it. Guessing that
    /// from error text instead couldn't tell which step had failed.
    public static let launchScript = """
    on run argv
        set targetWindow to item 1 of argv
        set cmd to item 2 of argv
        tell application "iTerm2"
            try
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
            on error m number n
                return "untyped " & n & " " & m
            end try
            tell s to write text cmd
            try
                return "typed " & ((id of w) as text)
            on error
                return "typed "
            end try
        end tell
    end run
    """

    static func classifyLaunch(_ result: ITermFocus.ScriptOutcome) -> (Outcome, window: String?) {
        switch result {
        case .success(let out) where out.hasPrefix("typed"):
            let id = out.dropFirst("typed".count).trimmingCharacters(in: .whitespaces)
            return (.launched, id.isEmpty ? nil : id)
        case .success(let out) where out.hasPrefix("untyped "):
            return (.failed(String(out.dropFirst("untyped ".count))), nil)
        case .success(let out):
            return (.uncertain("unexpected reply: \(out)"), nil)
        case .failure(let message):
            return (.uncertain(message), nil)
        }
    }

    public typealias ScriptRunner = @Sendable (
        _ script: String, _ args: [String], _ timeout: TimeInterval
    ) -> ITermFocus.ScriptOutcome

    /// Answers once iTerm is up and taking Apple events. Addressing iTerm
    /// launches it if needed, and a cold start — iTerm restoring its own
    /// windows after a login — can outlast a launch's timeout, which would
    /// turn the first sessions into uncertain ones and split the rest into
    /// a second window. Nothing is typed until this succeeds.
    public static let readyScript = """
    tell application "iTerm2" to count windows
    """

    /// Launches into a single new window in batches, waiting after each
    /// batch (via `awaitBatch`) so thirty sessions don't start in the same
    /// few seconds and slow every AppleScript round-trip past its timeout.
    /// Each entry is re-checked immediately before its launch. Blocking;
    /// run off the main thread.
    public static func execute(
        _ launches: [Launch],
        stillWanted: (WorkspaceEntry) -> Bool,
        batchSize: Int = 5,
        stagger: TimeInterval = 0.4,
        readyTimeout: TimeInterval = 60,
        run: ScriptRunner = { script, args, timeout in
            ITermFocus.runAppleScript(script, arguments: args, timeout: timeout)
        },
        awaitBatch: ([WorkspaceEntry]) -> Void = { _ in },
        progress: (WorkspaceEntry, Outcome) -> Void = { _, _ in }
    ) -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        if case .failure(let message) = run(readyScript, [], readyTimeout) {
            // nothing has been typed anywhere, so every launch is retryable
            let reason = message.hasPrefix("timed out")
                ? "iTerm2 didn't respond within \(Int(readyTimeout))s" : message
            for launch in launches {
                outcomes[launch.entry.key] = .failed(reason)
                progress(launch.entry, .failed(reason))
            }
            return outcomes
        }
        var window = ""
        var batch: [WorkspaceEntry] = []
        for (i, launch) in launches.enumerated() {
            guard stillWanted(launch.entry) else { continue }
            if i > 0, stagger > 0 { Thread.sleep(forTimeInterval: stagger) }
            let (outcome, newWindow) = classifyLaunch(
                run(launchScript, [window, launch.commandLine], 15))
            if let newWindow { window = newWindow }
            // an uncertain launch may be starting a session too, so it
            // counts toward the batch as much as a confirmed one
            if !outcome.isFailure { batch.append(launch.entry) }
            outcomes[launch.entry.key] = outcome
            progress(launch.entry, outcome)
            if batch.count >= batchSize, i < launches.count - 1 {
                awaitBatch(batch)
                batch = []
            }
        }
        return outcomes
    }
}
