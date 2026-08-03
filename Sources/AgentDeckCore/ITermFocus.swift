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
    public static let focusScript = """
    on run argv
        set targetId to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is targetId then
                            select s
                            select t
                            select w
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments
        let stdin = Pipe(), output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure(error.localizedDescription) }
        try? stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return .failure("timed out after \(Int(timeout))s "
                + "(Automation permission dialog unanswered?)")
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { return .failure(text) }
        return .success(text)
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

    /// Enumerates every iTerm session as "GUID<TAB>title" lines.
    /// Delimiters are computed OUTSIDE the tell block: inside it, `tab`
    /// resolves to iTerm's tab CLASS (dictionary shadowing), which silently
    /// produced unparseable output.
    public static let listSessionsScript = """
    on run argv
        set d to (character id 9)
        set nl to (character id 10)
        set out to ""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (id of s) & d & (name of s) & nl
                    end repeat
                end repeat
            end repeat
        end tell
        return out
    end run
    """

    /// Leading activity markers the CLIs paint into the title (✳ busy,
    /// braille spinner frames). The row's own state pill already says this,
    /// so they're duplicated noise that also shifts every title right.
    static let statusGlyphs = CharacterSet(charactersIn: "✳✽✻✢·*⠂⠄⠆⠇⠋⠙⠸⠰⠠⠐⢀⡀⣀⠈⠉⠊⠞⠟⠻⠽⠾⠷⠯⠟")

    /// Trailing `(claude)` / `(codex)` — the provider badge already shows it.
    static let providerSuffixes = ["(claude)", "(codex)"]

    /// Titles are whatever the shell or agent emitted. codex-cli emits an
    /// unbalanced quote — `Code (codex")` — so drop stray quotes, while
    /// leaving deliberately quoted titles (`run "make test"`) intact.
    /// Then strip the decoration that duplicates the row's own badges.
    public static func sanitizeTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
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
        case let s: return s
        }
    }

    public static func parseSessionNames(_ output: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let tabIndex = line.firstIndex(of: "\t") else { continue }
            let guid = String(line[..<tabIndex])
            let name = sanitizeTitle(String(line[line.index(after: tabIndex)...]))
            if !guid.isEmpty && !name.isEmpty { names[guid] = name }
        }
        return names
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
