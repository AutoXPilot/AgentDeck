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
    public static func focusViaAppleScript(guid: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-", guid]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return "error: \(error.localizedDescription)" }
        stdin.fileHandleForWriting.write(Data(focusScript.utf8))
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "error: \(detail)"
        }
        return String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
