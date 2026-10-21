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
    ///
    /// Falls back to argv[0] when the path can't be read. That is not an
    /// edge case here: Claude Code installs each release as a versioned
    /// file and prunes old ones on update, so a session that has been
    /// running a while is executing a binary that no longer exists, and
    /// `proc_pidpath` returns ENOENT for it. Losing the path loses pid
    /// attribution, and a pid-less snapshot falls under the 24-hour idle
    /// cap instead of the 7-day live one — so the longest-running sessions,
    /// the ones most worth keeping on screen, were the ones being deleted.
    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        if n > 0 {
            return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return launchPath(of: pid)
    }

    /// argv[0] via `KERN_PROCARGS2`. Survives the executable being replaced
    /// or deleted, because it is a copy made at exec time.
    ///
    /// Layout: `int argc`, the executable path, NUL padding, then argc
    /// NUL-separated arguments. Only the path is read.
    public static func launchPath(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        let start = MemoryLayout<Int32>.size
        guard let end = buffer[start..<size].firstIndex(of: 0), end > start else { return nil }
        let path = String(decoding: buffer[start..<end], as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" → "/Applications/ChatGPT.app".
    /// Pure so the parsing is testable without a GUI process.
    public static func bundlePath(fromExecutablePath path: String) -> String? {
        guard let marker = path.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(path[path.startIndex..<marker.lowerBound]) + ".app"
    }

    /// The nearest ancestor that is a GUI application bundle. Agents launched
    /// by an app rather than a terminal (e.g. Codex inside ChatGPT.app) have
    /// no terminal pane, but they do have an app worth bringing to the front.
    public static func owningApplicationBundle(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<12 {
            if let path = executablePath(of: current),
               let bundle = bundlePath(fromExecutablePath: path) {
                return bundle
            }
            guard let (_, ppid) = nameAndParent(of: current), ppid > 1, ppid != current else {
                return nil
            }
            current = ppid
        }
        return nil
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

    /// Controlling terminal device name ("ttys018"), or nil for a process
    /// with none — a daemonized background session, or one reparented
    /// after its terminal closed.
    public static func controllingTTY(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, dev != 0, let name = devname(dev, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.isEmpty || tty == "??" ? nil : tty
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

    /// Whether the process at `pid` is plausibly the agent itself: its
    /// executable path or name names the provider, or (Claude only) it is
    /// the node/bun runtime a wrapper-hosted install runs under. A reused
    /// pid is almost always something else — a shell, a helper — which is
    /// what this exists to reject; it is not proof of identity.
    public static func looksLikeAgent(_ pid: pid_t, provider: Provider) -> Bool {
        guard let (name, _) = nameAndParent(of: pid) else { return false }
        let lowerName = name.lowercased()
        let lowerPath = executablePath(of: pid)?.lowercased() ?? ""
        switch provider {
        case .claude:
            if lowerName.contains("claude") || lowerPath.contains("claude") { return true }
            // A node/bun runtime counts only if it is running Claude's
            // script: any long-lived node process that inherited a
            // session's pid would otherwise keep that row forever.
            guard lowerName == "node" || lowerName == "bun" else { return false }
            return argumentsMention("claude", pid: pid)
        case .codex:
            return lowerName.contains("codex") || lowerPath.contains("codex")
        }
    }

    /// Whether any of the process's arguments contains `needle`
    /// (case-insensitive). Reads the same `KERN_PROCARGS2` block as
    /// `launchPath`; the arguments are searched in place and nothing is
    /// kept. Environment variables, which follow them, are not searched.
    static func argumentsMention(_ needle: String, pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return false }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // layout: argc, exec path, NUL padding, then argc NUL-terminated args
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }        // exec path
        while i < size, buffer[i] == 0 { i += 1 }        // padding
        let target = Array(needle.lowercased().utf8)
        for _ in 0..<max(0, Int(argc)) {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            let arg = buffer[start..<i].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            if arg.count >= target.count,
               (0...(arg.count - target.count)).contains(where: {
                   Array(arg[$0..<($0 + target.count)]) == target
               }) {
                return true
            }
            i += 1
        }
        return false
    }
}
