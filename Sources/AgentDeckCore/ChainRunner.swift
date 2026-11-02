import Foundation

/// Runs the user's own status line command behind the tee, so it behaves
/// as if Claude or agy had run it directly: same stdin bytes, same cwd and
/// environment, its stdout and exit code passed back unchanged.
///
/// Unlike `BoundedSubprocess` (which merges stderr into stdout and writes
/// stdin before its timeout starts), stderr goes to our stderr so it can
/// never appear in the status line, stdin is fed on its own thread so a
/// command that never reads it can't block us, and the command runs in its
/// own process group so a timeout or a cancelled refresh kills everything
/// the shell started.
public enum ChainRunner {
    public struct Result: Equatable, Sendable {
        public let stdout: Data
        /// Exit status, or 128 + signal when it was killed.
        public let status: Int32
        public let timedOut: Bool
    }

    /// The running command's process group, for the helper's signal
    /// handler: Claude cancels a superseded status line run with SIGTERM,
    /// and the command must die with us rather than linger.
    public nonisolated(unsafe) static var activeGroup: pid_t = 0

    public static func run(command: String, input: Data, timeout: TimeInterval = 5) -> Result {
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { return Result(stdout: Data(), status: 127, timedOut: false) }
        guard pipe(&outPipe) == 0 else {
            close(inPipe[0]); close(inPipe[1])
            return Result(stdout: Data(), status: 127, timedOut: false)
        }
        // ours: never inherited by the child
        _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addclose(&actions, inPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"), strdup("-c"), strdup(command), nil,
        ]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
        close(inPipe[0])
        close(outPipe[1])
        guard spawned == 0 else {
            close(inPipe[1]); close(outPipe[0])
            return Result(stdout: Data(), status: 127, timedOut: false)
        }
        activeGroup = pid
        defer { activeGroup = 0 }

        // stdin on its own thread: a command that never reads it would
        // otherwise block this write once the pipe buffer fills
        let inWrite = inPipe[1]
        let writer = Thread {
            input.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(inWrite, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; break }
                    offset += n
                }
            }
            close(inWrite)
        }
        let output = OutputCollector(fd: outPipe[0])
        // SIGPIPE from a command that closes stdin early must not kill us
        signal(SIGPIPE, SIG_IGN)
        writer.start()
        output.start()

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var timedOut = false
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0, errno != EINTR { break }
            if Date() >= deadline {
                timedOut = true
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                break
            }
            usleep(5_000)
        }
        // anything the shell left running holds stdout open; give it a
        // moment to finish writing, then end the group
        if !output.finished(within: timedOut ? 0 : 0.5) {
            kill(-pid, SIGKILL)
            _ = output.finished(within: 1)
        }
        return Result(stdout: output.data, status: exitCode(status), timedOut: timedOut)
    }

    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }

    private final class OutputCollector: @unchecked Sendable {
        let fd: Int32
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()

        init(fd: Int32) { self.fd = fd }

        func start() {
            Thread {
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let n = read(self.fd, &chunk, chunk.count)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { break }
                    self.lock.lock(); self.buffer.append(chunk, count: n); self.lock.unlock()
                }
                close(self.fd)
                self.done.signal()
            }.start()
        }

        func finished(within seconds: TimeInterval) -> Bool {
            if done.wait(timeout: .now() + seconds) == .success {
                done.signal()  // stays signalled for later checks
                return true
            }
            return false
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
