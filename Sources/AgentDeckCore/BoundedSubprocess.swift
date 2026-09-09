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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe  // merged: one stream can't starve the other

        // Concurrent drain: accumulate as data arrives so the child never
        // blocks on a full pipe.
        let collected = DrainBox()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(chunk)
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
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        // ensure the handler saw EOF; a tiny grace for in-flight reads
        outPipe.fileHandleForReading.readabilityHandler = nil
        let remaining = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        collected.append(remaining)
        return Result(
            status: process.terminationStatus, output: collected.data, timedOut: timedOut
        )
    }

    /// Thread-safe accumulator for the readability handler (which runs on a
    /// background queue) plus the final drain (on the caller's thread).
    private final class DrainBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
