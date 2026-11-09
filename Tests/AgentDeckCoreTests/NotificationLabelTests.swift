import Testing
@testable import AgentDeckCore

struct NotificationLabelTests {
    func entry(name: String?, source: String?) -> ClaudeSessionRegistry.Entry {
        .init(pid: 1, sessionId: "s", status: "waiting", name: name, nameSource: source)
    }

    func label(
        desktop: String? = nil, claude: ClaudeSessionRegistry.Entry? = nil,
        codex: String? = nil, folder: String = "project"
    ) -> String {
        NotificationLabel.text(
            desktopTitle: desktop, claudeEntry: claude, codexName: codex,
            folder: folder, sessionId: "0123456789abcdef")
    }

    @Test func aNameTheUserSetIsUsed() {
        #expect(label(claude: entry(name: "release work", source: "user")) == "release work")
    }

    @Test func aGeneratedNameNeverLeaves() {
        #expect(label(claude: entry(name: "PROMPT-MARKER", source: "derived")) == "project")
    }

    @Test func aNameWithNoSourceNeverLeaves() {
        // builds before nameSource generated names too
        #expect(label(claude: entry(name: "PROMPT-MARKER", source: nil)) == "project")
    }

    @Test func aCodexRenameIsUsed() {
        #expect(label(codex: "renamed") == "renamed")
    }

    @Test func theDesktopLabelComesFirst() {
        #expect(label(desktop: "Claude Desktop · project",
                      claude: entry(name: "release work", source: "user"))
                == "Claude Desktop · project")
    }

    @Test func noFolderFallsBackToTheShortSessionId() {
        #expect(label(folder: "") == "session 01234567")
    }
}
