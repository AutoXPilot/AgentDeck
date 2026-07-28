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

    /// Runs the focus script via osascript. Returns "focused", "not-found",
    /// or "error: …" — callers can fall back to the reveal URL.
    ///
    /// Bounded: the first-ever run blocks on the macOS Automation consent
    /// dialog, and an unanswered dialog must not park a thread forever.
    /// The timeout is generous so the user has time to read the prompt.
    /// stderr merges into stdout (two pipes drained sequentially can
    /// deadlock), and the post-exit drain can't block on a live process.
    public static func focusViaAppleScript(
        guid: String, timeout: TimeInterval = 20
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-", guid]
        let stdin = Pipe(), output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return "error: \(error.localizedDescription)" }
        try? stdin.fileHandleForWriting.write(contentsOf: Data(focusScript.utf8))
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return "error: timed out after \(Int(timeout))s "
                + "(Automation permission dialog unanswered?)"
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { return "error: \(text)" }
        return text
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
