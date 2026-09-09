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
        public init(startTime: @escaping @Sendable (Int32) -> Date?) {
            self.startTime = startTime
        }
        public static let system = ProcessProbe { pid in
            isAlive(pid: pid) ? ProcessTree.startTime(of: pid) : nil
        }
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
    static func pidIsTrustworthy(
        _ pid: Int32, forUpdatedAt updatedAt: Date, slack: TimeInterval,
        probe: ProcessProbe
    ) -> Bool {
        guard let started = probe.startTime(pid) else {
            return isAlive(pid: pid)  // alive but unreadable start time
        }
        return started <= updatedAt.addingTimeInterval(slack)
    }

    /// Sessions to drop:
    /// - pid-bearing snapshots whose pid is dead OR belongs to a *different*
    ///   process now (reuse), OR idle past `liveMaxIdle`
    /// - pid-less snapshots from before the last boot, or idle past `maxIdle`
    ///
    /// The two idle caps differ for a reason discovered in production: a
    /// session blocked on the user emits NO events while it waits, so a 24h
    /// cap silently deleted live sessions waiting overnight — and they could
    /// never come back. Live, identity-verified pids get a long backstop.
    public static func keysToRemove(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        maxIdle: TimeInterval = 24 * 3600,
        liveMaxIdle: TimeInterval = 7 * 24 * 3600,
        startSlack: TimeInterval = 120,
        bootedAt: Date? = Liveness.bootTime(),
        probe: ProcessProbe = .system
    ) -> [String] {
        snapshots.compactMap { s in
            if let pid = s.agentPid {
                guard pidIsTrustworthy(
                    pid, forUpdatedAt: s.updatedAt, slack: startSlack, probe: probe
                ) else { return s.key }
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
