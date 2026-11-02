import Foundation

/// Codex threads run inside a shared app-server daemon (codex-cli 0.166):
/// the `codex` in a terminal is a client, and hooks run as the daemon's
/// children. The daemon's pid and its inherited `ITERM_SESSION_ID` say
/// nothing about where a given thread is shown.
public enum CodexAppServer {
    /// The daemon's install path, or `codex app-server` exactly. Not any
    /// argument containing the words: `codex "fix the app-server bug"` is
    /// an ordinary CLI.
    public static func matches(executablePath: String?, firstArgument: String?) -> Bool {
        if let path = executablePath, path.contains("/app-server-daemon/") { return true }
        return firstArgument == "app-server"
    }

    /// `…/rollout-2026-11-01T23-25-17-<thread id>.jsonl` → the thread id.
    public static func threadId(fromRolloutPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(6)
        guard stem.count >= 36, let uuid = UUID(uuidString: String(stem.suffix(36))) else { return nil }
        return uuid.uuidString.lowercased()
    }

    public struct PaneMatch: Equatable, Sendable {
        public let guid: String
        /// Found by the thread's own name in the title, not by being the
        /// only Codex pane. Only a named match is good enough to mark the
        /// session handled once focused.
        public let byName: Bool
    }

    /// The iTerm pane showing a daemon-run CLI thread. Only panes whose
    /// terminal runs a Codex CLI are candidates. Codex titles the pane
    /// with the thread's name (iTerm shows `<profile> | <name> (codex)`),
    /// so the title must end in exactly that name, not merely contain it:
    /// "web" must not match "webapp". With no name, the only Codex pane is
    /// used, and only for a thread known to be the CLI's (`allowSolePane`):
    /// a ChatGPT or `codex exec` thread has no pane. Anything ambiguous
    /// gives nil: no pane beats the wrong pane.
    public static func pane(threadName: String?, panes: [(guid: String, tty: String, title: String)],
                            codexTTYs: Set<String>, allowSolePane: Bool) -> PaneMatch? {
        let candidates = panes.filter { codexTTYs.contains($0.tty) }
        if let name = threadName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let named = candidates.filter { titleNames($0.title, name) }
            return named.count == 1 ? PaneMatch(guid: named[0].guid, byName: true) : nil
        }
        guard allowSolePane, candidates.count == 1 else { return nil }
        return PaneMatch(guid: candidates[0].guid, byName: false)
    }

    static func titleNames(_ title: String, _ name: String) -> Bool {
        var t = title.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasSuffix(" (codex)") { t = String(t.dropLast(8)) }
        let lowered = t.lowercased(), wanted = name.lowercased()
        return lowered == wanted || lowered.hasSuffix(" | " + wanted)
    }
}
