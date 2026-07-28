import Foundation

public enum ITermFocus {
    /// ITERM_SESSION_ID looks like "w0t2p1:1D5C29F2-...-UUID".
    /// The reveal URL wants the GUID part (iterm2.com/documentation-command-selection.html).
    public static func revealURL(terminalSessionId: String?) -> URL? {
        guard let raw = terminalSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let id: String
        if let colon = raw.lastIndex(of: ":") {
            id = String(raw[raw.index(after: colon)...])
        } else {
            id = raw
        }
        guard !id.isEmpty,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-")))
        else { return nil }
        return URL(string: "iterm2:///reveal?sessionid=\(encoded)")
    }
}
