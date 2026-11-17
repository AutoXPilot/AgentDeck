import Foundation

public enum ITermFocus {
    /// The GUID part of ITERM_SESSION_ID ("w0t2p1:GUID" → "GUID") —
    /// AppleScript session ids are the bare GUID.
    public static func sessionGUID(from terminalSessionId: String?) -> String? {
        guard let raw = terminalSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let colon = raw.lastIndex(of: ":") else { return raw }
        let guid = String(raw[raw.index(after: colon)...])
        return guid.isEmpty ? nil : guid
    }

    /// Primary focus mechanism. The iterm2:///reveal URL scheme proved
    /// unreliable (observed working, then silently no-oping minutes later —
    /// likely gated by app-to-app URL consent); AppleScript selection is
    /// deterministic. Requires the one-time Automation permission.
    /// A tab closing mid-traversal throws "Invalid index (-1719)" and aborted
    /// the whole enumeration (2 logged in production). Per-window/per-tab
    /// `try` blocks skip the vanished element; the `tell` stays outside them
    /// so an Automation-denied error still surfaces at the top level.
    public static let focusScript = """
    on run argv
        set targetId to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            repeat with s in sessions of t
                                if (id of s) is targetId then
                                    select s
                                    select t
                                    select w
                                    activate
                                    return "focused"
                                end if
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return "not-found"
    end run
    """

    /// Runs an AppleScript via osascript with a hard deadline.
    ///
    /// Bounded: the first-ever run blocks on the macOS Automation consent
    /// dialog, and an unanswered dialog must not park a thread forever.
    /// The timeout is generous so the user has time to read the prompt.
    /// stderr merges into stdout (two pipes drained sequentially can
    /// deadlock), and the post-exit drain can't block on a live process.
    public enum ScriptOutcome: Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    public static func runAppleScript(
        _ script: String, arguments: [String] = [], timeout: TimeInterval = 20
    ) -> ScriptOutcome {
        let result = BoundedSubprocess.run(
            "/usr/bin/osascript", arguments: ["-"] + arguments,
            stdin: Data(script.utf8), timeout: timeout
        )
        if result.timedOut {
            return .failure("timed out after \(Int(timeout))s "
                + "(Automation permission dialog unanswered?)")
        }
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 ? .success(text) : .failure(text)
    }

    /// Sets one session's name (what its tab shows). The name arrives as an
    /// argument, never spliced into the script, so no title can change
    /// what the script does. Same per-window/per-tab `try` as the focus
    /// script. Cleared first: iTerm ignores a rename to the name it already
    /// holds, even after the shell has retitled the tab since (observed).
    public static let renameScript = """
    on run argv
        set targetId to item 1 of argv
        set newName to item 2 of argv
        tell application "iTerm2"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        try
                            repeat with s in sessions of t
                                if (id of s) is targetId then
                                    set name of s to ""
                                    set name of s to newName
                                    return "named"
                                end if
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return "not-found"
    end run
    """

    /// Whether iTerm renamed the pane.
    public static func renameSession(guid: String, to name: String, timeout: TimeInterval = 5) -> Bool {
        runAppleScript(renameScript, arguments: [guid, name], timeout: timeout) == .success("named")
    }

    /// Returns "focused", "not-found", or "error: …" — callers can fall
    /// back to the reveal URL.
    public static func focusViaAppleScript(
        guid: String, timeout: TimeInterval = 20
    ) -> String {
        switch runAppleScript(focusScript, arguments: [guid], timeout: timeout) {
        case .success(let out): return out
        case .failure(let err): return "error: \(err)"
        }
    }

    /// Enumerates every iTerm session as
    /// "GUID<TAB>tty<TAB>window id<TAB>tab number<TAB>title" lines, then a
    /// "#skipped<TAB>n" line: how many windows, tabs or sessions raised an
    /// error and were left out. A listing once came back with 14 of 31
    /// panes and said nothing; now it says it's partial. The title
    /// goes last because it is the only free-text field. The tab number
    /// counts every tab of the window, including one whose sessions failed
    /// to read, so positions stay true.
    /// Delimiters are computed OUTSIDE the tell block: inside it, `tab`
    /// resolves to iTerm's tab CLASS (dictionary shadowing), which silently
    /// produced unparseable output.
    public static let listSessionsScript = """
    on run argv
        set d to (character id 9)
        set nl to (character id 10)
        set out to ""
        set skipped to 0
        tell application "iTerm2"
            repeat with w in windows
                try
                    set wid to (id of w) as text
                    set tabNo to 0
                    repeat with t in tabs of w
                        set tabNo to tabNo + 1
                        try
                            repeat with s in sessions of t
                                try
                                    set out to out & (id of s) & d & (tty of s) & d & wid & d & tabNo & d & (name of s) & nl
                                on error
                                    set skipped to skipped + 1
                                end try
                            end repeat
                        on error
                            set skipped to skipped + 1
                        end try
                    end repeat
                on error
                    set skipped to skipped + 1
                end try
            end repeat
        end tell
        return out & "#skipped" & d & skipped & nl
    end run
    """

    /// Leading activity markers the CLIs paint into the title (✳ busy,
    /// braille spinner frames). The row's own state pill already says this,
    /// so they're duplicated noise that also shifts every title right.
    static let statusGlyphs = CharacterSet(charactersIn: "✳✽✻✢·*⠂⠄⠆⠇⠋⠙⠸⠰⠠⠐⢀⡀⣀⠈⠉⠊⠞⠟⠻⠽⠾⠷⠯⠟")

    /// Trailing `(claude)` / `(codex)` — the provider badge already shows it.
    /// Agents paint their own name into the tab title: the provider's name,
    /// or the command it runs as when that differs — agy titles its tab
    /// "<folder> (agy)", not "(antigravity)".
    static let providerSuffixes: [String] = Provider.allCases.flatMap { provider -> [String] in
        var names = ["(\(provider.rawValue))"]
        if case .exactBasename(let command, _) = provider.spec.executableMatch,
           command != provider.rawValue {
            names.append("(\(command))")
        }
        return names
    }

    /// Titles are whatever the shell or agent emitted. codex-cli emits an
    /// unbalanced quote — `Code (codex")` — so drop stray quotes, while
    /// leaving deliberately quoted titles (`run "make test"`) intact.
    /// Then strip the decoration that duplicates the row's own badges.
    public static func sanitizeTitle(_ raw: String) -> String {
        var title = String(String.UnicodeScalarView(
            // a tab is kept: titles can contain one
            raw.unicodeScalars.filter { $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        )).trimmingCharacters(in: .whitespaces)
        if title.filter({ $0 == "\"" }).count % 2 == 1 {
            title = title.replacingOccurrences(of: "\"", with: "")
        }
        while let first = title.unicodeScalars.first,
              statusGlyphs.contains(first) || first == " " {
            title.removeFirst()
        }
        let lowered = title.lowercased()
        for suffix in providerSuffixes where lowered.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
            break
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Human wording for the raw notification/registry reason strings.
    public static func humanizeReason(_ raw: String) -> String {
        switch raw.lowercased().replacingOccurrences(of: "_", with: " ") {
        case let s where s.contains("permission"): return "needs permission"
        case let s where s.contains("idle"): return "idle"
        case let s where s.contains("elicitation"): return "needs input"
        case let s where s.contains("agent needs"): return "subagent needs input"
        case let s where s.contains("sandbox"): return "sandbox request"
        case let s where s.contains("dialog"): return "dialog open"
        case "ask question": return "asked you a question"
        // shown and notified: anything not recognised above may be free text
        // from the session, so it becomes a fixed word
        default: return "waiting"
        }
    }

    /// Where a pane sits: iTerm's window id (as text) and the tab's
    /// position in it, from 1.
    public struct Place: Equatable, Sendable {
        public var window: String
        public var tab: Int

        public init?(window: String, tab: Int) {
            guard !window.isEmpty, tab >= 1 else { return nil }
            self.window = window
            self.tab = tab
        }
    }

    public struct SessionList: Equatable, Sendable {
        /// GUID → sanitized tab title
        public var names: [String: String] = [:]
        /// "ttys018" → GUID
        public var guidByTTY: [String: String] = [:]
        /// GUID → window and tab
        public var placeByGUID: [String: Place] = [:]
        /// Nothing was left out: the script's closing count arrived and is 0.
        /// Only a complete listing is the whole truth about which panes exist.
        public var complete = false

        public init() {}

        /// This listing laid over `earlier`: what it saw replaces, what it
        /// missed is kept. For a partial listing, whose gaps say nothing
        /// about whether those panes closed.
        public func merged(over earlier: SessionList) -> SessionList {
            var result = earlier
            result.names.merge(names) { _, new in new }
            // a pane seen now with no title has none, whatever it had
            for guid in Set(guidByTTY.values) where names[guid] == nil { result.names[guid] = nil }
            // a tty seen now names its pane now
            result.guidByTTY.merge(guidByTTY) { _, new in new }
            result.placeByGUID.merge(placeByGUID) { _, new in new }
            result.complete = false
            return result
        }
    }

    /// The tty is how a session with no recorded pane id finds its pane:
    /// the agent's controlling terminal is an exact fact about the process,
    /// unlike cwd or title, which several sessions routinely share.
    public static func parseSessionList(_ output: String) -> SessionList {
        var list = SessionList()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("#skipped\t") {
                list.complete = line.dropFirst("#skipped\t".count) == "0"
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let guid = String(fields[0])
            guard !guid.isEmpty else { continue }
            if let tty = normalizedTTY(String(fields[1])) { list.guidByTTY[tty] = guid }
            if Int(fields[2]) != nil, let tab = Int(fields[3]),
               let place = Place(window: String(fields[2]), tab: tab) {
                list.placeByGUID[guid] = place
            }
            let name = sanitizeTitle(String(fields[4]))
            if !name.isEmpty { list.names[guid] = name }
        }
        return list
    }

    public static func parseSessionNames(_ output: String) -> [String: String] {
        parseSessionList(output).names
    }

    /// "/dev/ttys018" and "ttys018" name the same device.
    public static func normalizedTTY(_ raw: String) -> String? {
        var tty = raw.trimmingCharacters(in: .whitespaces)
        if tty.hasPrefix("/dev/") { tty.removeFirst(5) }
        return tty.isEmpty ? nil : tty
    }

    /// GUID → tab title for every live iTerm session; failure carries the
    /// osascript error so callers can log why (and fall back to folders).
    /// Only call when iTerm is running — `tell application` would LAUNCH it.
    public static func fetchSessionNames(
        timeout: TimeInterval = 10
    ) -> ScriptOutcome {
        runAppleScript(listSessionsScript, timeout: timeout)
    }

    /// ITERM_SESSION_ID looks like "w0t2p1:1D5C29F2-...-UUID". iTerm's reveal
    /// URL needs the FULL id, colon included (percent-encoded) — a bare GUID
    /// is silently ignored. Verified against iTerm 3.6.11 by observing the
    /// active session change via AppleScript before/after opening the URL.
    public static func revealURL(terminalSessionId: String?) -> URL? {
        guard let raw = terminalSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let colon = raw.lastIndex(of: ":"),
           raw[raw.index(after: colon)...].isEmpty {
            return nil  // "w0t0p0:" with no GUID can't identify a session
        }
        guard let encoded = raw.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))
        ) else { return nil }
        return URL(string: "iterm2:///reveal?sessionid=\(encoded)")
    }
}
