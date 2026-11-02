import Foundation
import Testing
@testable import AgentDeckCore

struct FocusTargetTests {
    @Test func iTermPaneWinsWhenPresent() {
        let target = FocusResolver.resolve(
            terminalSessionId: "w0t2p1:ABC-123",
            owningAppBundlePath: "/Applications/iTerm.app"
        )
        #expect(target == .itermPane(guid: "ABC-123"))
        #expect(target.isActionable)
    }

    @Test func guiHostedSessionFocusesItsApp() {
        // The real case: Codex running inside ChatGPT.app has no pane id,
        // but the app is a perfectly good destination.
        let target = FocusResolver.resolve(
            terminalSessionId: nil,
            owningAppBundlePath: "/Applications/ChatGPT.app"
        )
        #expect(target == .application(bundlePath: "/Applications/ChatGPT.app", name: "ChatGPT"))
        #expect(target.isActionable)
    }

    @Test func neitherPaneNorAppIsNotActionable() {
        let target = FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: nil)
        #expect(target == .none)
        #expect(!target.isActionable)
        // an empty/prefix-only pane id doesn't count either
        #expect(FocusResolver.resolve(
            terminalSessionId: "w0t0p0:", owningAppBundlePath: nil) == .none)
    }

    @Test func anUnfocusableBackgroundSessionSaysWhereToAnswerIt() {
        // Observed live: a session blocked on a permission prompt, started
        // via slash command as `claude --bg-pty-host` and reparented to
        // launchd. Correct that it can't be focused; useless to stop there.
        let message = FocusResolver.describe(.none, sessionKind: "bg")
        #expect(message.contains("agents panel"))
        #expect(!message.contains("No terminal pane or app recorded"))
        #expect(FocusResolver.isBackground(sessionKind: "bg"))
        #expect(FocusResolver.isBackground(sessionKind: "BG"))
        #expect(!FocusResolver.isBackground(sessionKind: "interactive"))
        #expect(!FocusResolver.isBackground(sessionKind: nil))
    }

    @Test func focusableRowsDescribeTheirDestination() {
        #expect(FocusResolver.describe(.itermPane(guid: "G")).contains("iTerm pane"))
        #expect(FocusResolver.describe(
            .application(bundlePath: "/Applications/ChatGPT.app", name: "ChatGPT")
        ) == "Click to bring ChatGPT to the front")
        // a pane always wins, even for a background-kind session
        #expect(FocusResolver.describe(.itermPane(guid: "G"), sessionKind: "bg")
            .contains("iTerm pane"))
        #expect(FocusResolver.describe(.none).contains("click just dismisses it"))
    }

    @Test func appNameExtraction() {
        #expect(FocusResolver.appName(fromBundlePath: "/Applications/ChatGPT.app") == "ChatGPT")
        #expect(FocusResolver.appName(fromBundlePath: "/Users/x/Applications/AgentDeck.app")
            == "AgentDeck")
        #expect(FocusResolver.appName(fromBundlePath: "/usr/bin/codex") == nil)
        #expect(FocusResolver.appName(fromBundlePath: ".app") == nil)
    }
}

struct OwningBundleTests {
    @Test func extractsBundleFromExecutablePath() {
        #expect(ProcessTree.bundlePath(
            fromExecutablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
            == "/Applications/ChatGPT.app")
        #expect(ProcessTree.bundlePath(
            fromExecutablePath: "/Users/x/Applications/AgentDeck.app/Contents/MacOS/AgentDeck")
            == "/Users/x/Applications/AgentDeck.app")
    }

    @Test func nonBundleExecutablesHaveNoBundle() {
        #expect(ProcessTree.bundlePath(fromExecutablePath: "/opt/homebrew/bin/codex") == nil)
        #expect(ProcessTree.bundlePath(fromExecutablePath: "/bin/zsh") == nil)
        #expect(ProcessTree.bundlePath(fromExecutablePath: "") == nil)
    }

    @Test func walkFromOurOwnProcessTerminatesCleanly() {
        // the test runner isn't in a .app; the walk must end, not hang or crash
        _ = ProcessTree.owningApplicationBundle(of: getpid())
    }

    @Test func aChatGPTThreadOpensItselfByLink() {
        // verified live: ChatGPT opens codex://threads/<id> on that thread
        let chatgpt = SessionHost(kind: .app, bundlePath: "/Applications/ChatGPT.app")
        let id = "01A163C8-1E31-7321-9683-010EB69E7904"
        let target = FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: nil,
                                           host: chatgpt, provider: .codex, sessionId: id)
        #expect(target == .appURL(URL(string: "codex://threads/01a163c8-1e31-7321-9683-010eb69e7904")!,
                                  name: "ChatGPT"))
        #expect(FocusResolver.describe(target) == "Click to open this thread in ChatGPT")
    }

    @Test func onlyAValidCodexThreadInChatGPTGetsALink() {
        let chatgpt = SessionHost(kind: .app, bundlePath: "/Applications/ChatGPT.app")
        let uuid = "01a163c8-1e31-7321-9683-010eb69e7904"
        // not a UUID: nothing but a canonical id may reach the URL
        #expect(FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: nil, host: chatgpt,
                                      provider: .codex, sessionId: "x/../evil?y")
                == .application(bundlePath: "/Applications/ChatGPT.app", name: "ChatGPT"))
        // Claude in Claude Desktop has no verified link: bring the app forward
        let desktop = SessionHost(kind: .app, bundlePath: "/Applications/Claude.app")
        #expect(FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: nil, host: desktop,
                                      provider: .claude, sessionId: uuid)
                == .application(bundlePath: "/Applications/Claude.app", name: "Claude"))
        // Codex in a terminal keeps its pane
        #expect(FocusResolver.resolve(terminalSessionId: "w0t0p0:GUID", owningAppBundlePath: nil,
                                      host: SessionHost(kind: .terminal, bundlePath: "/Applications/iTerm.app"),
                                      provider: .codex, sessionId: uuid) == .itermPane(guid: "GUID"))
    }
}
