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

    private func assistant(
        _ model: String, sidechain: Bool = false, kind: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "type": "assistant",
            "isSidechain": sidechain,
            "message": ["model": model, "role": "assistant"],
        ]
        if let kind { object["sessionKind"] = kind }
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
        // Only the tail of a multi-megabyte transcript is read, so the first
        // entry in the window is usually cut in half. The fragment must be
        // dropped rather than half-parsed — and it is a *valid-looking*
        // assistant record here, so a test using invalid-JSON filler would
        // pass even without the drop.
        let head = assistant("claude-haiku-4-5") + String(repeating: " ", count: 4_000)
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [head, assistant("claude-opus-5-5")]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        #expect(ClaudeTranscript.latestModel(at: url, tailBytes: 512) == "claude-opus-5-5")
    }

    @Test func entriesOlderThanTheWindowAreNotRead() throws {
        // Proves the read is actually bounded: an implementation that
        // scanned the whole file would still find the newest entry, so the
        // fixture needs an older entry that a full scan would have to skip
        // past — and a window too small to contain it.
        let filler = String(repeating: "y", count: 4_000)
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-haiku-4-5"),
                #"{"type":"user","message":{"role":"user","content":""# + filler + #""}}"#,
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        #expect(ClaudeTranscript.latestModel(at: url, tailBytes: 256) == nil,
                "the only assistant turn is outside the window")
        #expect(ClaudeTranscript.latestModel(at: url) == "claude-haiku-4-5",
                "and is found when the window covers it")
    }

    @Test func aWindowOpeningExactlyOnANewlineKeepsItsFirstLine() throws {
        // The truncated-first-line rule assumed the window always opens
        // mid-line. Land it on the newline instead and the first entry is
        // whole — dropping it lost the only turn in the window.
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [assistant("claude-opus-5"), assistant("claude-opus-5-5")]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        let oneLine = assistant("claude-opus-5-5").utf8.count
        // the window opens on the newline terminating the first entry…
        #expect(ClaudeTranscript.latestModel(at: url, tailBytes: oneLine + 1)
                == "claude-opus-5-5")
        // …and on the very first byte of the final entry, which is the case
        // the first fix missed: the record is whole, not a fragment
        #expect(ClaudeTranscript.latestModel(at: url, tailBytes: oneLine)
                == "claude-opus-5-5")
    }

    @Test func aTurnLargerThanTheWindowReportsNothingRatherThanGuessing() throws {
        let root = try makeProjects([(
            dir: "-p", session: "s", lines: [assistant("claude-opus-5-5")]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        // no complete line fits — fall back to the payload, don't invent one
        #expect(ClaudeTranscript.latestModel(at: url, tailBytes: 20) == nil)
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

    @Test func modelAndKindComeFromTheSameSelectedRecord() throws {
        // Both fields must be read off the *chosen* entry. With one record
        // per fixture this passes even if they're sourced independently —
        // so the older entry disagrees on both.
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-opus-5", kind: "bg"),
                assistant("claude-fable-5-1"),
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        let reading = ClaudeTranscript.latest(at: url)
        #expect(reading?.model == "claude-fable-5-1")
        #expect(reading?.sessionKind == nil, "kind must not leak from the older entry")

        let reversed = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-fable-5-1"),
                assistant("claude-opus-5", kind: "bg"),
            ]
        )])
        let bgURL = ClaudeTranscript.url(
            sessionId: "s", projectPath: "", projectsDirectory: reversed
        )!
        let bg = ClaudeTranscript.latest(at: bgURL)
        #expect(bg?.model == "claude-opus-5")
        #expect(bg?.sessionKind == "bg")
    }

    @Test func onlyAnAssistantTurnReportsTheModel() throws {
        // A non-assistant record carrying a `model` key was accepted, which
        // mislabelled the model and — via sessionKind on the same record —
        // the focus explanation too.
        let root = try makeProjects([(
            dir: "-p", session: "s",
            lines: [
                assistant("claude-opus-5-5"),
                #"{"type":"user","sessionKind":"bg","message":{"role":"user","model":"gpt-9-fake"}}"#,
            ]
        )])
        let url = ClaudeTranscript.url(sessionId: "s", projectPath: "", projectsDirectory: root)!
        let reading = ClaudeTranscript.latest(at: url)
        #expect(reading?.model == "claude-opus-5-5")
        #expect(reading?.sessionKind == nil)
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

    @Test func anEventThatOmitsTheModelDoesNotRefreshItsAge() {
        // The bug this field exists for: the session switched to astra,
        // sqlite saw it, then a later hook arrived carrying no model. The
        // helper advanced updatedAt while carrying the OLD model forward,
        // so ranking on updatedAt let the stale value win — and keep
        // winning for as long as the session kept emitting events.
        let read = Date(timeIntervalSince1970: 1_000)
        #expect(ModelSource.codex(
            payload: "gpt-5.6-sol",
            payloadObservedAt: read.addingTimeInterval(-60),   // observed BEFORE the read
            cached: "gpt-6-astra",
            cacheReadAt: read,
            snapshotUpdatedAt: read.addingTimeInterval(600)    // but touched after
        ) == "gpt-6-astra")

        // and a payload that genuinely carried a newer model still wins
        #expect(ModelSource.codex(
            payload: "gpt-6-astra",
            payloadObservedAt: read.addingTimeInterval(60),
            cached: "gpt-5.6-sol",
            cacheReadAt: read,
            snapshotUpdatedAt: read.addingTimeInterval(60)
        ) == "gpt-6-astra")
    }

    @Test func snapshotsPredatingTheObservedAtFieldStillResolve() {
        let read = Date(timeIntervalSince1970: 1_000)
        // nil observedAt falls back to updatedAt rather than dropping the row
        #expect(ModelSource.codex(
            payload: "gpt-5.6-sol", payloadObservedAt: nil,
            cached: "gpt-6-astra", cacheReadAt: read,
            snapshotUpdatedAt: read.addingTimeInterval(-60)
        ) == "gpt-6-astra")
        #expect(ModelSource.codex(
            payload: "gpt-5.6-sol", payloadObservedAt: nil,
            cached: "gpt-6-astra", cacheReadAt: read,
            snapshotUpdatedAt: read.addingTimeInterval(60)
        ) == "gpt-5.6-sol")
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
