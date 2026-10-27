import Foundation

/// What hosts a session: a terminal, an application, or unknown. Unknown
/// is not app — it means the evidence ran out (the process walk failed and
/// nothing else says), and callers keep today's terminal-first behaviour.
public enum HostKind: String, Sendable {
    case terminal
    case app
}

public struct SessionHost: Equatable, Sendable {
    public var kind: HostKind?
    /// The outermost application bundle, when one was found.
    public var bundlePath: String?

    public init(kind: HostKind?, bundlePath: String? = nil) {
        self.kind = kind
        self.bundlePath = bundlePath
    }

    public static let unknown = SessionHost(kind: nil)
}

public enum HostClassifier {
    /// Bundle file names of terminals. A session under one of these lives
    /// in a pane; anything else hosting it is an application.
    public static let terminalBundleNames: Set<String> = [
        "iterm.app", "iterm2.app", "terminal.app", "ghostty.app", "kitty.app",
        "alacritty.app", "wezterm.app", "warp.app",
    ]

    /// `ancestorBundlePaths`: every `.app` on the agent's ancestor chain,
    /// innermost first. The outermost decides, because an app can bundle
    /// its own inner app (Claude Desktop runs Claude Code from a nested
    /// `claude.app`), and activating that inner bundle brings nothing
    /// useful forward.
    ///
    /// A verified app host wins over `ITERM_SESSION_ID`: a GUI launched
    /// from an iTerm shell inherits that variable, and so does every agent
    /// it starts, so the variable alone would send a click to a pane the
    /// session isn't in. It is used only when no bundle was found.
    public static func classify(
        ancestorBundlePaths: [String],
        terminalSessionId: String?,
        transcriptEntrypoint: String?
    ) -> SessionHost {
        if let outermost = ancestorBundlePaths.last {
            let name = (outermost as NSString).lastPathComponent.lowercased()
            return terminalBundleNames.contains(name)
                ? SessionHost(kind: .terminal, bundlePath: outermost)
                : SessionHost(kind: .app, bundlePath: outermost)
        }
        if transcriptEntrypoint == "claude-desktop" {
            return SessionHost(kind: .app)
        }
        if let id = terminalSessionId, !id.isEmpty {
            return SessionHost(kind: .terminal)
        }
        return .unknown
    }
}

extension SessionSnapshot {
    /// The recorded host; a kind this build doesn't know reads as unknown.
    public var host: SessionHost {
        SessionHost(kind: hostKind.flatMap(HostKind.init(rawValue:)), bundlePath: hostBundlePath)
    }
}
