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
    /// Policy runs only the organization's hooks. Claude sessions still
    /// appear, from Claude's own session files; there just aren't any.
    /// Checked before the helper: on such a Mac nothing ever runs the
    /// helper, so asking for it to be installed would be wrong.
    case hooksBlockedByPolicy
    /// Claude works, but these providers' hooks aren't installed — their
    /// sessions won't appear. Informational, not an error.
    case secondaryHooksMissing([Provider])
    /// Fully set up, just nothing running (or sessions predate install).
    case idle

    /// The provider whose hooks the core pipeline depends on.
    static let core: Provider = .claude

    public static func determine(
        helperInstalled: Bool,
        statuses: [Provider: HookStatus],
        filter: String
    ) -> EmptyState {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return .noFilterMatch(query: trimmed) }
        let coreStatus = statuses[core] ?? .missing
        if coreStatus == .blockedByPolicy { return .hooksBlockedByPolicy }
        if !helperInstalled || coreStatus == .missing { return .coreHooksMissing }
        let missing = Provider.allCases.filter { $0 != core && statuses[$0] == .missing }
        if !missing.isEmpty { return .secondaryHooksMissing(missing) }
        return .idle
    }
}
