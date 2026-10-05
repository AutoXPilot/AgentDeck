import Foundation
import Testing
@testable import AgentDeckCore

struct ClaudeTranscriptTests {
    /// Builds `<tmp>/projects/<dir>/<session>.jsonl` and returns the
    /// projects directory.
    private func makeProjects(
        _ files: [(dir: String, session: String, lines: [String])]
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentdeck-transcript-\(UUID().uuidString)")
        for file in files {
            let dir = root.appendingPathComponent(file.dir)
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            try file.lines.joined(separator: "\n").write(
                to: dir.appendingPathComponent("\(file.session).jsonl"),
                atomically: true, encoding: .utf8
            )
        }
        return root
    }

    private func assistant(_ model: String, sidechain: Bool = false) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "isSidechain": sidechain,
            "message": ["model": model, "role": "assistant"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func slugMatchesClaudesDirectoryNaming() {
        // observed: both "/" and "." become "-"
        #expect(ClaudeTranscript.slug(for: "/Users/t/Code") == "-Users-t-Code")
        #expect(ClaudeTranscript.slug(for: "/Users/t/Code/v2/.claude/wt")
                == "-Users-t-Code-v2--claude-wt")
    }

    @Test func findsTranscriptByDerivedDirectory() throws {
        let root = try makeProjects([
            (dir: "-Users-t-Code", session: "abc", lines: [assistant("claude-opus-5-5")])
        ])
        let url = ClaudeTranscript.url(
            sessionId: "abc", projectPath: "/Users/t/Code", projectsDirectory: root
        )
        #expect(url?.lastPathComponent == "abc.jsonl")
    }

    @Test func findsTranscriptWhenTheDirectoryNameDoesntMatchTheCwd() throws {
        // the slug rule isn't documented, and a session can be resumed from
        // elsewhere — the scan is what keeps those rows from going blank
        let root = try makeProjects([
            (dir: "-somewhere-else", session: "abc", lines: [assistant("claude-opus-5-5")])
        ])
        let url = ClaudeTranscript.url(
            sessionId: "abc", projectPath: "/Users/t/Code", projectsDirectory: root
        )
        #expect(url != nil)
        #expect(ClaudeTranscript.latestModel(at: url!) == "claude-opus-5-5")
    }

    @Test func missingTranscriptIsNil() throws {
        let root = try makeProjects([
            (dir: "-Users-t-Code", session: "abc", lines: [assistant("claude-opus-5-5")])
        ])
        #expect(ClaudeTranscript.url(
            sessionId: "nope", projectPath: "/Users/t/Code", projectsDirectory: root
        ) == nil)
        // a session id must never escape the projects directory
        #expect(ClaudeTranscript.url(
            sessionId: "../../etc/passwd", projectPath: "", projectsDirectory: root
        ) == nil)
    }

    @Test func readsTheLastModelNotTheFirst() throws {
        // a session that switched with /model reports the new one
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-opus-5"),
                #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
                assistant("claude-fable-5-1"),
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)
        #expect(ClaudeTranscript.latestModel(at: url!) == "claude-fable-5-1")
    }

    @Test func subagentModelIsNotTheSessionModel() throws {
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-opus-5-5"),
                assistant("claude-haiku-4-5", sidechain: true),
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)
        #expect(ClaudeTranscript.latestModel(at: url!) == "claude-opus-5-5")
    }

    @Test func syntheticTurnsAreNotModels() throws {
        // locally generated turns are recorded as model "<synthetic>"
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [assistant("claude-opus-5-5"), assistant("<synthetic>")]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)
        #expect(ClaudeTranscript.latestModel(at: url!) == "claude-opus-5-5")
    }

    @Test func textMentioningAModelIdIsNotMistakenForOne() throws {
        // this very repo's transcripts discuss model ids at length
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-opus-5-5"),
                #"{"type":"user","message":{"role":"user","content":"set \"model\":\"gpt-9-fake\""}}"#,
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)
        #expect(ClaudeTranscript.latestModel(at: url!) == "claude-opus-5-5")
    }

    @Test func aTruncatedFirstLineIsDiscardedNotMisparsed() throws {
        // only the tail of a multi-megabyte transcript is read, so the first
        // line in the window is usually cut in half
        let filler = String(repeating: "x", count: 4_000)
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                #"{"type":"user","message":{"role":"user","content":""# + filler + #""}}"#,
                assistant("claude-opus-5-5"),
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)
        #expect(ClaudeTranscript.latestModel(at: url!, tailBytes: 512) == "claude-opus-5-5")
    }

    @Test func noAssistantTurnInTheWindowReportsNothing() throws {
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [#"{"type":"user","message":{"role":"user","content":"hi"}}"#]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)
        #expect(ClaudeTranscript.latestModel(at: url!) == nil)
        #expect(ClaudeTranscript.latestModel(
            at: URL(fileURLWithPath: "/nonexistent/x.jsonl")
        ) == nil)
    }

    @Test func fingerprintChangesWhenTheTranscriptGrows() throws {
        let root = try makeProjects([(
            dir: "-p", session: "s", lines: [assistant("claude-opus-5-5")]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        let before = ClaudeTranscript.fingerprint(of: url)
        try (assistant("claude-opus-5-5") + "\n" + assistant("claude-sonnet-5"))
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(before != nil)
        #expect(before != ClaudeTranscript.fingerprint(of: url))
        #expect(ClaudeTranscript.fingerprint(
            of: URL(fileURLWithPath: "/nonexistent/x.jsonl")
        ) == nil)
    }
}

struct ModelSourceTests {
    @Test func transcriptWinsWhenTheSourcesNameDifferentModels() {
        // Observed live: the hook payload reported claude-fable-5-1 for a
        // session whose transcript was 160/160 claude-opus-5-5, and the
        // person running it confirmed it was Opus.
        #expect(ModelSource.claude(
            payload: "claude-fable-5-1", transcript: "claude-opus-5-5"
        ) == "claude-opus-5-5")
    }

    @Test func payloadWinsWhenItOnlyAddsAQualifier() {
        // the transcript never records the [1m] long-context variant
        #expect(ModelSource.claude(
            payload: "claude-opus-5-5[1m]", transcript: "claude-opus-5-5"
        ) == "claude-opus-5-5[1m]")
    }

    @Test func eitherSourceAloneIsEnough() {
        #expect(ModelSource.claude(payload: "claude-opus-5-5", transcript: nil)
                == "claude-opus-5-5")
        #expect(ModelSource.claude(payload: nil, transcript: "claude-opus-5")
                == "claude-opus-5")
        #expect(ModelSource.claude(payload: nil, transcript: nil) == nil)
        // a blank is not a value — it would render as an empty label and a
        // dangling separator
        #expect(ModelSource.claude(payload: "   ", transcript: nil) == nil)
        #expect(ModelSource.claude(payload: "  ", transcript: " x ") == "x")
    }

    @Test func codexCacheLosesToASnapshotWrittenAfterItWasRead() {
        let readAt = Date(timeIntervalSince1970: 1_000)
        // thread switched model, hook wrote the new one, cache is older
        #expect(ModelSource.codex(
            payload: "gpt-6-astra", cached: "gpt-5.6-sol",
            cacheReadAt: readAt,
            snapshotUpdatedAt: readAt.addingTimeInterval(60)
        ) == "gpt-6-astra")
        // cache read after the last hook event — sqlite is the live value
        #expect(ModelSource.codex(
            payload: "gpt-5.6-sol", cached: "gpt-6-astra",
            cacheReadAt: readAt,
            snapshotUpdatedAt: readAt.addingTimeInterval(-60)
        ) == "gpt-6-astra")
        // never read: the cache can't be newer than anything
        #expect(ModelSource.codex(
            payload: "gpt-6-astra", cached: "gpt-5.6-sol",
            cacheReadAt: nil, snapshotUpdatedAt: readAt
        ) == "gpt-6-astra")
        #expect(ModelSource.codex(
            payload: nil, cached: "gpt-6-astra",
            cacheReadAt: nil, snapshotUpdatedAt: readAt
        ) == "gpt-6-astra")
    }
}
