import Foundation
import Testing
@testable import AgentDeckCore

/// A newer build can record sessions for a provider this build has no case
/// for. These pin that this build carries them through every write instead
/// of dropping them — or, worse, failing to read the whole file and then
/// writing a fresh one over it.
struct WorkspaceCompatibilityTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func tempStore() -> WorkspaceStore {
        WorkspaceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wsc-\(UUID().uuidString)", isDirectory: true))
    }

    func entry(_ id: String) -> WorkspaceEntry {
        WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp", lastSeen: .distantPast)
    }

    nonisolated(unsafe) static let futureEntry: [String: Any] = [
        "provider": "zzz", "sessionId": "9d3e", "cwd": "/tmp/agy",
        "lastSeen": "2026-10-26T10:00:00.000Z", "launchFlags": ["a", 1, true, 1.5, NSNull()],
    ]

    func writeGeneration(_ store: WorkspaceStore, bootID: String, entries: [[String: Any]]) throws {
        let object: [String: Any] = [
            "schemaVersion": 1, "bootID": bootID, "updatedAt": "2026-10-26T10:00:00.000Z",
            "entries": entries, "closedSets": [],
        ]
        let url = store.generationURL(bootID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// The raw on-disk entries, as JSON objects.
    func rawEntries(_ url: URL) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["entries"] as? [[String: Any]] ?? []
    }

    func futureEntries(_ url: URL) throws -> [[String: Any]] {
        try rawEntries(url).filter { $0["provider"] as? String == "zzz" }
    }

    func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        return da != nil && da == db
    }

    @Test func anUnknownProviderEntrySurvivesARecord() throws {
        let store = tempStore()
        let realEntry: [String: Any] = [
            "provider": "claude", "sessionId": "old", "cwd": "/tmp",
            "lastSeen": "2026-10-26T09:00:00.000Z",
        ]
        try writeGeneration(store, bootID: "B", entries: [realEntry, Self.futureEntry])
        #expect(try store.record(live: [entry("new")], bootID: "B", now: t0))
        let url = store.generationURL("B")
        let kept = try futureEntries(url)
        #expect(kept.count == 1)
        #expect(jsonEqual(try #require(kept.first), Self.futureEntry), "written back exactly as found")
        let keys = try rawEntries(url).compactMap { $0["sessionId"] as? String }
        #expect(Set(keys) == ["old", "new", "9d3e"])
        // and this build still reads the file it wrote
        #expect(store.loadGeneration(bootID: "B")?.entries.map(\.sessionId).sorted() == ["new", "old"])
    }

    @Test func twoCopiesWritingKeepAnUnknownEntry() throws {
        let store = tempStore()
        try writeGeneration(store, bootID: "B", entries: [Self.futureEntry])
        let a = WorkspaceStore(directory: store.directory)
        let b = WorkspaceStore(directory: store.directory)
        try a.record(live: [entry("x")], bootID: "B", now: t0)
        try b.record(live: [entry("y")], bootID: "B", now: t0 + 1)
        try a.record(live: [entry("x"), entry("z")], bootID: "B", now: t0 + 2)
        let url = store.generationURL("B")
        #expect(try futureEntries(url).count == 1)
        let keys = Set(try rawEntries(url).compactMap { $0["sessionId"] as? String })
        #expect(keys == ["x", "y", "z", "9d3e"])
    }

    @Test func mergingKeepsTheNewerSightingOfAnUnknownEntry() throws {
        func opaque(_ lastSeen: String) throws -> OpaqueWorkspaceEntry {
            var e = Self.futureEntry
            e["lastSeen"] = lastSeen
            let data = try JSONSerialization.data(withJSONObject: e)
            return OpaqueWorkspaceEntry(try JSONDecoder().decode(JSONValue.self, from: data))
        }
        let older = try opaque("2026-10-26T10:00:00.000Z")
        let newer = try opaque("2026-10-26T11:00:00.000Z")
        var a = WorkspaceGeneration(bootID: "B", updatedAt: t0)
        a.unknownEntries = [older]
        var b = WorkspaceGeneration(bootID: "B", updatedAt: t0)
        b.unknownEntries = [newer]
        #expect(a.merged(with: b).unknownEntries == [newer])
        #expect(b.merged(with: a).unknownEntries == [newer])
    }

    @Test func anUnreadableGenerationIsNotOverwritten() throws {
        let store = tempStore()
        let url = store.generationURL("B")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data(#"{"schemaVersion": 99, "bootID": 7}"#.utf8)
        try junk.write(to: url)
        #expect(throws: WorkspaceStore.UnreadableFile.self) {
            try store.record(live: [entry("a")], bootID: "B", now: t0)
        }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test func updatingANamedWorkspaceKeepsUnknownEntries() throws {
        let store = tempStore()
        let ws = NamedWorkspace(name: "w", savedAt: t0, entries: [entry("x")])
        try store.save(ws)
        // a newer build adds an entry of its own to the saved workspace
        let url = store.namedURL(ws.id)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["entries"] = (object["entries"] as! [Any]) + [Self.futureEntry]
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        #expect(store.named().first?.entries.map(\.sessionId) == ["x"])
        #expect(try store.updateNamed(id: ws.id) { $0.entries[0].cwd = "/new" })
        let kept = try futureEntries(url)
        #expect(kept.count == 1 && jsonEqual(kept[0], Self.futureEntry))
        #expect(store.named().first?.entries.first?.cwd == "/new")
    }

    @Test func opaqueValuesRoundTripEveryJSONType() throws {
        let source = Data(#"{"a":1,"b":true,"c":1.5,"d":null,"e":"s","f":[1,{"g":false}],"h":-7}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: source)
        let back = try JSONEncoder().encode(value)
        #expect(jsonEqual(try JSONSerialization.jsonObject(with: back),
                          try JSONSerialization.jsonObject(with: source)))
        #expect(value["b"] == .bool(true))
        #expect(value["a"] == .int(1))
        #expect(value["c"] == .double(1.5))
    }
}
