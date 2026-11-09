import Foundation

/// Where a row click should take you. Not every agent lives in a terminal:
/// Codex sessions hosted by ChatGPT.app have no iTerm pane, but the owning
/// application is still the right place to land.
public enum FocusTarget: Equatable, Sendable {
    case itermPane(guid: String)
    case application(bundlePath: String, name: String)
    /// A link the hosting app opens to the exact session — ChatGPT's
    /// `codex://threads/<id>`. Dispatching it doesn't prove it landed, so
    /// like `.application` it never acknowledges a session that needs you.
    case appURL(URL, name: String)
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
    /// destination — unless the session is known to run in an app: then a
    /// pane id can only be inherited (a GUI launched from an iTerm shell
    /// passes ITERM_SESSION_ID to everything it starts), and the app itself,
    /// its outermost bundle, is where the session is. Otherwise fall back
    /// to the owning GUI app.
    public static func resolve(
        terminalSessionId: String?, owningAppBundlePath: String?, host: SessionHost = .unknown,
        provider: Provider? = nil, sessionId: String? = nil, isBackground: Bool = false
    ) -> FocusTarget {
        // Nothing to reach, whatever the process tree says: every background
        // worker descends from one daemon, itself a child of whichever
        // window started it, so its owning app and host are that window's.
        if isBackground { return .none }
        if host.kind == .app,
           let path = host.bundlePath ?? owningAppBundlePath, let name = appName(fromBundlePath: path) {
            if let provider, let sessionId,
               let url = deepLink(provider: provider, sessionId: sessionId, hostBundlePath: path) {
                return .appURL(url, name: name)
            }
            return .application(bundlePath: path, name: name)
        }
        if let guid = ITermFocus.sessionGUID(from: terminalSessionId) {
            return .itermPane(guid: guid)
        }
        if let path = owningAppBundlePath, let name = appName(fromBundlePath: path) {
            return .application(bundlePath: path, name: name)
        }
        return .none
    }

    /// A link that opens this exact session in its host app, where one is
    /// known to work. Verified: ChatGPT handles `codex://threads/<thread id>`
    /// by opening that thread. The id must parse as a UUID, so nothing but
    /// a canonical id can reach the URL.
    public static func deepLink(provider: Provider, sessionId: String, hostBundlePath: String) -> URL? {
        guard provider == .codex,
              (hostBundlePath as NSString).lastPathComponent == "ChatGPT.app",
              let uuid = UUID(uuidString: sessionId) else { return nil }
        return URL(string: "codex://threads/\(uuid.uuidString.lowercased())")
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
    public static func describe(_ target: FocusTarget, sessionKind: String? = nil,
                                inAgentsView: Bool = false) -> String {
        switch target {
        case .itermPane where inAgentsView:
            return "Click to open this session in its agents view"
        case .itermPane:
            return "Click to focus this iTerm pane"
        case .application(_, let name):
            return "Click to bring \(name) to the front"
        case .appURL(_, let name):
            return "Click to open this thread in \(name)"
        case .none where isBackground(sessionKind: sessionKind):
            return "Background session — no window to focus. "
                + "Answer it in the agents panel of the session that started it."
        case .none:
            return "No terminal pane or app recorded — click just dismisses it"
        }
    }
}
