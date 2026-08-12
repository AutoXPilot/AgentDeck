import Foundation
import Testing
@testable import AgentDeckCore

/// Golden-path integration: real snapshot FILES through SnapshotStore into
/// SessionPipeline. Unit tests hand the pipeline nice structs; this catches
/// the seams — decode quirks, sanitized keys, corrupt files — that only
/// exist at the file boundary.
final class StoreToPipelineIntegrationTests {
    let dir: URL
    let store: SnapshotStore
    let now = Date(timeIntervalSince1970: 1_785_000_000)

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-golden-\(UUID().uuidString)")
        store = SnapshotStore(directory: dir)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func filesInToUiOut() throws {
        // a realistic deck written as actual files
        let fixtures: [SessionSnapshot] = [
            SessionSnapshot(provider: .claude, sessionId: "blocked", projectPath: "/p/api",
                            state: .waiting, event: "PermissionRequest",
                            updatedAt: now.addingTimeInterval(-300),
                            notificationType: "permission_prompt"),
            SessionSnapshot(provider: .claude, sessionId: "idle-fake", projectPath: "/p/web",
                            state: .waiting, event: "Notification",
                            updatedAt: now.addingTimeInterval(-7200),
                            notificationType: "idle_prompt"),
            SessionSnapshot(provider: .codex, sessionId: "worker", projectPath: "/p/etl",
                            state: .working, event: "UserPromptSubmit",
                            updatedAt: now.addingTimeInterval(-60)),
            SessionSnapshot(provider: .claude, sessionId: "finished", projectPath: "/p/api",
                            state: .done, event: "Stop",
                            updatedAt: now.addingTimeInterval(-900),
                            errorKind: nil),
        ]
        for fixture in fixtures { try store.write(fixture) }
        // plus debris that must be survived, not rendered
        try Data("{corrupt".utf8).write(to: dir.appendingPathComponent("claude-x.json"))

        let loaded = store.loadAll()
        #expect(loaded.count == 4, "corrupt file skipped, all fixtures decoded")

        let out = SessionPipeline.run(
            snapshots: loaded, registry: [:], acks: [:],
            frozenOrder: nil, popoverVisible: false, now: now
        )
        #expect(out.rows.count == 4)
        #expect(out.alertCount == 1, "only the genuine block counts")
        #expect(out.doneCount == 1)
        #expect(out.mostUrgent == .waiting)
        #expect(out.rows.first?.sessionId == "blocked", "block sorts first")
        #expect(out.waitingReasons["claude-blocked"] == "needs permission")
        let states = Dictionary(uniqueKeysWithValues: out.rows.map { ($0.sessionId, $0.state) })
        #expect(states["idle-fake"] == .ready, "idle nudge repaired on the file path too")
    }
}
