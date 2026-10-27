import Foundation
import Testing
@testable import AgentDeckCore

final class HelperSyncTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func file(_ name: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func detectsDrift() throws {
        let bundled = try file("bundled", "v2")
        let staleStable = try file("stable", "v1")
        #expect(HelperSync.needsSync(bundled: bundled, stable: staleStable))
        let sameStable = try file("stable2", "v2")
        #expect(!HelperSync.needsSync(bundled: bundled, stable: sameStable))
        // missing stable = needs sync; missing bundled = leave stable alone
        #expect(HelperSync.needsSync(bundled: bundled,
                                     stable: dir.appendingPathComponent("missing")))
        #expect(!HelperSync.needsSync(bundled: dir.appendingPathComponent("missing"),
                                      stable: staleStable))
    }

    @Test func syncReplacesAndMarksExecutable() throws {
        let bundled = try file("bundled", "new helper bytes")
        let stable = try file("stable", "old helper bytes")
        #expect(try HelperSync.sync(bundled: bundled, stable: stable))
        #expect(try String(contentsOf: stable, encoding: .utf8) == "new helper bytes")
        #expect(FileManager.default.isExecutableFile(atPath: stable.path))
        // second sync is a no-op
        #expect(try !HelperSync.sync(bundled: bundled, stable: stable))
    }

    @Test func anOlderBundledHelperNeverReplacesANewerOne() throws {
        // an older app launched beside a newer one
        let bundled = try file("bundled", "0.5.1 helper bytes")
        let stable = try file("stable", "0.6.0 helper bytes")
        let decision = HelperSync.decision(
            bundled: bundled, bundledVersion: "0.5.1", stable: stable,
            stableVersion: { _ in "0.6.0" })
        #expect(decision == .keepNewer)
        #expect(try !HelperSync.sync(bundled: bundled, bundledVersion: "0.5.1", stable: stable,
                                     stableVersion: { _ in "0.6.0" }))
        #expect(try String(contentsOf: stable, encoding: .utf8) == "0.6.0 helper bytes")
    }

    @Test func aNewerOrEqualOrUnknownVersionStillReplaces() throws {
        let bundled = try file("bundled", "new")
        func decide(_ stableVersion: String?) throws -> HelperSync.Decision {
            HelperSync.decision(bundled: bundled, bundledVersion: "0.5.1",
                                stable: try file("stable", "old"),
                                stableVersion: { _ in stableVersion })
        }
        #expect(try decide("0.5.0") == .replace, "upgrade")
        #expect(try decide("0.5.1") == .replace, "a rebuilt helper of the same version")
        #expect(try decide(nil) == .replace, "a helper too old to report a version")
        #expect(try decide("garbage") == .replace)
        // identical bytes are current whatever the version says
        let same = try file("same", "new")
        #expect(HelperSync.decision(bundled: bundled, bundledVersion: "0.5.1", stable: same,
                                    stableVersion: { _ in "9.9.9" }) == .current)
    }

    @Test func versionsCompareNumerically() {
        #expect(HelperSync.parseVersion("0.10.0") == [0, 10, 0])
        #expect(HelperSync.parseVersion(" 0.5.1\n") == [0, 5, 1])
        #expect(HelperSync.parseVersion("0.5.0-dev") == nil)
        #expect(HelperSync.parseVersion("0..1") == nil)
        #expect(HelperSync.parseVersion("") == nil)
        #expect(HelperSync.isNewer([0, 10, 0], than: [0, 9, 9]))
        #expect(!HelperSync.isNewer([0, 5, 1], than: [0, 5, 1]))
        #expect(HelperSync.isNewer([0, 5, 1], than: [0, 5]))
        #expect(!HelperSync.isNewer([0, 5], than: [0, 5, 0]))
    }

    @Test func theBuiltHelperReportsThisVersion() throws {
        // the real binary, so the parse is pinned to what --version prints
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/agentdeck-hook")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        #expect(HelperSync.reportedVersion(of: helper) == AgentDeckVersion.current)
        #expect(HelperSync.reportedVersion(of: dir.appendingPathComponent("missing")) == nil)
    }

    @Test func syncCreatesMissingStable() throws {
        let bundled = try file("bundled", "helper")
        let stable = dir.appendingPathComponent("bin/agentdeck-hook")
        #expect(try HelperSync.sync(bundled: bundled, stable: stable))
        #expect(HelperSync.sha256(of: stable) == HelperSync.sha256(of: bundled))
    }
}
