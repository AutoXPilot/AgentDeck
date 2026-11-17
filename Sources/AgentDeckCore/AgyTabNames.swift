import Foundation

/// Names agy's iTerm tabs after the conversation's title, as the row shows
/// it. agy sets no terminal title of its own, so its tabs read "agy" or
/// whatever the shell left ("cd" after a restore).
///
/// A tab is renamed only when its conversation's title differs from the
/// last one AgentDeck gave that pane, never merely because the tab's
/// current name differs: a name typed into the tab by hand stays until agy's
/// title changes.
public struct AgyTabNames: Equatable, Sendable {
    /// Pane GUID → the title last given to it.
    public private(set) var given: [String: String] = [:]

    public init() {}

    /// The renames due now: pane → title, for agy conversations with a
    /// title and a known pane.
    public func due(titleByPane: [String: String]) -> [String: String] {
        titleByPane.filter { pane, title in !title.isEmpty && given[pane] != title }
    }

    /// Records a rename iTerm confirmed. Panes no longer running agy are
    /// forgotten, so a pane reused by a later conversation is named afresh.
    public mutating func confirm(pane: String, title: String) {
        given[pane] = title
    }

    public mutating func keepOnly(_ panes: Set<String>) {
        given = given.filter { panes.contains($0.key) }
    }
}
