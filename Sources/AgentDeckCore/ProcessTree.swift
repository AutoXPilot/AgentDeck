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

    /// Hooks run under a shell the CLI spawned, so getppid() is usually
    /// sh — walk ancestors until we find the agent process itself.
    /// Returns nil when no plausible agent ancestor exists; callers should
    /// then omit the pid rather than record a short-lived shell's.
    public static func findAgentAncestor(
        provider: Provider, startingAt pid: pid_t
    ) -> pid_t? {
        var current = pid
        for _ in 0..<12 {
            guard let (name, ppid) = nameAndParent(of: current) else { return nil }
            let lower = name.lowercased()
            let matches: Bool
            switch provider {
            case .claude:
                matches = lower.contains("claude") || lower == "node" || lower == "bun"
            case .codex:
                matches = lower.contains("codex")
            }
            if matches { return current }
            guard ppid > 1, ppid != current else { return nil }
            current = ppid
        }
        return nil
    }
}
