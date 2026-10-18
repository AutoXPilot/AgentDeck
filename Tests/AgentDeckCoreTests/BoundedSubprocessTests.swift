import Foundation
import Testing
@testable import AgentDeckCore

struct BoundedSubprocessTests {
    @Test func aChildThatIgnoresSIGTERMAndLeavesThePipeOpenStillReturns() {
        // sh ignores SIGTERM, and the sleep it starts inherits the output
        // pipe, so neither the polite kill nor the child's death ends the
        // stream. The old blocking read-to-end waited out the whole sleep.
        let start = Date()
        let result = BoundedSubprocess.run(
            "/bin/sh", arguments: ["-c", "echo started; trap '' TERM; sleep 20"],
            timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.timedOut)
        #expect(elapsed < 8, "returned after \(elapsed)s")
        #expect(String(decoding: result.output, as: UTF8.self).contains("started"))
    }

    @Test func outputLargerThanAPipeBufferArrivesWhole() {
        let result = BoundedSubprocess.run(
            "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\\\0' x"],
            timeout: 10)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.output.count == 300_000)
    }
}
