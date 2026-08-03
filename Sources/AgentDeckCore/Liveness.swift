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

    /// Sessions to drop:
    /// - snapshots from before the last boot (their pids are meaningless)
    /// - pid-bearing snapshots whose process is gone (crash, terminal close
    ///   without SessionEnd)
    /// - pid-less snapshots idle past `maxIdle`
    /// - live-pid snapshots idle past `liveMaxIdle`
    ///
    /// The two idle caps differ for a reason discovered in production: a
    /// session blocked on the user emits NO events while it waits, so a 24h
    /// cap silently deleted live sessions that were waiting overnight — and
    /// they could never come back, because nothing fires until the user
    /// answers. Live pids therefore get a much longer backstop, which exists
    /// only for same-user pid reuse (reboots are already covered by the boot
    /// guard above, and that's the common reuse vector).
    public static func keysToRemove(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        maxIdle: TimeInterval = 24 * 3600,
        liveMaxIdle: TimeInterval = 7 * 24 * 3600,
        bootedAt: Date? = Liveness.bootTime()
    ) -> [String] {
        snapshots.compactMap { s in
            if let bootedAt, s.updatedAt < bootedAt { return s.key }
            if let pid = s.agentPid {
                guard isAlive(pid: pid) else { return s.key }
                return now.timeIntervalSince(s.updatedAt) > liveMaxIdle ? s.key : nil
            }
            return now.timeIntervalSince(s.updatedAt) > maxIdle ? s.key : nil
        }
    }
}
