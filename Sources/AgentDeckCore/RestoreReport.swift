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
    /// - notRunning: typed but not registered as running.
    /// - awaitingConfirmation: running, but stopped at a question in its tab
    ///   (Claude asks before resuming a long conversation idle for a while).
    /// - homeDirectory: Claude asks whether to trust the home folder on every
    ///   launch and never remembers the answer there, so a session started
    ///   in it always stops at that question — the usual reason a restore
    ///   "didn't start". Named, so the user knows what to answer.
    public func confirmationMessage(
        notRunning: [WorkspaceEntry], awaitingConfirmation: [WorkspaceEntry] = [],
        homeDirectory: String? = nil
    ) -> String {
        let running = typed.count - notRunning.count
        guard !notRunning.isEmpty || !awaitingConfirmation.isEmpty else {
            return message("Restored \(typed.count) session\(typed.count == 1 ? "" : "s")")
        }
        var parts: [String] = []
        let home = homeDirectory.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let inHome = notRunning.filter { home != nil && $0.cwd == home }
        let elsewhere = notRunning.filter { home == nil || $0.cwd != home }
        if !inHome.isEmpty {
            parts.append(names(inHome) + " — Claude asks whether to trust your home folder "
                         + "every time; answer it in \(inHome.count == 1 ? "that tab" : "those tabs")")
        }
        if !elsewhere.isEmpty {
            parts.append(names(elsewhere) + " — check \(elsewhere.count == 1 ? "that tab" : "those tabs") "
                         + "for a prompt")
        }
        if !awaitingConfirmation.isEmpty {
            // the registry says only "dialog open"; the usual one after a
            // restore is Claude asking before resuming a long, idle
            // conversation, so it's named as likely, not certain
            parts.append(names(awaitingConfirmation) + " — waiting on a question in "
                         + "\(awaitingConfirmation.count == 1 ? "its tab" : "their tabs") "
                         + "(usually Claude asking whether to resume a long, idle conversation)")
        }
        let headline = notRunning.isEmpty
            ? "Restored \(typed.count); waiting on you"
            : "\(running) of \(typed.count) running; not yet"
        return message(headline + ": " + parts.joined(separator: "; "))
    }

    private func names(_ entries: [WorkspaceEntry]) -> String {
        let labels = entries.map(\.label)
        return labels.prefix(5).joined(separator: ", ")
            + (labels.count > 5 ? " +\(labels.count - 5) more" : "")
    }
}
