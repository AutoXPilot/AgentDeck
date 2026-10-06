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

    /// Claude's `sessionKind` for a daemonized background session —
    /// `claude --bg-pty-host`, started from a slash command and reparented
    /// to launchd.
    public static let backgroundSessionKind = "bg"

    public static func isBackground(sessionKind: String?) -> Bool {
        sessionKind?.lowercased() == backgroundSessionKind
    }

    /// What a click will do, in words.
    ///
    /// An unfocusable row still has to be useful. "Not in a terminal or app
    /// we can focus" is true of a background session but leaves you stuck
    /// in front of a permission prompt with nowhere to go — the prompt is
    /// answered in the agents panel of whichever session spawned it.
    public static func describe(_ target: FocusTarget, sessionKind: String? = nil) -> String {
        switch target {
        case .itermPane:
            return "Click to focus this iTerm pane"
        case .application(_, let name):
            return "Click to bring \(name) to the front"
        case .none where isBackground(sessionKind: sessionKind):
            return "Background session — no window to focus. "
                + "Answer it in the agents panel of the session that started it."
        case .none:
            return "No terminal pane or app recorded — click just dismisses it"
        }
    }
}
