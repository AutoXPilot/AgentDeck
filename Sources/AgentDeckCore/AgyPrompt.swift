import Foundation

/// An agy permission prompt, inferred: agy has no hook for one.
///
/// A `run_command` call fires PreToolUse before agy decides whether to
/// ask, then PostInvocation at once (before the tool runs or the prompt
/// shows), and PostToolUse once it finishes. Approved, the command runs as
/// a child of agy (`zsh -c …`); while agy waits for approval there is none
/// (observed, agy 1.5.10). So a started `run_command` whose agy has no child
/// on two looks a few seconds apart is a prompt on screen. Shown as "may
/// need you", since it is inferred. A long-lived child of agy (a server it
/// started, a second command) hides a prompt: a miss, never a false alarm.
public struct AgyPromptWatch: Sendable {
    /// Long enough that a command just approved has started its shell.
    public static let threshold: TimeInterval = 10
    /// Between the two childless looks: one look can fall between a
    /// command's processes.
    public static let confirmGap: TimeInterval = 5

    private struct Look: Sendable {
        var call: Date
        var firstChildless: Date
    }
    private var looks: [String: Look] = [:]

    public init() {}

    /// A row that could be a prompt, before looking at its processes.
    public static func isCandidate(_ row: SessionSnapshot, now: Date) -> Bool {
        row.provider == .antigravity && row.state == .working
            && row.event == "PreToolUse" && row.pendingTool == "run_command"
            && row.agentPid != nil && now.timeIntervalSince(row.updatedAt) >= threshold
    }

    /// Row key → when the prompt began, for rows that look like one now and
    /// did at least `confirmGap` earlier, for the same call. `rows` must
    /// already have the pid that runs the conversation now
    /// (`SessionPipeline.correctedAgyRow`). `hasChild` nil: can't tell, which
    /// starts over.
    public mutating func observe(_ rows: [SessionSnapshot], now: Date,
                                 hasChild: (Int32) -> Bool?) -> [String: Date] {
        var kept: [String: Look] = [:]
        var since: [String: Date] = [:]
        for row in rows where Self.isCandidate(row, now: now) {
            guard let pid = row.agentPid, hasChild(pid) == false else { continue }
            let look = looks[row.key].flatMap { $0.call == row.updatedAt ? $0 : nil }
                ?? Look(call: row.updatedAt, firstChildless: now)
            kept[row.key] = look
            if now.timeIntervalSince(look.firstChildless) >= Self.confirmGap {
                since[row.key] = row.updatedAt
            }
        }
        looks = kept
        return since
    }
}
