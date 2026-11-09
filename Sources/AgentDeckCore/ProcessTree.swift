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

    /// Every application bundle on the ancestor chain from `pid`, innermost
    /// first, for `HostClassifier`. Consecutive processes of the same
    /// bundle are listed once.
    public static func ancestorBundlePaths(startingAt pid: pid_t) -> [String] {
        var bundles: [String] = []
        var current = pid
        for _ in 0..<16 {
            if let path = executablePath(of: current),
               let bundle = bundlePath(fromExecutablePath: path), bundles.last != bundle {
                bundles.append(bundle)
            }
            guard let (_, ppid) = nameAndParent(of: current), ppid > 1, ppid != current else {
                break
            }
            current = ppid
        }
        return bundles
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
    /// on the executable path (not p_comm; see above). The per-provider
    /// rule is `ExecutableMatch.matchesAncestor`.
    /// Returns nil when no plausible agent ancestor exists; callers should
    /// then omit the pid rather than record a short-lived shell's.
    public static func findAgentAncestor(
        provider: Provider, startingAt pid: pid_t
    ) -> pid_t? {
        let match = provider.spec.executableMatch
        var current = pid
        for depth in 0..<12 {
            guard let (name, ppid) = nameAndParent(of: current) else { return nil }
            let pid = current
            if match.matchesAncestor(
                name: name, path: executablePath(of: current), depth: depth,
                argvMentions: { argumentsMention($0, pid: pid) }) {
                return current
            }
            guard ppid > 1, ppid != current else { return nil }
            current = ppid
        }
        return nil
    }

    /// Whether the process at `pid` is plausibly the agent itself; see
    /// `ExecutableMatch.looksLikeAgent`.
    public static func looksLikeAgent(_ pid: pid_t, provider: Provider) -> Bool {
        guard let (name, _) = nameAndParent(of: pid) else { return false }
        return provider.spec.executableMatch.looksLikeAgent(
            name: name, path: executablePath(of: pid),
            argvMentions: { argumentsMention($0, pid: pid) })
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
        let target = Array(needle.lowercased().utf8)
        for raw in procArguments(Array(buffer.prefix(size))) {
            let arg = raw.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            if arg.count >= target.count,
               (0...(arg.count - target.count)).contains(where: {
                   Array(arg[$0..<($0 + target.count)]) == target
               }) {
                return true
            }
        }
        return false
    }

    /// The arguments in a `KERN_PROCARGS2` buffer: argc, the exec path, NUL
    /// padding, then up to argc NUL-terminated arguments. Stops at the end
    /// of the buffer whatever argc says.
    static func procArguments(_ buffer: [UInt8]) -> [ArraySlice<UInt8>] {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }        // exec path
        while i < size, buffer[i] == 0 { i += 1 }        // padding
        var arguments: [ArraySlice<UInt8>] = []
        while arguments.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            arguments.append(buffer[start..<i])
            i += 1
        }
        return arguments
    }

    /// Every process id on the machine.
    public static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// Which of `ids` a running agent process of `provider` was started
    /// with — `codex resume <id>` carries the id in its arguments. Codex has
    /// no session registry and runs no hook until the first message after a
    /// resume, so without this a restored Codex session looked like it had
    /// never started. Only processes that look like the provider's agent are
    /// examined, and their arguments are searched in place, not kept.
    public static func sessionsRunning(provider: Provider, ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let wanted = ids.map { $0.lowercased() }
        var found = Set<String>()
        for pid in allPids() where looksLikeAgent(pid, provider: provider) {
            for id in wanted where !found.contains(id) && argumentsMention(id, pid: pid) {
                found.insert(id)
            }
            if found.count == wanted.count { break }
        }
        return found
    }

    public static func codexThreadsRunning(_ threadIds: Set<String>) -> Set<String> {
        sessionsRunning(provider: .codex, ids: threadIds)
    }

    /// Codex's shared app-server daemon (`~/.codex/packages/app-server-daemon/
    /// …/codex app-server`, from 0.166), which runs threads for the CLI and
    /// ChatGPT.app alike. Hooks run under it, so its pid is shared by every
    /// thread and its environment holds whatever pane started it.
    public static func isCodexAppServer(_ pid: pid_t) -> Bool {
        CodexAppServer.matches(executablePath: executablePath(of: pid),
                               firstArgument: argument(1, of: pid))
    }

    /// The shared daemon specifically (by install path), not ChatGPT's own
    /// bundled `codex app-server`, whose pid ChatGPT-hosted rows rely on.
    public static func isCodexSharedDaemon(_ pid: pid_t) -> Bool {
        executablePath(of: pid)?.contains("/app-server-daemon/") == true
    }

    /// One argument of the process (argv[index]), read from `KERN_PROCARGS2`
    /// and not kept. Used only to compare against a fixed word.
    static func argument(_ index: Int, of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        let arguments = procArguments(Array(buffer.prefix(size)))
        guard index >= 0, index < arguments.count else { return nil }
        return String(decoding: arguments[index], as: UTF8.self)
    }

    /// Codex thread ids whose rollout a Codex app-server daemon holds open.
    /// The daemon keeps the rollout of each thread it is running open and
    /// closes it when the thread ends, so this is the daemon-run thread's
    /// running evidence (its CLI client names no thread). Only file paths
    /// are read, from the daemon's own descriptor table.
    public static func codexDaemonOpenThreads(daemons: [pid_t]? = nil) -> Set<String> {
        var ids = Set<String>()
        for pid in daemons ?? codexDaemonPids() {
            for file in openFilePaths(of: pid) {
                if let id = CodexAppServer.threadId(fromRolloutPath: file) { ids.insert(id) }
            }
        }
        return ids
    }

    /// The shared daemon's processes. Walks every process, so callers that
    /// ask often cache it.
    public static func codexDaemonPids() -> [pid_t] {
        allPids().filter { isCodexSharedDaemon($0) }
    }

    static func openFilePaths(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let filled = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                   Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard n == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// Terminals running a Codex CLI (not the daemon). Each process's
    /// executable and arguments are checked in place; nothing is kept.
    public static func codexCLITTYs() -> Set<String> {
        var ttys = Set<String>()
        for pid in allPids() where looksLikeAgent(pid, provider: .codex) && !isCodexAppServer(pid) {
            if let tty = controllingTTY(of: pid) { ttys.insert(tty) }
        }
        return ttys
    }
}
