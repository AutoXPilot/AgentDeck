import Foundation
import Testing
@testable import AgentDeckCore

struct WorkspaceCaptureTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func row(_ provider: Provider = .claude, pane: String? = nil, mode: String? = nil) -> SessionSnapshot {
        SessionSnapshot(provider: provider, sessionId: "s", projectPath: "/hook/cwd", state: .ready,
                        event: "x", terminalSessionId: pane, permissionMode: mode)
    }

    func reg(kind: String? = "interactive", name: String? = nil, source: String? = nil,
             cwd: String? = "/registry/cwd") -> ClaudeSessionRegistry.Entry {
        ClaudeSessionRegistry.Entry(pid: 1, sessionId: "s", status: "idle", name: name,
                                    nameSource: source, kind: kind, cwd: cwd)
    }

    func capture(_ s: SessionSnapshot, _ r: ClaudeSessionRegistry.Entry?, kind: String? = nil,
                 codexName: String? = nil, terminal: WorkspaceCapture.Terminal = .unknown) -> WorkspaceEntry? {
        WorkspaceCapture.entry(for: s, registry: r, transcriptSessionKind: kind,
                               codexName: codexName, terminal: terminal, now: now)
    }

    @Test func onlyANameSomeoneChoseIsKept() {
        #expect(capture(row(), reg(name: "Home-value", source: "user"))?.displayName == "Home-value")
        #expect(capture(row(), reg(name: "fix-the-login-bug", source: "derived"))?.displayName == nil,
                "a generated name can come from the conversation")
        #expect(capture(row(.codex, pane: "w0t0p0:G"), nil, codexName: "")?.displayName == nil)
        #expect(capture(row(.codex, pane: "w0t0p0:G"), nil, codexName: "infra")?.displayName == "infra")
    }

    @Test func backgroundSessionsAreLeftOut() {
        #expect(capture(row(pane: "w0t0p0:G"), reg(kind: "bg")) == nil)
        #expect(capture(row(pane: "w0t0p0:G"), nil, kind: "bg") == nil, "kind from the transcript")
    }

    @Test func aClaudeSessionNeedsSomeSignItWasInteractive() {
        #expect(capture(row(), nil) == nil)
        #expect(capture(row(pane: "w0t0p0:G"), nil) != nil)
        #expect(capture(row(), reg()) != nil)
    }

    @Test func theRegistryCwdWinsAndTheModeIsKept() {
        let e = capture(row(mode: "acceptEdits"), reg())
        #expect(e?.cwd == "/registry/cwd")
        #expect(e?.permissionMode == "acceptEdits")
        #expect(capture(row(pane: "w0t0p0:G"), nil)?.cwd == "/hook/cwd")
    }

    @Test func aSessionKnownToRunOutsideITermIsLeftOut() {
        // restoring it would move it into iTerm
        #expect(capture(row(), reg(), terminal: .elsewhere) == nil)
        #expect(capture(row(), reg(), terminal: .iTerm) != nil)
        #expect(capture(row(), reg(), terminal: .unknown) != nil, "not knowing isn't grounds")
    }

    @Test func codexNeedsAPane() {
        #expect(capture(row(.codex), nil) == nil, "an app-hosted Codex has nowhere to return")
        #expect(capture(row(.codex, pane: "w0t0p0:G"), nil) != nil)
    }
}

struct RestoreReportTests {
    func e(_ n: Int, _ label: String) -> WorkspaceEntry {
        WorkspaceEntry(provider: .claude, sessionId: String(format: "%08d-0000-4000-8000-000000000000", n),
                       cwd: "/tmp/\(label)", lastSeen: .distantPast)
    }

    func launches(_ entries: [WorkspaceEntry]) -> [WorkspaceRestore.Launch] {
        entries.map { WorkspaceRestore.Launch(entry: $0, commandLine: "x") }
    }

    @Test func failuresSurviveIntoTheConfirmation() {
        let a = e(1, "alpha"), b = e(2, "beta"), c = e(3, "gamma")
        let report = RestoreReport(
            launches: launches([a, b, c]),
            outcomes: [a.key: .launched, b.key: .uncertain("timed out"), c.key: .failed("-1743 denied")],
            skipped: [(e(4, "delta"), .missingDirectory)])
        #expect(report.release == [c.key], "only what certainly wasn't typed is released")
        #expect(report.startedMessage == "Started 1 of 3; beta may have opened — check iTerm before "
                + "retrying; AgentDeck needs Automation permission to control iTerm2. "
                + "Skipped: delta (folder missing).")
        #expect(report.confirmationMessage(notRunning: []).hasPrefix("Restored 1 session; beta may have opened"),
                "the confirmation keeps what went wrong instead of replacing it")
    }

    @Test func theConfirmationNamesWhatIsntRunning() {
        let a = e(1, "alpha"), b = e(2, "beta")
        let report = RestoreReport(launches: launches([a, b]),
                                   outcomes: [a.key: .launched, b.key: .launched], skipped: [])
        #expect(report.confirmationMessage(notRunning: [b])
                == "1 of 2 running; not yet: beta — check those tabs for a prompt.")
        #expect(report.confirmationMessage(notRunning: []) == "Restored 2 sessions.")
    }

    @Test func aSessionThatCameBackOnItsOwnIsReleased() {
        let a = e(1, "alpha")
        let report = RestoreReport(launches: launches([a]), outcomes: [:], skipped: [])
        #expect(report.release == [a.key])
        #expect(report.startedMessage == "Started none of 1.")
    }
}
