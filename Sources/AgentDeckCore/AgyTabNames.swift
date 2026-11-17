import Foundation

/// Names agy's iTerm tabs after the conversation's title, as the row shows
/// it. agy sets no terminal title of its own, so its tabs read "agy" or
/// whatever the shell left ("cd" after a restore, "agy" after a relaunch:
/// oh-my-zsh titles a tab after each command it runs).
///
/// A pane is renamed when the title, or the agy process in it, differs from
/// the last rename AgentDeck made there; never merely because the tab's
/// current name differs, so a name typed into the tab stays until then.
/// A new agy process in the same pane gets the name again: launching it
/// let the shell retitle the tab.
public struct AgyTabNames: Equatable, Sendable {
    public struct Given: Equatable, Sendable {
        public var title: String
        public var pid: Int32

        public init(title: String, pid: Int32) {
            self.title = title
            self.pid = pid
        }
    }

    /// Pane GUID → the last rename made there, and for which process.
    public private(set) var given: [String: Given] = [:]

    public init() {}

    /// The renames due now: pane → title, for agy rows with a title, a known
    /// pane and a pid.
    public func due(_ targets: [String: Given]) -> [String: String] {
        targets.filter { pane, target in !target.title.isEmpty && given[pane] != target }
            .mapValues(\.title)
    }

    /// Records a rename iTerm confirmed.
    public mutating func confirm(pane: String, as target: Given) {
        given[pane] = target
    }

    /// Forgets renames made for processes no longer running agy. Keyed by
    /// process, not by which panes the last listing saw: a listing that came
    /// back partial would otherwise make every rename look new, and each
    /// would overwrite a name typed into the tab.
    public mutating func keepOnly(pids: Set<Int32>) {
        given = given.filter { pids.contains($0.value.pid) }
    }
}
