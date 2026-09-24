import Foundation

/// Where a row click should take you. Not every agent lives in a terminal:
/// Codex sessions hosted by ChatGPT.app have no iTerm pane, but the owning
/// application is still the right place to land.
public enum FocusTarget: Equatable, Sendable {
    case itermPane(guid: String)
    case application(bundlePath: String, name: String)
    case none

    public var isActionable: Bool { self != .none }
}

public enum FocusResolver {
    /// "/Applications/ChatGPT.app" → "ChatGPT"
    public static func appName(fromBundlePath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".app") else { return nil }
        let base = String(name.dropLast(4))
        return base.isEmpty ? nil : base
    }

    /// A terminal pane wins when we have one — it's the most precise
    /// destination. Otherwise fall back to the owning GUI app.
    public static func resolve(
        terminalSessionId: String?, owningAppBundlePath: String?
    ) -> FocusTarget {
        if let guid = ITermFocus.sessionGUID(from: terminalSessionId) {
            return .itermPane(guid: guid)
        }
        if let path = owningAppBundlePath, let name = appName(fromBundlePath: path) {
            return .application(bundlePath: path, name: name)
        }
        return .none
    }
}
