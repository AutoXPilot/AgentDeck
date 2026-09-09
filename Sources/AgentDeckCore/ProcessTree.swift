import Darwin
import Foundation

public enum ProcessTree {
    /// Short command name (p_comm, 16 chars) and parent pid via sysctl.
    public static func nameAndParent(of pid: pid_t) -> (name: String, ppid: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return (name, info.kp_eproc.e_ppid)
    }

    /// Full executable path. p_comm alone is useless for the claude CLI:
    /// its binary is named after the version (~/.local/share/claude/versions/2.1.220),
    /// so p_comm reads "2.1.220".
    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// When the process at `pid` started. Combined with the pid, this is a
    /// stable process IDENTITY: a recycled pid belongs to a process that
    /// started later than the snapshot that recorded it, so comparing start
    /// time against the snapshot detects reuse directly — no boot-time
    /// guessing required.
    public static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970:
            TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// Hooks run under a shell the CLI spawned, so getppid() is usually
    /// sh — walk ancestors until we find the agent process itself, matching
    /// on the executable path (not p_comm; see above).
    /// Returns nil when no plausible agent ancestor exists; callers should
    /// then omit the pid rather than record a short-lived shell's.
    public static func findAgentAncestor(
        provider: Provider, startingAt pid: pid_t
    ) -> pid_t? {
        var current = pid
        for remaining in stride(from: 12, to: 0, by: -1) {
            guard let (name, ppid) = nameAndParent(of: current) else { return nil }
            let lowerName = name.lowercased()
            let lowerPath = executablePath(of: current)?.lowercased() ?? ""
            // Match on the executable PATH first (the project's stated rule —
            // p_comm is the version number for claude). The node/bun name
            // fallback stays for wrapper-hosted installs where the agent runs
            // via a JS launcher, but only ABOVE the starting process: the
            // start pid is the hook's own short-lived shell, and matching it
            // as "node" would record a pid the liveness sweep deletes at once.
            let depth = 12 - remaining
            let matches: Bool
            switch provider {
            case .claude:
                let pathMatch = lowerName.contains("claude") || lowerPath.contains("claude")
                let wrapperMatch = depth > 0 && (lowerName == "node" || lowerName == "bun")
                matches = pathMatch || wrapperMatch
            case .codex:
                matches = lowerName.contains("codex") || lowerPath.contains("codex")
            }
            if matches { return current }
            guard ppid > 1, ppid != current else { return nil }
            current = ppid
        }
        return nil
    }
}
