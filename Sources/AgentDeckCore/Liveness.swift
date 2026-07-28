import Darwin
import Foundation

public enum Liveness {
    /// kill(pid, 0) probes existence without signaling.
    /// EPERM means "exists but not ours" — still alive.
    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Sessions whose agent process died (crash, terminal closed without a
    /// SessionEnd hook, or Codex which has no SessionEnd at all), plus
    /// pid-less snapshots that have been silent for `maxIdle`.
    public static func keysToRemove(
        _ snapshots: [SessionSnapshot],
        now: Date = Date(),
        maxIdle: TimeInterval = 24 * 3600
    ) -> [String] {
        snapshots.compactMap { s in
            if let pid = s.agentPid {
                return isAlive(pid: pid) ? nil : s.key
            }
            return now.timeIntervalSince(s.updatedAt) > maxIdle ? s.key : nil
        }
    }
}
