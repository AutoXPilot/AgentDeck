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
    /// - snapshots from before the last boot (their pids are meaningless,
    ///   and a recycled pid could otherwise keep them alive forever)
    /// - pid-bearing snapshots whose process is gone (crash, terminal close
    ///   without SessionEnd)
    /// - anything idle past `maxIdle` — the backstop for pid-less snapshots
    ///   AND for same-user pid reuse, which no liveness probe can detect
    public static func keysToRemove(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        maxIdle: TimeInterval = 24 * 3600,
        bootedAt: Date? = Liveness.bootTime()
    ) -> [String] {
        snapshots.compactMap { s in
            if let bootedAt, s.updatedAt < bootedAt { return s.key }
            if now.timeIntervalSince(s.updatedAt) > maxIdle { return s.key }
            if let pid = s.agentPid {
                return isAlive(pid: pid) ? nil : s.key
            }
            return nil
        }
    }
}
