import Foundation
import Testing
@testable import AgentDeckCore

struct HostClassifierTests {
    let inner = "/Users/x/Library/Application Support/Claude/claude-code/2.1.300/ab12/claude.app"

    @Test func theOutermostBundleIsTheHost() {
        // Claude Desktop runs Claude Code from a nested claude.app; that
        // inner bundle is not where the user is
        let host = HostClassifier.classify(
            ancestorBundlePaths: [inner, "/Applications/Claude.app"],
            terminalSessionId: nil, transcriptEntrypoint: nil)
        #expect(host == SessionHost(kind: .app, bundlePath: "/Applications/Claude.app"))
    }

    @Test func aTerminalBundleIsATerminal() {
        let host = HostClassifier.classify(
            ancestorBundlePaths: ["/Applications/iTerm.app"],
            terminalSessionId: "w0t0p0:GUID", transcriptEntrypoint: nil)
        #expect(host == SessionHost(kind: .terminal, bundlePath: "/Applications/iTerm.app"))
        #expect(HostClassifier.classify(
            ancestorBundlePaths: ["/System/Applications/Utilities/Terminal.app"],
            terminalSessionId: nil, transcriptEntrypoint: nil).kind == .terminal)
    }

    @Test func aVerifiedAppHostBeatsAnInheritedITermId() {
        // a GUI launched from an iTerm shell passes ITERM_SESSION_ID on
        let host = HostClassifier.classify(
            ancestorBundlePaths: ["/Applications/Visual Studio Code.app"],
            terminalSessionId: "w0t0p0:INHERITED", transcriptEntrypoint: nil)
        #expect(host.kind == .app)
        #expect(host.bundlePath == "/Applications/Visual Studio Code.app")
    }

    @Test func noEvidenceIsUnknownNotApp() {
        #expect(HostClassifier.classify(
            ancestorBundlePaths: [], terminalSessionId: nil, transcriptEntrypoint: nil) == .unknown)
        #expect(HostClassifier.classify(
            ancestorBundlePaths: [], terminalSessionId: nil, transcriptEntrypoint: "cli") == .unknown)
    }

    @Test func fallbacksWithoutABundle() {
        #expect(HostClassifier.classify(
            ancestorBundlePaths: [], terminalSessionId: "w0t0p0:G",
            transcriptEntrypoint: nil) == SessionHost(kind: .terminal))
        #expect(HostClassifier.classify(
            ancestorBundlePaths: [], terminalSessionId: "w0t0p0:G",
            transcriptEntrypoint: "claude-desktop") == SessionHost(kind: .app))
    }

    @Test func anUnknownRecordedKindReadsAsUnknown() {
        var s = SessionSnapshot(provider: .claude, sessionId: "s", projectPath: "/",
                                state: .ready, event: "e")
        s.hostKind = "hologram"
        #expect(s.host.kind == nil)
        s.hostKind = "app"
        s.hostBundlePath = "/Applications/Claude.app"
        #expect(s.host == SessionHost(kind: .app, bundlePath: "/Applications/Claude.app"))
    }

    @Test func focusPrefersAPaneOnlyForTerminalOrUnknownHosts() {
        let pane = "w0t0p0:B4F41D67-F1B2-4A6C-A21F-4431B718477E"
        let app = SessionHost(kind: .app, bundlePath: "/Applications/Claude.app")
        #expect(FocusResolver.resolve(terminalSessionId: pane, owningAppBundlePath: inner, host: app)
                == .application(bundlePath: "/Applications/Claude.app", name: "Claude"))
        #expect(FocusResolver.resolve(terminalSessionId: pane, owningAppBundlePath: nil,
                                      host: SessionHost(kind: .terminal))
                == .itermPane(guid: "B4F41D67-F1B2-4A6C-A21F-4431B718477E"))
        #expect(FocusResolver.resolve(terminalSessionId: pane, owningAppBundlePath: nil,
                                      host: .unknown)
                == .itermPane(guid: "B4F41D67-F1B2-4A6C-A21F-4431B718477E"))
    }

    @Test func ourOwnAncestryIsReadable() {
        // the walk terminates and returns bundle paths only
        let bundles = ProcessTree.ancestorBundlePaths(startingAt: getpid())
        #expect(bundles.allSatisfy { $0.hasSuffix(".app") })
    }
}
