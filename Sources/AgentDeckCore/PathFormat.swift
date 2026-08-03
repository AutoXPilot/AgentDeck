import Foundation

public enum PathFormat {
    /// Rows are 360pt wide and every path starts with the same home prefix,
    /// so show `~/…/parent/leaf` instead of burning half the row on
    /// "/Users/<name>/Code/".
    public static func abbreviate(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        components: Int = 2
    ) -> String {
        var text = path
        if !home.isEmpty, text == home {
            return "~"
        }
        if !home.isEmpty, text.hasPrefix(home + "/") {
            text = "~/" + String(text.dropFirst(home.count + 1))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > components + 1 else { return text }
        let tail = parts.suffix(components).joined(separator: "/")
        let prefix = text.hasPrefix("~") ? "~/…/" : "…/"
        return prefix + tail
    }
}
