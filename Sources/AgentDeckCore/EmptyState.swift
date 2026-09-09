import Foundation

/// What the popover should say when no rows are showing. Pure and tested
/// because getting the precedence wrong (e.g. telling a user with a live
/// filter that their hooks are broken) is a straight-to-user bug, and this
/// kind of branch selection is exactly what kept escaping in the app target.
public enum EmptyState: Equatable, Sendable {
    /// A filter is applied and matches nothing — checked FIRST so it isn't
    /// masked by a hooks-not-installed message.
    case noFilterMatch(query: String)
    /// The core pipeline isn't wired: the helper or Claude hooks are missing.
    case coreHooksMissing
    /// Everything Claude works, but Codex hooks aren't installed — Codex
    /// sessions won't appear. Informational, not an error.
    case codexHooksMissing
    /// Fully set up, just nothing running (or sessions predate install).
    case idle

    public static func determine(
        helperInstalled: Bool,
        claudeHooksInstalled: Bool,
        codexHooksInstalled: Bool,
        filter: String
    ) -> EmptyState {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return .noFilterMatch(query: trimmed) }
        if !helperInstalled || !claudeHooksInstalled { return .coreHooksMissing }
        if !codexHooksInstalled { return .codexHooksMissing }
        return .idle
    }
}
