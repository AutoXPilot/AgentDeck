import Foundation
import Testing
@testable import AgentDeckCore

struct CodexSessionIndexTests {
    @Test func parsesRealIndexLines() {
        // shape recorded from ~/.codex/session_index.jsonl (codex-cli 0.145.0)
        let jsonl = """
        {"id":"019fa496-4c84-7fc2-96dd-7f19a124ec6c","thread_name":"AgentDeck","updated_at":"2026-07-29T15:38:47.894743Z"}
        {"id":"019fb864-ccaa-7c61-af12-b8cb8710fbb8","thread_name":"review-coding-plan","updated_at":"2026-07-31T14:07:37.488598Z"}
        """
        let names = CodexSessionIndex.parse(jsonl)
        #expect(names["019fb864-ccaa-7c61-af12-b8cb8710fbb8"] == "review-coding-plan")
        #expect(names["019fa496-4c84-7fc2-96dd-7f19a124ec6c"] == "AgentDeck")
    }

    @Test func laterEntriesWinBecauseTheFileIsAnAppendLog() {
        let jsonl = """
        {"id":"abc","thread_name":"old-name"}
        {"id":"abc","thread_name":"renamed-later"}
        """
        #expect(CodexSessionIndex.parse(jsonl)["abc"] == "renamed-later")
    }

    @Test func skipsMalformedAndIncompleteLines() {
        let jsonl = """
        not json at all
        {"id":"missing-name"}
        {"thread_name":"missing-id"}
        {"id":"","thread_name":"empty-id"}
        {"id":"ok","thread_name":""}
        {"id":"good","thread_name":"kept"}
        """
        let names = CodexSessionIndex.parse(jsonl)
        #expect(names == ["good": "kept"])
    }

    @Test func emptyInputAndMissingFile() {
        #expect(CodexSessionIndex.parse("").isEmpty)
        let missing = URL(fileURLWithPath: "/nonexistent/session_index.jsonl")
        #expect(CodexSessionIndex.load(from: missing).isEmpty)
    }

    @Test func threadExistenceDistinguishesAbsentFromUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.sqlite")
        let id = "01a14a60-ebb5-70c1-a848-1a32a0d6ee08"
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        make.arguments = [db.path, "create table threads(id text); insert into threads values('\(id)');"]
        try make.run()
        make.waitUntilExit()
        #expect(CodexThreads.exists(id: id, in: db) == true)
        #expect(CodexThreads.exists(id: id.uppercased(), in: db) == true)
        #expect(CodexThreads.exists(id: "11111111-1111-4111-8111-111111111111", in: db) == false)
        #expect(CodexThreads.exists(id: id, in: dir.appendingPathComponent("missing.sqlite")) == nil)
        #expect(CodexThreads.exists(id: "'; drop table threads; --", in: db) == nil, "not a UUID")
        let garbage = dir.appendingPathComponent("garbage.sqlite")
        try Data("not a database".utf8).write(to: garbage)
        #expect(CodexThreads.exists(id: id, in: garbage) == nil, "unreadable is unknown, not absent")
    }
}
