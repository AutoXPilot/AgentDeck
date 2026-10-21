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

    /// Every field the helper sets must survive a write/read.
    ///
    /// `modelObservedAt` did not: it was populated on every hook event but
    /// left out of `CodingKeys`, and because an explicit `CodingKeys` also
    /// drives the synthesized encoder, it was dropped on write. The reader
    /// therefore always saw nil and fell back to ranking by `updatedAt` —
    /// the exact behaviour the field was added to replace. Shipped inert in
    /// 0.4.1, because the tests exercised the decision function directly
    /// and never went through the store.
    ///
    /// This asserts on a fully-populated snapshot rather than one field, so
    /// the next addition that misses `CodingKeys` fails here.
    @Test func roundTripsEveryField() throws {
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = SessionSnapshot(
            provider: .codex,
            sessionId: "full",
            projectPath: "/tmp/full",
            state: .waiting,
            event: "Notification",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            terminalSessionId: "w1t2p3:GUID-9",
            agentPid: 4242,
            notificationType: "permission_prompt",
            permissionMode: "acceptEdits",
            model: "gpt-6-astra",
            modelObservedAt: observed,
            effort: "high",
            errorKind: "rate_limit"
        )
        try store.write(snap)
        let loaded = try #require(store.load(key: snap.key))

        #expect(loaded.provider == .codex)
        #expect(loaded.sessionId == "full")
        #expect(loaded.projectPath == "/tmp/full")
        #expect(loaded.state == .waiting)
        #expect(loaded.event == "Notification")
        #expect(loaded.terminalSessionId == "w1t2p3:GUID-9")
        #expect(loaded.agentPid == 4242)
        #expect(loaded.notificationType == "permission_prompt")
        #expect(loaded.permissionMode == "acceptEdits")
        #expect(loaded.model == "gpt-6-astra")
        #expect(loaded.effort == "high")
        #expect(loaded.errorKind == "rate_limit", "every field populated, so a dropped one shows")
        #expect(loaded.modelObservedAt != nil, "modelObservedAt was silently dropped on write")
        #expect(abs((loaded.modelObservedAt ?? .distantPast)
            .timeIntervalSince(observed)) < 1.0)

        // and the field must actually reach the on-disk JSON, not just
        // survive an in-memory copy
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.url(forKey: snap.key))
        ) as? [String: Any]
        #expect(raw?["modelObservedAt"] != nil)
        #expect(raw?["errorKind"] as? String == "rate_limit")
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

    @Test func fractionalSecondPrecisionSurvivesRoundTrip() throws {
        var snap = makeSnapshot(id: "frac")
        snap.updatedAt = Date(timeIntervalSince1970: 1_785_000_000.400)
        try store.write(snap)
        let loaded = try #require(store.load(key: snap.key))
        // whole-second precision would collapse the 0.4s — the same-second
        // ack race depends on this
        #expect(abs(loaded.updatedAt.timeIntervalSince1970 - 1_785_000_000.400) < 0.005)
    }

    @Test func traversalKeyStaysInsideDirectory() {
        let url = store.url(forKey: "claude-../../../.claude/settings")
        #expect(url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path))
        #expect(!url.path.contains(".."))
    }

    @Test func orphanSweepRemovesStaleDebris() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try store.write(makeSnapshot(id: "keep"))
        let staleTmp = dir.appendingPathComponent(".dead.tmp")
        let corrupt = dir.appendingPathComponent("claude-corrupt.json")
        try Data("partial".utf8).write(to: staleTmp)
        try Data("{broken".utf8).write(to: corrupt)
        let past = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: staleTmp.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: corrupt.path
        )
        store.sweepOrphans()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["claude-keep.json"])
    }

    @Test func anAgedButHeldLockIsNotReclaimed() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Acquire the lock, age it past the sweep threshold, and sweep from
        // another thread while it is still held. Unlinking here gave the
        // next helper a different inode for the same path — two writers
        // both believing they were serialized.
        let lockPath = dir.appendingPathComponent(".claude-held.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: lockPath
        )
        store.sweepOrphans()
        #expect(FileManager.default.fileExists(atPath: lockPath),
                "a held lock must survive the sweep")
        flock(fd, LOCK_UN)
        close(fd)

        // once released and still old, it is reclaimable
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: lockPath
        )
        store.sweepOrphans()
        #expect(!FileManager.default.fileExists(atPath: lockPath),
                "an unheld, aged lock should be reclaimed")
    }

    @Test func usingALockKeepsItFromAgingOut() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent(".claude-busy.lock").path
        _ = try store.withKeyLock("claude-busy") { 0 }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: lockPath
        )
        // a session active again right now must not look idle for an hour
        _ = try store.withKeyLock("claude-busy") { 0 }
        store.sweepOrphans()
        #expect(FileManager.default.fileExists(atPath: lockPath),
                "acquiring the lock must refresh its mtime")
    }

    @Test func aWaiterOnAnUnlinkedLockFileDoesNotRunAlongsideTheNextHolder() throws {
        // The interleaving: someone holds lock file A; a writer opens A and
        // waits; the sweep unlinks A; a second writer creates B at the same
        // path and locks it; A is released. The waiter used to get A and
        // run at the same time as B's holder — two "serialized" writers.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = self.store
        let lockPath = dir.appendingPathComponent(".claude-race.lock").path
        let holderA = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(holderA, LOCK_EX)

        final class Spans: @unchecked Sendable {
            let lock = NSLock()
            var spans: [(String, Date, Date)] = []
            func add(_ who: String, _ a: Date, _ b: Date) { lock.lock(); spans.append((who, a, b)); lock.unlock() }
        }
        let spans = Spans()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {   // the waiter, blocked on A
            _ = try? store.withKeyLock("claude-race") {
                let start = Date(); Thread.sleep(forTimeInterval: 0.3)
                spans.add("waiter", start, Date())
            }
        }
        Thread.sleep(forTimeInterval: 0.2)             // let it open A and block
        unlink(lockPath)                                // the sweep reclaims A
        DispatchQueue.global().async(group: group) {   // creates and locks B
            _ = try? store.withKeyLock("claude-race") {
                let start = Date(); Thread.sleep(forTimeInterval: 0.6)
                spans.add("second", start, Date())
            }
        }
        Thread.sleep(forTimeInterval: 0.2)             // B is held now
        flock(holderA, LOCK_UN)                         // release A
        close(holderA)
        group.wait()
        #expect(spans.spans.count == 2)
        if spans.spans.count == 2 {
            let (a, b) = (spans.spans[0], spans.spans[1])
            let overlap = a.1 < b.2 && b.1 < a.2
            #expect(!overlap, "\(a.0) and \(b.0) held the lock at the same time")
        }
    }

    @Test func aSecondSweeperDoesNotUnlinkTheLockThatReplacedTheOneItOpened() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(".claude-two.lock")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let secondSweeper = open(url.path, O_RDWR)        // opened A, not yet acted
        defer { close(secondSweeper) }
        let first = open(url.path, O_RDWR)
        store.reclaimLock(openedAs: first, at: url)        // the first sweeper unlinks A
        close(first)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // a helper creates B at the same path and is holding it
        let helper = open(url.path, O_CREAT | O_RDWR, 0o600)
        defer { close(helper) }
        var b = stat()
        fstat(helper, &b)
        store.reclaimLock(openedAs: secondSweeper, at: url)
        var atPath = stat()
        #expect(stat(url.path, &atPath) == 0, "B must still be at the path")
        #expect(atPath.st_ino == b.st_ino)
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
