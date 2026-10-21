import Foundation

/// Which rows a workspace remembers, and as what. Pure, so the rules —
/// including the privacy one about names — are tested rather than living
/// in app code nothing exercises.
public enum WorkspaceCapture {
    /// What's known about where a session's terminal is.
    public enum Terminal: Equatable, Sendable {
        /// Its controlling terminal is an iTerm pane, or a hook recorded
        /// one.
        case iTerm
        /// Its terminal is known and isn't any iTerm pane: Terminal.app,
        /// an editor's terminal. Restoring it would put it somewhere new.
        case elsewhere
        /// iTerm's panes haven't been listed yet, or there's no terminal
        /// to look up. Not grounds for leaving it out.
        case unknown
    }

    /// The remembered form of a row, or nil for one that can't be brought
    /// back into an iTerm tab: a background session (no window to return
    /// to), a Codex session hosted by an app, a session known to run
    /// outside iTerm, or a Claude session with no sign it was interactive.
    ///
    /// `displayName` is only a name someone chose — a user-set Claude name
    /// or a Codex `/rename` — never a generated name or a terminal title,
    /// either of which can be derived from the conversation.
    public static func entry(
        for s: SessionSnapshot,
        registry: ClaudeSessionRegistry.Entry?,
        transcriptSessionKind: String?,
        codexName: String?,
        terminal: Terminal,
        now: Date
    ) -> WorkspaceEntry? {
        if terminal == .elsewhere { return nil }
        switch s.provider {
        case .claude:
            let kind = registry?.kind ?? transcriptSessionKind
            if FocusResolver.isBackground(sessionKind: kind) { return nil }
            guard registry?.kind == "interactive" || s.terminalSessionId != nil else { return nil }
            let cwd = registry?.cwd ?? s.projectPath
            guard !cwd.isEmpty else { return nil }
            return WorkspaceEntry(
                provider: .claude, sessionId: s.sessionId, cwd: cwd,
                // Explicitly user-set only. Claude builds before about
                // 2.1.248 record no source at all, though they already
                // generated names — so a missing source isn't a user's.
                displayName: registry?.nameSource == "user" ? registry?.name : nil,
                permissionMode: s.permissionMode, lastSeen: now
            )
        case .codex:
            guard s.terminalSessionId != nil, !s.projectPath.isEmpty else { return nil }
            return WorkspaceEntry(
                provider: .codex, sessionId: s.sessionId, cwd: s.projectPath,
                displayName: (codexName?.isEmpty == false) ? codexName : nil,
                permissionMode: s.permissionMode, lastSeen: now
            )
        }
    }
}
