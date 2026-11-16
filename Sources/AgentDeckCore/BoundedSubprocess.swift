import Foundation

/// Runs a child process with a hard deadline, draining its output CONCURRENTLY
/// while it runs. Draining only after `waitUntilExit` deadlocks when the child
/// produces more than a pipe buffer (~64KB) — a large sqlite result would turn
/// a success into a timeout. Callers in this repo kept re-committing that bug
/// (osascript, CodexThreads), so it lives in one bounded place.
public enum BoundedSubprocess {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var timedOut: Bool
    }

    public static func run(
        _ executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) -> Result {
        run(executable, arguments: arguments, stdin: stdin, timeout: timeout, afterRead: nil)
    }

    /// `afterRead` runs between taking a chunk off the pipe and storing it,
    /// so a test can widen that window.
    static func run(
        _ executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval,
        afterRead: (@Sendable () -> Void)?
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe  // merged: one stream can't starve the other

        // Concurrent drain: accumulate as data arrives so the child never
        // blocks on a full pipe.
        // Each chunk is read and stored under the box's lock, so the final
        // collection below can't land between the two: osascript's whole
        // answer was once taken off the pipe and not yet stored when the
        // result was read (status 0, empty output).
        let collected = DrainBox()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            collected.withLock { buffer in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    afterRead?()
                    buffer.append(chunk)
                }
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return Result(status: -1, output: Data(), timedOut: false)
        }
        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? inPipe.fileHandleForWriting.close()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // SIGTERM first, then SIGKILL: an osascript parked in an Apple
            // event to a hung app can ignore the first.
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        // Take what is already buffered without waiting for EOF. A blocking
        // read-to-end here once had no bound at all: anything still holding
        // the pipe open — the child, if even SIGKILL hadn't landed, or a
        // grandchild that inherited it — parked the caller forever, and a
        // restore waiting on it never finished.
        // Under the lock: a handler call already under way finishes storing
        // its chunk first, so nothing is lost and the order holds.
        let output = collected.withLock { buffer in
            buffer.append(drainWithoutBlocking(outPipe.fileHandleForReading.fileDescriptor))
            return buffer
        }
        // terminationStatus raises if the process is somehow still running
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: status, output: output, timedOut: timedOut)
    }

    static func drainWithoutBlocking(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) } else { break }  // 0 = EOF, -1 = EAGAIN/error
        }
        return data
    }

    /// Thread-safe accumulator for the readability handler (which runs on a
    /// background queue) plus the final drain (on the caller's thread).
    private final class DrainBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func withLock<T>(_ body: (inout Data) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&buffer)
        }
    }
}
