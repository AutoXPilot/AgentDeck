import Foundation
import Testing
@testable import AgentDeckCore

final class SnapshotStoreTests {
    let dir: URL
    let store: SnapshotStore

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-tests-\(UUID().uuidString)")
        store = SnapshotStore(directory: dir)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeSnapshot(id: String = "s1", state: SessionState = .working) -> SessionSnapshot {
        SessionSnapshot(
            provider: .claude, sessionId: id, projectPath: "/tmp/project",
            state: state, event: "UserPromptSubmit",
            terminalSessionId: "w0t0p0:ABC-123", agentPid: 999
        )
    }

    @Test func roundTrip() throws {
        let snap = makeSnapshot()
        try store.write(snap)
        let loaded = try #require(store.load(key: snap.key))
        #expect(loaded.sessionId == "s1")
        #expect(loaded.state == .working)
        #expect(loaded.terminalSessionId == "w0t0p0:ABC-123")
        #expect(loaded.agentPid == 999)
        // ISO8601 round-trip has second precision
        #expect(abs(loaded.updatedAt.timeIntervalSince(snap.updatedAt)) < 1.0)
    }

    @Test func removeDeletesFile() throws {
        let snap = makeSnapshot()
        try store.write(snap)
        store.remove(key: snap.key)
        #expect(store.load(key: snap.key) == nil)
        #expect(store.loadAll().isEmpty)
    }

    @Test func loadAllSkipsCorruptFiles() throws {
        try store.write(makeSnapshot(id: "good"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("claude-bad.json"))
        try Data().write(to: dir.appendingPathComponent("claude-empty.json"))
        let all = store.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.sessionId == "good")
    }

    @Test func concurrentWritesNeverExposePartialJSON() throws {
        let store = self.store
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let snap = SessionSnapshot(
                provider: .claude, sessionId: "shared", projectPath: "/tmp/p\(i)",
                state: SessionState.allCases[i % SessionState.allCases.count],
                event: "e\(i)"
            )
            try? store.write(snap)
            // interleaved reads must always parse or be absent, never partial
            if let data = try? Data(contentsOf: store.url(forKey: "claude-shared")),
               !data.isEmpty {
                #expect(throws: Never.self, "reader observed partial JSON") {
                    _ = try JSONSerialization.jsonObject(with: data)
                }
            }
        }
        #expect(store.load(key: "claude-shared") != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "leftover temp files: \(leftovers)")
    }
}
