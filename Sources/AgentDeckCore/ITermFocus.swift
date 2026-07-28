import Foundation

public enum ITermFocus {
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
