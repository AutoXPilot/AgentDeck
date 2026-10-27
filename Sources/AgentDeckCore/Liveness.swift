import Darwin
import Foundation

public enum Liveness {
    /// kill(pid, 0) == 0 means a process we own exists at that pid.
    /// EPERM (another user's process) counts as DEAD here: claude/codex always
    /// run as the current user, so a pid now owned by someone else's process
    /// is a recycled pid, and treating it as alive makes zombies immortal.
    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// How the sweep sees a pid. Injectable so the deletion logic is testable
    /// without spawning real processes — the class of bug that kept escaping
    /// lived in code that could only be exercised live.
    public struct ProcessProbe: Sendable {
        /// Process start time, or nil if the pid is dead/unreadable.
        public var startTime: @Sendable (Int32) -> Date?
        /// Whether the process is plausibly the agent (see
        /// `ProcessTree.looksLikeAgent`). Test probes default to yes.
        public var isAgent: @Sendable (Int32, Provider) -> Bool
        public init(
            startTime: @escaping @Sendable (Int32) -> Date?,
            isAgent: @escaping @Sendable (Int32, Provider) -> Bool = { _, _ in true }
        ) {
            self.startTime = startTime
            self.isAgent = isAgent
        }
        public static let system = ProcessProbe(
            startTime: { pid in isAlive(pid: pid) ? ProcessTree.startTime(of: pid) : nil },
            isAgent: { pid, provider in ProcessTree.looksLikeAgent(pid, provider: provider) }
        )
    }

    /// A snapshot's pid is TRUSTWORTHY if a process is alive at that pid and
    /// it started at or before the snapshot's last update (+slack). A
    /// recycled pid fails the second test: the new process necessarily
    /// started later than the snapshot that recorded the old one.
    ///
    /// This replaces the old boot-time guard for live pids. `KERN_BOOTTIME`
    /// is wall-clock-derived and drifts forward across sleep-wake/NTP, so a
    /// "snapshot older than boot ⇒ delete" test could wrongly delete a
    /// session started seconds after login — and a waiting session, emitting
    /// no further events, could never come back. Start-time identity has no
    /// such failure mode. `slack` absorbs the gap between a process starting
    /// and its first hook firing. A live pid whose start time can't be read
    /// falls back to liveness alone.
    ///
    /// The process must also look like the agent. Start time alone accepts
    /// a pid reused within `slack` of the last update, forever; the name
    /// check rejects nearly all of those, since a reused pid is almost
    /// never another claude or codex.
    public static func pidIsTrustworthy(
        _ pid: Int32, forUpdatedAt updatedAt: Date, slack: TimeInterval = 120,
        provider: Provider, probe: ProcessProbe = .system
    ) -> Bool {
        guard let started = probe.startTime(pid) else {
            // alive but unreadable start time
            return isAlive(pid: pid) && probe.isAgent(pid, provider)
        }
        return started <= updatedAt.addingTimeInterval(slack) && probe.isAgent(pid, provider)
    }

    /// Sessions to drop:
    /// - pid-bearing snapshots whose pid is dead OR belongs to a *different*
    ///   process now (reuse, or not the agent at all), OR — only when the
    ///   start time can't be read to confirm it — idle past `liveMaxIdle`
    /// - pid-less snapshots from before the last boot, or idle past `maxIdle`
    ///
    /// The two idle caps differ for a reason discovered in production: a
    /// session blocked on the user emits NO events while it waits, so a 24h
    /// cap silently deleted live sessions waiting overnight — and they could
    /// never come back. A live, identity-verified pid is never expired for
    /// being quiet.
    /// `confirmedLive` names session KEYS another source has independently
    /// verified as running (Claude's registry). Keys, not bare session ids,
    /// so one provider's evidence can never protect another provider's
    /// snapshot that happens to share an id. Their snapshots are never
    /// aged out: deleting one doesn't hide the session any more — discovery
    /// re-adds it on the same key — it just silently strips the pane id,
    /// permission mode and hook-derived state, leaving a row that looks
    /// fine but can no longer be clicked to its terminal.
    public static func keysToRemove(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        maxIdle: TimeInterval = 24 * 3600,
        liveMaxIdle: TimeInterval = 7 * 24 * 3600,
        startSlack: TimeInterval = 120,
        bootedAt: Date? = Liveness.bootTime(),
        confirmedLive: Set<String> = [],
        liveByPid: [Int32: ClaudeSessionRegistry.Entry] = [:],
        probe: ProcessProbe = .system
    ) -> [String] {
        snapshots.compactMap { s in
            if confirmedLive.contains(s.key) { return nil }
            // Superseded: after /clear the process keeps running under a new
            // session id, and the registry, observed after this snapshot was
            // last written, names that new one for this pid. The old
            // conversation's row would otherwise live as long as the
            // process. Only when the registry is the newer of the two — a
            // brand-new session's first hook can land before its registry
            // entry is rewritten.
            if s.provider == .claude, let pid = s.agentPid, let live = liveByPid[pid],
               live.sessionId != s.sessionId,
               (live.observedAt ?? .distantPast) > s.updatedAt {
                return s.key
            }
            if let pid = s.agentPid {
                guard pidIsTrustworthy(
                    pid, forUpdatedAt: s.updatedAt, slack: startSlack,
                    provider: s.provider, probe: probe
                ) else { return s.key }
                // A verified-live agent is not expired for being quiet. A
                // Codex session left waiting for input over a long weekend
                // used to lose its row — and then, gone from every live
                // set, be offered for restore while still running.
                // `liveMaxIdle` now applies only where liveness can't be
                // confirmed by start time.
                if probe.startTime(pid) != nil { return nil }
                return now.timeIntervalSince(s.updatedAt) > liveMaxIdle ? s.key : nil
            }
            // no pid to identity-check: the boot guard is the only reuse
            // defense left, with slack for the login-item race.
            if let bootedAt, s.updatedAt < bootedAt.addingTimeInterval(-startSlack) {
                return s.key
            }
            return now.timeIntervalSince(s.updatedAt) > maxIdle ? s.key : nil
        }
    }
}
