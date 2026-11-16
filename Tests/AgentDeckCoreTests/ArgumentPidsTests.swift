import Foundation
import Testing
@testable import AgentDeckCore

struct ArgumentPidsTests {
    @Test func scansOnlyIdsNotYetTried() {
        var cache = ArgumentPids()
        var scanned: [Set<String>] = []
        func scan(_ ids: Set<String>) -> [String: pid_t] {
            scanned.append(ids)
            return ids.contains("a") ? ["a": 100] : [:]
        }
        cache.update(wanted: ["a", "b"], stillValid: { _, _ in true }, scan: scan)
        #expect(cache.pids == ["a": 100])
        cache.update(wanted: ["a", "b"], stillValid: { _, _ in true }, scan: scan)
        #expect(scanned == [["a", "b"]], "a found pid and a miss are both remembered")
        cache.update(wanted: ["a", "b", "c"], stillValid: { _, _ in true }, scan: scan)
        #expect(scanned.last == ["c"])
    }

    @Test func aReusedPidIsDroppedAndTheIdLookedUpAgain() {
        var cache = ArgumentPids()
        cache.update(wanted: ["a"], stillValid: { _, _ in true }, scan: { _ in ["a": 100] })
        var scanned = false
        cache.update(wanted: ["a"], stillValid: { _, _ in false },
                     scan: { _ in scanned = true; return ["a": 200] })
        #expect(scanned)
        #expect(cache.pids == ["a": 200])
    }

    @Test func idsNoLongerWantedAreForgotten() {
        var cache = ArgumentPids()
        cache.update(wanted: ["a", "b"], stillValid: { _, _ in true }, scan: { _ in ["a": 100] })
        cache.update(wanted: [], stillValid: { _, _ in true }, scan: { _ in [:] })
        #expect(cache.pids.isEmpty)
        // a miss forgotten too: wanted again later, it's scanned again
        var scanned: Set<String> = []
        cache.update(wanted: ["b"], stillValid: { _, _ in true },
                     scan: { scanned = $0; return [:] })
        #expect(scanned == ["b"])
    }

    @Test func aScanResultOutsideTheAskIsIgnored() {
        var cache = ArgumentPids()
        cache.update(wanted: ["a"], stillValid: { _, _ in true }, scan: { _ in ["a": 1, "z": 2] })
        #expect(cache.pids == ["a": 1])
    }
}
