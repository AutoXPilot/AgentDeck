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
}
