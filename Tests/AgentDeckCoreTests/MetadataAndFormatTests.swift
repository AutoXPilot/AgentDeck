import Foundation
import Testing
@testable import AgentDeckCore

struct PathFormatTests {
    let home = "/Users/someone"

    @Test func abbreviatesHomeAndKeepsTail() {
        #expect(PathFormat.abbreviate("/Users/someone/Code/version2", home: home)
            == "~/Code/version2")
        #expect(PathFormat.abbreviate("/Users/someone/Code/knowledge/documentation", home: home)
            == "~/…/knowledge/documentation")
        #expect(PathFormat.abbreviate(home, home: home) == "~")
    }

    @Test func handlesNonHomeAndShortPaths() {
        #expect(PathFormat.abbreviate("/tmp", home: home) == "/tmp")
        #expect(PathFormat.abbreviate("/opt/homebrew/var/foo", home: home) == "…/var/foo")
        #expect(PathFormat.abbreviate("", home: home) == "")
    }
}

struct CodexThreadsTests {
    @Test func parsesRowsFromSqliteOutput() {
        let sep = "\u{1}"
        let output = [
            ["019fb864", "gpt-5.6-sol", "high", "7003838",
             "", "on-request", "{\"type\":\"disabled\"}"].joined(separator: sep),
            ["019faf3a", "gpt-5.6-sol", "high", "15579",
             "V2B-1488", "never", "{\"type\":\"managed\"}"].joined(separator: sep),
        ].joined(separator: "\n")
        let threads = CodexThreads.parse(output)
        #expect(threads.count == 2)
        let first = threads["019fb864"]
        #expect(first?.model == "gpt-5.6-sol")
        #expect(first?.tokensUsed == 7_003_838)
        #expect(first?.gitBranch == nil, "empty column is NULL, not an empty branch")
        #expect(first?.isUnsupervised == true, "sandbox disabled means unsupervised")
        #expect(threads["019faf3a"]?.gitBranch == "V2B-1488")
        #expect(threads["019faf3a"]?.isUnsupervised == true, "approval 'never' is unsupervised")
    }

    @Test func promptTextIsNeverReadFromTheCodexStore() {
        // `threads.title` holds the first user message whenever a thread
        // wasn't renamed, and nothing in the schema says which it is. The
        // old guard displayed anything under 60 characters, which let
        // "Help me research this problem" — a real prompt from this
        // machine — reach row titles and notification bodies.
        //
        // The column is no longer selected, so the guarantee is structural:
        // there is no property to leak it through.
        #expect(!CodexThreads.query.contains("title"))

        // and a row of the old 8-column shape is rejected rather than
        // silently shifting prompt text into the model field
        let legacy = ["019fb864", "Help me research this problem", "gpt-6-astra",
                      "high", "100", "", "never", "{}"].joined(separator: "\u{1}")
        let parsed = CodexThreads.parse(legacy)
        #expect(parsed["019fb864"]?.model != "Help me research this problem")
    }

    @Test func skipsMalformedLines() {
        #expect(CodexThreads.parse("").isEmpty)
        #expect(CodexThreads.parse("too\u{1}few").isEmpty)
    }

    @Test func loadFromMissingFileIsEmpty() {
        #expect(CodexThreads.load(from: URL(fileURLWithPath: "/nonexistent/db.sqlite")).isEmpty)
    }
}

struct VersionTests {
    @Test func versionMatchesTheVersionFile() throws {
        // The VERSION file drives the app bundle and Homebrew; the constant
        // drives the UI and diagnostics. They must not drift.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentDeckCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let fileVersion = try String(
            contentsOf: repoRoot.appendingPathComponent("VERSION"), encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fileVersion == AgentDeckVersion.current)
    }
}
