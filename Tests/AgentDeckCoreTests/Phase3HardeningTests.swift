import Foundation
import Testing
@testable import AgentDeckCore

struct SanitizeCollisionTests {
    @Test func distinctRawIdsThatSanitizeAlikeGetDistinctFiles() {
        // "a/b" and "a-b" both sanitize to "a-b" — a hash suffix keeps them
        // apart so one session can't overwrite/remove the other's snapshot.
        let a = SnapshotStore.sanitizeKeyComponent("claude-a/b")
        let b = SnapshotStore.sanitizeKeyComponent("claude-a-b")
        #expect(a != b)
        #expect(!a.contains("/"))
    }

    @Test func alreadySafeIdsAreUnchanged() {
        // real UUIDs must not gain a hash suffix (keeps existing files valid)
        let uuid = "claude-9c64a083-c8d8-4c00-9008-6d0ea533783d"
        #expect(SnapshotStore.sanitizeKeyComponent(uuid) == uuid)
    }

    @Test func sanitizeIsDeterministic() {
        // write and remove must resolve to the same file
        #expect(SnapshotStore.sanitizeKeyComponent("a/b/c")
            == SnapshotStore.sanitizeKeyComponent("a/b/c"))
    }

    @Test func traversalStillNeutralized() {
        let s = SnapshotStore.sanitizeKeyComponent("../../etc/passwd")
        #expect(!s.contains(".."))
        #expect(!s.contains("/"))
    }
}

struct PruneBackupsTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    // no deinit cleanup needed; temp dir

    @Test func keepsNewestFiveByName() throws {
        let config = dir.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: config)
        // 8 backups with sortable UTC-style names
        let stamps = (1...8).map { String(format: "20260101-0000%02d", $0) }
        for stamp in stamps {
            try Data("x".utf8).write(
                to: dir.appendingPathComponent("settings.json.agentdeck-\(stamp).bak"))
        }
        HookInstaller.pruneBackups(for: config, keep: 5)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".bak") }.sorted()
        #expect(remaining.count == 5)
        // the five KEPT are the newest (highest-sorting) stamps
        #expect(remaining.first!.contains("00004"))
        #expect(remaining.last!.contains("00008"))
    }

    @Test func timestampIsUTCAndSortable() {
        let t = HookInstaller.timestamp(date: Date(timeIntervalSince1970: 0))
        #expect(t == "19700101-000000")
    }
}

final class CwdlessSnapshotTests {
    let dir: URL
    let store: SnapshotStore
    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-cwdless-\(UUID().uuidString)")
        store = SnapshotStore(directory: dir)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func notificationBeforeSessionStartStillHasIdentity() {
        // a Notification arriving before SessionStart creates a snapshot with
        // no cwd; projectName is empty. The row must not be blank.
        let payload = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "session_id": "abc123def456",
            "notification_type": "permission_prompt",
        ])
        HookProcessor.process(
            provider: .claude, payloadData: payload,
            environment: [:], parentPid: nil, store: store
        )
        let snap = store.load(key: "claude-abc123def456")
        #expect(snap != nil)
        #expect(snap?.projectName.isEmpty == true, "no cwd → empty folder name")
        // the model's title(for:) falls back to a session-id label; here we
        // assert the raw material for that fallback exists
        #expect(snap?.sessionId.prefix(8) == "abc123de")
    }
}

struct StableSortTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    func snap(_ id: String) -> SessionSnapshot {
        SessionSnapshot(provider: .claude, sessionId: id, projectPath: "/p",
                        state: .working, event: "x", updatedAt: now)
    }

    @Test func equalRankEqualTimeRowsHoldAStableOrder() {
        let rows = [snap("c"), snap("a"), snap("b")]
        let first = Attention.sorted(rows, acks: [:]).map(\.sessionId)
        let second = Attention.sorted(rows.reversed(), acks: [:]).map(\.sessionId)
        #expect(first == second, "same set, same order regardless of input order")
        #expect(first == ["a", "b", "c"], "keyed tiebreak is deterministic")
    }
}
