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

    @Test func syncCreatesMissingStable() throws {
        let bundled = try file("bundled", "helper")
        let stable = dir.appendingPathComponent("bin/agentdeck-hook")
        #expect(try HelperSync.sync(bundled: bundled, stable: stable))
        #expect(HelperSync.sha256(of: stable) == HelperSync.sha256(of: bundled))
    }
}
