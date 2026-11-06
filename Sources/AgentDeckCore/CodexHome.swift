import Foundation

/// Where Codex keeps its files: `~/.codex` unless `CODEX_HOME` says
/// otherwise. Hooks, rollouts, the thread database and the session index
/// all move with it.
///
/// A menu-bar app is started by launchd, not a shell, so it sees
/// `CODEX_HOME` only when it is set for launchd (`launchctl setenv`); one
/// exported in a shell profile alone isn't visible here. Codex has no
/// settings file outside that folder to read it from, unlike Claude.
public enum CodexHome {
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let dir = environment["CODEX_HOME"], let url = ClaudeConfig.absolute(dir, home: home) {
            return url
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Resolved once per process, like `ClaudeConfig.current`.
    public static let current: URL = directory()
}
