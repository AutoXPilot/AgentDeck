import Foundation

/// Codex threads run inside a shared app-server daemon (codex-cli 0.166):
/// the `codex` in a terminal is a client, and hooks run as the daemon's
/// children. The daemon's pid and its inherited `ITERM_SESSION_ID` say
/// nothing about where a given thread is shown.
public enum CodexAppServer {
    public static func matches(executablePath: String?, argvMentionsAppServer: Bool) -> Bool {
        if let path = executablePath, path.contains("/app-server-daemon/") { return true }
        return argvMentionsAppServer
    }

    /// The iTerm pane showing a daemon-run CLI thread. Only panes whose
    /// terminal runs a Codex CLI are candidates. Codex titles the pane with
    /// the thread's name, so a unique title match wins; with no name, the
    /// only Codex pane is used. Anything ambiguous gives nil: no pane beats
    /// the wrong pane.
    public static func pane(threadName: String?, panes: [(guid: String, tty: String, title: String)],
                            codexTTYs: Set<String>) -> String? {
        let candidates = panes.filter { codexTTYs.contains($0.tty) }
        if let name = threadName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let named = candidates.filter { $0.title.localizedCaseInsensitiveContains(name) }
            return named.count == 1 ? named[0].guid : nil
        }
        return candidates.count == 1 ? candidates[0].guid : nil
    }
}
