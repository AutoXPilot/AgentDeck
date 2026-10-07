import Foundation

/// What the binary was asked to do.
///
/// This lives in core because the bug it fixes was exactly the kind that
/// hides in `main.swift`: `--version` was documented in the README but
/// never implemented, so it fell through to "run the app" — and so did
/// every typo, silently starting a second menu-bar instance that raced the
/// live one over the same state files.
public enum LaunchAction: Equatable, Sendable {
    case runApp
    case printVersion
    case printHelp
    case renderPopover(path: String)
    /// Message for stderr; the caller exits 64 (EX_USAGE).
    case usageError(String)
}

public enum LaunchArguments {
    /// `arguments` is everything after the executable name.
    public static func parse(_ arguments: [String]) -> LaunchAction {
        guard let first = arguments.first else { return .runApp }
        switch first {
        case "--version", "-v":
            return .printVersion
        case "--help", "-h":
            return .printHelp
        case "--render-popover":
            guard arguments.count > 1, !arguments[1].isEmpty else {
                return .usageError("usage: AgentDeck --render-popover <out.png>")
            }
            return .renderPopover(path: arguments[1])
        default:
            // Single-dash arguments are not ours: LaunchServices and Xcode
            // pass their own (`-psn_…`, `-NSDocumentRevisionsDebugMode`),
            // and rejecting those would break launching from Finder.
            guard first.hasPrefix("--") else { return .runApp }
            return .usageError("AgentDeck: unknown option '\(first)'. Try --help.")
        }
    }

    public static func helpText(version: String) -> String {
        """
        AgentDeck \(version) — menu-bar monitor for Claude Code and Codex

        usage: AgentDeck [--version | --help]
               AgentDeck --render-popover <out.png>

        With no arguments, runs as a menu-bar app.
        """
    }
}
