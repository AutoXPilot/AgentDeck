import Foundation

/// Claude Code sessions hosted by the Claude desktop app (its Code tab).
/// They run inside the app, so there is no pane to focus and nothing to
/// restore into iTerm. Sessions Desktop merely *lists* — ordinary `claude`
/// processes in a terminal, shown through Remote Control — are terminal
/// sessions and are not affected by anything here.
///
/// Only metadata is used: the host, the transcript's `entrypoint`, and the
/// working directory. Desktop's own session files and titles are never
/// read; a title is derived from the conversation.
public enum ClaudeDesktop {
    /// The outer application, which is what a click should bring forward.
    public static let bundlePath = "/Applications/Claude.app"
    /// The transcript `entrypoint` of a session Desktop started.
    public static let entrypoint = "claude-desktop"

    /// Desktop runs Claude Code from an inner bundle it downloads itself
    /// (`…/Application Support/Claude/claude-code/<version>/<hash>/claude.app`).
    /// Activating that brings nothing useful forward.
    public static func isInnerBundle(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let root = (home as NSString).appendingPathComponent(
            "Library/Application Support/Claude/claude-code") + "/"
        return path.hasPrefix(root) && (path as NSString).lastPathComponent.lowercased() == "claude.app"
    }

    /// The outer Desktop bundle, wherever it is installed.
    static func isOuterBundle(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "Claude.app"
    }

    /// Where Desktop puts sessions started without a project folder.
    public static func scratchRoot(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(
            "Library/Application Support/Claude/scratch-workspaces")
    }

    /// A working directory inside Desktop's scratch workspaces — only
    /// Desktop creates these. The root itself doesn't count.
    public static func isScratchWorkspace(_ cwd: String, home: String = NSHomeDirectory()) -> Bool {
        guard cwd.hasPrefix("/") else { return false }
        let standardized = (cwd as NSString).standardizingPath
        return standardized.hasPrefix(scratchRoot(home: home) + "/")
    }

    /// Where a Claude session runs, all evidence considered.
    ///
    /// - A terminal verified from the process ancestry (a bundle was found)
    ///   wins: someone running `claude` in iTerm from inside a scratch
    ///   folder is still in iTerm.
    /// - A recorded app host is kept, but Desktop's inner bundle (or no
    ///   bundle at all, which only a `claude-desktop` entrypoint produces)
    ///   becomes the outer `Claude.app`.
    /// - Otherwise the transcript's `claude-desktop` entrypoint or a scratch
    ///   working directory makes it a Desktop session. An inherited
    ///   `ITERM_SESSION_ID` doesn't outweigh either.
    /// - Anything else is the recorded host, unknown included.
    public static func effectiveHost(
        recorded: SessionHost, transcriptEntrypoint: String?, cwd: String,
        home: String = NSHomeDirectory()
    ) -> SessionHost {
        if recorded.kind == .terminal, recorded.bundlePath != nil { return recorded }
        if recorded.kind == .app {
            guard let path = recorded.bundlePath, !isInnerBundle(path, home: home) else {
                return SessionHost(kind: .app, bundlePath: bundlePath)
            }
            return recorded
        }
        if transcriptEntrypoint == entrypoint || isScratchWorkspace(cwd, home: home) {
            return SessionHost(kind: .app, bundlePath: bundlePath)
        }
        return recorded
    }

    /// The host is the Claude desktop app.
    public static func isDesktopHost(_ host: SessionHost, home: String = NSHomeDirectory()) -> Bool {
        guard host.kind == .app, let path = host.bundlePath else { return false }
        return isOuterBundle(path) || isInnerBundle(path, home: home)
    }

    /// Whether a remembered session runs inside an app, by whatever
    /// evidence there is now: the live row's host, the transcript's
    /// entrypoint, the working directory. Workspace records are
    /// append-only, so entries captured by older builds — or while the
    /// host was still unknown — can name one.
    public static func isAppHosted(
        _ entry: WorkspaceEntry, liveHost: SessionHost?, transcriptEntrypoint: String?,
        home: String = NSHomeDirectory()
    ) -> Bool {
        guard entry.provider == .claude else { return liveHost?.kind == .app }
        return effectiveHost(
            recorded: liveHost ?? .unknown, transcriptEntrypoint: transcriptEntrypoint,
            cwd: entry.cwd, home: home
        ).kind == .app
    }

    /// "scratch-2026-10-19-64df10" → "scratch 2026-10-19"; anything else
    /// unchanged.
    public static func folderLabel(_ folder: String) -> String {
        let parts = folder.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "scratch",
              parts[1].count == 4, parts[2].count == 2, parts[3].count == 2,
              parts[1...3].allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              !parts[4].isEmpty, parts[4].allSatisfy(\.isHexDigit)
        else { return folder }
        return "scratch \(parts[1])-\(parts[2])-\(parts[3])"
    }

    /// A Desktop row's title, and whether it needs a separate "Desktop"
    /// tag (it doesn't when the title already says so).
    ///
    /// The registry name only when the user set it: a missing source
    /// (older builds) or a generated name can come from the conversation.
    /// Desktop's own session title is never consulted, for the same reason.
    public static func rowLabel(
        registryName: String?, nameSource: String?, cwd: String
    ) -> (title: String, showsTag: Bool) {
        if nameSource == "user", let name = registryName, !name.isEmpty {
            return (name, true)
        }
        let folder = (cwd as NSString).lastPathComponent
        guard !folder.isEmpty, folder != "/" else { return ("Claude Desktop", false) }
        return ("Claude Desktop · \(folderLabel(folder))", false)
    }
}
