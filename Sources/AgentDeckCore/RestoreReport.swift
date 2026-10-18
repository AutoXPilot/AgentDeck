import Foundation

/// What a finished restore means, and how to say it. Kept out of the app
/// so the wording — the only feedback a user gets — is tested.
public struct RestoreReport: Equatable, Sendable {
    /// The command was typed; whether the session is running is confirmed
    /// later, from the registry.
    public var typed: [WorkspaceEntry] = []
    /// May have opened. Reserved until seen running or cleared.
    public var uncertain: [WorkspaceEntry] = []
    public var failures: [String] = []
    /// Reservations to drop now: nothing was typed, or the session came
    /// back some other way before its turn.
    public var release: Set<String> = []
    public var total: Int
    public var skipped: [(entry: WorkspaceEntry, reason: WorkspaceRestore.SkipReason)]

    public static func == (a: RestoreReport, b: RestoreReport) -> Bool {
        a.typed == b.typed && a.uncertain == b.uncertain && a.failures == b.failures
            && a.release == b.release && a.total == b.total
            && a.skipped.map(\.entry) == b.skipped.map(\.entry)
            && a.skipped.map(\.reason) == b.skipped.map(\.reason)
    }

    public init(
        launches: [WorkspaceRestore.Launch], outcomes: [String: WorkspaceRestore.Outcome],
        skipped: [(entry: WorkspaceEntry, reason: WorkspaceRestore.SkipReason)]
    ) {
        total = launches.count
        self.skipped = skipped
        for launch in launches {
            let key = launch.entry.key
            switch outcomes[key] {
            case .launched: typed.append(launch.entry)
            case .uncertain: uncertain.append(launch.entry)
            case .failed(let message):
                failures.append(message)
                release.insert(key)
            case nil:
                release.insert(key)
            }
        }
    }

    /// Everything that went wrong, carried into every later message about
    /// this restore — the 30-second confirmation used to replace them.
    var problems: [String] {
        var out: [String] = []
        if !uncertain.isEmpty {
            out.append("\(uncertain.map(\.label).joined(separator: ", ")) may have opened — "
                       + "check iTerm before retrying")
        }
        if let first = failures.first {
            out.append(first.contains("1743")
                ? "AgentDeck needs Automation permission to control iTerm2"
                : "failed: \(first)")
        }
        return out
    }

    func message(_ headline: String) -> String {
        var message = ([headline] + problems).joined(separator: "; ") + "."
        if !skipped.isEmpty { message += " " + WorkspaceRestore.describeSkips(skipped) }
        return message
    }

    /// Right after launching.
    public var startedMessage: String {
        message(typed.isEmpty ? "Started none of \(total)" : "Started \(typed.count) of \(total)")
    }

    /// Once the typed sessions have had time to come up. `notRunning` are
    /// the typed ones the registry doesn't show.
    public func confirmationMessage(notRunning: [WorkspaceEntry]) -> String {
        let running = typed.count - notRunning.count
        return message(notRunning.isEmpty
            ? "Restored \(typed.count) session\(typed.count == 1 ? "" : "s")"
            : "\(running) of \(typed.count) running; not yet: "
                + notRunning.map(\.label).joined(separator: ", ")
                + " — check those tabs for a prompt")
    }
}
