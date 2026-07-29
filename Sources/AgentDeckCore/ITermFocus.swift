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

    static func runAppleScript(
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
    public static let listSessionsScript = """
    on run argv
        set out to ""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (id of s) & tab & (name of s) & linefeed
                    end repeat
                end repeat
            end repeat
        end tell
        return out
    end run
    """

    public static func parseSessionNames(_ output: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let tabIndex = line.firstIndex(of: "\t") else { continue }
            let guid = String(line[..<tabIndex])
            let name = String(line[line.index(after: tabIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !guid.isEmpty && !name.isEmpty { names[guid] = name }
        }
        return names
    }

    /// GUID → tab title for every live iTerm session; empty on any failure
    /// (callers fall back to folder names). Only call when iTerm is running —
    /// `tell application` would LAUNCH it otherwise.
    public static func fetchSessionNames(timeout: TimeInterval = 10) -> [String: String] {
        switch runAppleScript(listSessionsScript, timeout: timeout) {
        case .success(let out): return parseSessionNames(out)
        case .failure: return [:]
        }
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
