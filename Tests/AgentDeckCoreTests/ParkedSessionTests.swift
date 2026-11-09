import Foundation
import Testing
@testable import AgentDeckCore

/// A session moved to the background: the conversation carries on in a job,
/// and the window it left drops to the agents view. Shapes from Claude Code
/// 2.1.310 (window) and 2.1.319 (job); ids synthetic.
private let windowId = "be846d7d-265c-4d12-83e5-16cc4586aea8"
private let jobSession = "a371a042-a85e-48b5-a0fb-183d822ec73c"
private let job = "a371a042"
private let pane = "w0t0p0:84C6182F-BADB-4E9B-AD22-3E3CC27AA68E"
private let now = Date(timeIntervalSince1970: 1_793_980_000)

private func windowEntry(parked: String? = job, pid: Int32 = 12731) -> ClaudeSessionRegistry.Entry {
    ClaudeSessionRegistry.Entry(pid: pid, sessionId: windowId, status: "idle", name: "troubleshoot-problem",
                                nameSource: "user", kind: "interactive", parkedJobId: parked,
                                cwd: "/p", statusUpdatedAt: now.addingTimeInterval(-3600))
}

private func jobEntry(status: String = "busy", id: String? = job, spare: Bool = false) -> ClaudeSessionRegistry.Entry {
    ClaudeSessionRegistry.Entry(pid: 18587, sessionId: jobSession, status: status,
                                waitingFor: status == "waiting" ? "permission prompt" : nil,
                                name: "troubleshoot-problem", kind: "bg", isSpare: spare, jobId: id,
                                cwd: "/p", statusUpdatedAt: now)
}

private func windowRow(state: SessionState = .done, pid: Int32 = 12731) -> SessionSnapshot {
    SessionSnapshot(provider: .claude, sessionId: windowId, projectPath: "/p", state: state, event: "Stop",
                    updatedAt: now.addingTimeInterval(-3600), terminalSessionId: pane, agentPid: pid)
}

private func jobRow(state: SessionState = .working) -> SessionSnapshot {
    SessionSnapshot(provider: .claude, sessionId: jobSession, projectPath: "/p", state: state,
                    event: "UserPromptSubmit", updatedAt: now, agentPid: 18587)
}

private func run(_ rows: [SessionSnapshot], live: [ClaudeSessionRegistry.Entry]) -> SessionPipeline.Output {
    SessionPipeline.run(snapshots: rows, registry: [:],
                        liveSessions: Dictionary(uniqueKeysWithValues: live.map { ($0.sessionId, $0) }),
                        acks: [:], frozenOrder: nil, popoverVisible: false, now: now)
}

private let jobKey = SessionKey.make(.claude, jobSession)

struct ParkedPairTests {
    @Test func parsesTheJobAndParkingFields() throws {
        let window = #"{"pid":1,"sessionId":"x","status":"idle","kind":"interactive","parkedJobId":"a371a042"}"#
        #expect(try #require(ClaudeSessionRegistry.parse(Data(window.utf8))).parkedJobId == "a371a042")
        let bg = #"{"pid":2,"sessionId":"y","status":"busy","kind":"bg","jobId":"a371a042"}"#
        #expect(try #require(ClaudeSessionRegistry.parse(Data(bg.utf8))).jobId == "a371a042")
    }

    @Test func aPairIsOneRowWithTheJobsState() {
        let out = run([windowRow(), jobRow()], live: [windowEntry(), jobEntry()])
        #expect(out.rows.map(\.sessionId) == [jobSession])
        #expect(out.rows.first?.state == .working)
        // the pane is an association, not something the job recorded
        #expect(out.rows.first?.terminalSessionId == nil)
        #expect(out.parkedWindows[jobKey]?.pane == pane)
        #expect(out.parkedWindows[jobKey]?.entry.pid == 12731)
    }

    @Test func aPairCountsOnce() {
        let out = run([windowRow(state: .done), jobRow(state: .done)], live: [windowEntry(), jobEntry(status: "idle")])
        #expect(out.doneCount == 1)
        let waiting = run([windowRow(state: .waiting), jobRow(state: .waiting)],
                          live: [windowEntry(), jobEntry(status: "waiting")])
        #expect(waiting.alertCount == 1)
    }

    @Test func aWaitingJobKeepsItsReason() {
        let out = run([windowRow(), jobRow(state: .waiting)], live: [windowEntry(), jobEntry(status: "waiting")])
        #expect(out.waitingReasons[jobKey] != nil)
    }

    @Test func aWindowsStalePaneIsNotCarriedOver() {
        // its last hook ran in an earlier process
        let out = run([windowRow(pid: 999), jobRow()], live: [windowEntry(), jobEntry()])
        #expect(out.parkedWindows[jobKey]?.pane == nil)
        #expect(out.parkedWindows[jobKey]?.entry.pid == 12731)
    }

    @Test func aJobNoHookReportedStillGetsTheRow() {
        let out = run([windowRow()], live: [windowEntry(), jobEntry()])
        #expect(out.rows.map(\.sessionId) == [jobSession])
        #expect(out.parkedWindows[jobKey]?.pane == pane)
    }

    @Test func aWindowNoHookReportedStillPairs() {
        let out = run([jobRow()], live: [windowEntry(), jobEntry()])
        #expect(out.rows.map(\.sessionId) == [jobSession])
        #expect(out.parkedWindows[jobKey]?.pane == nil)
        #expect(out.parkedWindows[jobKey]?.entry.pid == 12731)
    }

    @Test func aDeadJobGivesTheWindowItsRowBack() {
        let out = run([windowRow(state: .working)], live: [windowEntry()])
        #expect(out.rows.map(\.sessionId) == [windowId])
        #expect(out.rows.first?.terminalSessionId == pane)
        #expect(out.parkedWindows.isEmpty)
        // nothing invents a "done" the hooks never reported
        #expect(out.rows.first?.state != .done)
    }

    @Test func aDeadWindowLeavesTheJobAlone() {
        let out = run([jobRow()], live: [jobEntry()])
        #expect(out.rows.map(\.sessionId) == [jobSession])
        #expect(out.parkedWindows.isEmpty)
    }

    @Test func otherJobsDoNotPair() {
        let out = run([windowRow(), jobRow()], live: [windowEntry(parked: "ffffffff"), jobEntry()])
        #expect(out.rows.count == 2)
        #expect(out.parkedWindows.isEmpty)
        #expect(run([windowRow(), jobRow()], live: [windowEntry(), jobEntry(id: nil)]).rows.count == 2)
    }

    @Test func onlyAWindowAndAJobPair() {
        var notBg = jobEntry()
        notBg.kind = "interactive"
        #expect(run([windowRow(), jobRow()], live: [windowEntry(), notBg]).rows.count == 2)
        var notInteractive = windowEntry()
        notInteractive.kind = "bg"
        #expect(run([windowRow(), jobRow()], live: [notInteractive, jobEntry()]).rows.count == 2)
    }

    @Test func aSpareNeverPairs() {
        let out = run([windowRow()], live: [windowEntry(), jobEntry(spare: true)])
        #expect(out.rows.map(\.sessionId) == [windowId])
        #expect(out.parkedWindows.isEmpty)
    }

    @Test func anotherProvidersIdIsLeftAlone() {
        var codex = windowRow()
        codex.provider = .codex
        let rows = run([codex, jobRow()], live: [windowEntry(), jobEntry()]).rows
        #expect(Set(rows.map(\.provider)) == [.codex, .claude])
    }

    @Test func parkingAndReturningAcrossReloads() {
        let rows = [windowRow(), jobRow()]
        #expect(run(rows, live: [windowEntry(parked: nil)]).rows.map(\.sessionId).contains(windowId))
        #expect(run(rows, live: [windowEntry(), jobEntry()]).rows.count == 1)
        // back in the window: the field clears and the pair ends by itself
        #expect(run(rows, live: [windowEntry(parked: nil), jobEntry()]).rows.count == 2)
        // parked again on another job
        var second = jobEntry(id: "bbbbbbbb")
        second.sessionId = "b0000000-0000-4000-8000-000000000000"
        let out = run([windowRow()], live: [windowEntry(parked: "bbbbbbbb"), second, jobEntry()])
        #expect(out.parkedWindows.keys.map { $0 } == [SessionKey.make(.claude, second.sessionId)])
    }

    @Test func theTerminalIsTheWindowsForAPairedRow() {
        let windows = [jobKey: ParkedWindow(entry: windowEntry())]
        #expect(SessionPipeline.terminalPid(for: jobRow(), registryPid: 18587, parkedWindows: windows) == 12731)
        #expect(SessionPipeline.terminalPid(for: jobRow(), registryPid: 18587, parkedWindows: [:]) == 18587)
        #expect(SessionPipeline.terminalPid(for: jobRow(), registryPid: nil, parkedWindows: [:]) == 18587)
    }

    @Test func focusingAParkedWindowDoesNotClearAWait() {
        let windows = [jobKey: ParkedWindow(entry: windowEntry())]
        #expect(!SessionPipeline.focusAcknowledges(jobRow(state: .waiting), parkedWindows: windows))
        #expect(SessionPipeline.focusAcknowledges(jobRow(state: .done), parkedWindows: windows))
        #expect(SessionPipeline.focusAcknowledges(jobRow(state: .waiting), parkedWindows: [:]))
    }
}

struct BackgroundFocusTests {
    @Test func aWindowlessBackgroundSessionHasNowhereToGo() {
        let iTerm = "/Applications/iTerm.app"
        #expect(FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: iTerm,
                                      isBackground: true) == .none)
        #expect(FocusResolver.resolve(terminalSessionId: pane, owningAppBundlePath: iTerm,
                                      isBackground: true) == .none)
        #expect(FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: nil,
                                      host: SessionHost(kind: .app, bundlePath: "/Applications/Claude.app"),
                                      isBackground: true) == .none)
    }

    @Test func everythingElseResolvesAsBefore() {
        let target = FocusResolver.resolve(terminalSessionId: pane, owningAppBundlePath: nil)
        #expect(target == .itermPane(guid: "84C6182F-BADB-4E9B-AD22-3E3CC27AA68E"))
        if case .application = FocusResolver.resolve(terminalSessionId: nil, owningAppBundlePath: "/Applications/iTerm.app") {
        } else {
            Issue.record("an ordinary session with no pane still raises its app")
        }
    }

    @Test func aParkedPaneSaysWhereItLeads() {
        let target = FocusTarget.itermPane(guid: "x")
        #expect(FocusResolver.describe(target, inAgentsView: true).contains("agents view"))
        #expect(!FocusResolver.describe(target).contains("agents view"))
    }
}

struct ContinuationTests {
    private func transcript(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-cont-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(windowId).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private let link = #"{"type":"continued-in","sessionId":"\#(windowId)","continuedInSessionId":"\#(jobSession)","timestamp":"2026-11-06T15:45:34.119Z"}"#
    private let user = #"{"type":"user","message":{"role":"user","content":"hi"}}"#

    @Test func readsTheLink() throws {
        #expect(ClaudeTranscript.continuedIn(at: try transcript([user, link])) == jobSession)
        // bookkeeping records after it don't matter
        #expect(ClaudeTranscript.continuedIn(at: try transcript([user, link, #"{"type":"cost-state"}"#])) == jobSession)
    }

    @Test func aConversationThatWentOnHereDidNotMove() throws {
        #expect(ClaudeTranscript.continuedIn(at: try transcript([link, user])) == nil)
        #expect(ClaudeTranscript.continuedIn(at: try transcript([link, #"{"type":"assistant"}"#])) == nil)
    }

    @Test func textMentioningTheRecordIsNotOne() throws {
        let quoted = #"{"type":"user","message":{"content":"{\"type\":\"continued-in\",\"continuedInSessionId\":\"\#(jobSession)\"}"}}"#
        #expect(ClaudeTranscript.continuedIn(at: try transcript([quoted])) == nil)
    }

    @Test func anIdThatIsNotAUUIDIsIgnored() throws {
        let bad = #"{"type":"continued-in","continuedInSessionId":"../../etc"}"#
        #expect(ClaudeTranscript.continuedIn(at: try transcript([bad])) == nil)
    }

    @Test func noLinkOrNoFile() throws {
        #expect(ClaudeTranscript.continuedIn(at: try transcript([user])) == nil)
        #expect(ClaudeTranscript.continuedIn(at: URL(fileURLWithPath: "/no/such/file")) == nil)
    }

    @Test func aLineCutOffByTheTailIsNotBelieved() throws {
        // the marker is inside the tail, the start of its record isn't
        let padding = String(repeating: "x", count: 200)
        let cut = #"{"pad":"\#(padding)","type":"continued-in","continuedInSessionId":"\#(jobSession)"}"#
        let url = try transcript([cut, #"{"type":"cost-state"}"#])
        #expect(ClaudeTranscript.continuedIn(at: url, tailBytes: 120) == nil)
        #expect(ClaudeTranscript.continuedIn(at: url) == jobSession)
    }

    private func projects() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-proj-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(ClaudeTranscript.slug(for: "/p"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder)
    }

    private var entry: WorkspaceEntry {
        WorkspaceEntry(provider: .claude, sessionId: windowId, cwd: "/p", lastSeen: now)
    }

    @Test func continuationsFollowAChangedTranscript() throws {
        let (root, folder) = try projects()
        let url = folder.appendingPathComponent("\(windowId).jsonl")
        try Data((link + "\n").utf8).write(to: url)
        var continuations = ClaudeContinuations()
        continuations.update([entry], projectsDirectory: root)
        #expect(continuations.successors[windowId] == jobSession)
        // the conversation went on here after all
        try Data((link + "\n" + user + "\n").utf8).write(to: url)
        continuations.update([entry], projectsDirectory: root)
        #expect(continuations.successors[windowId] == nil)
    }

    @Test func anUnchangedTranscriptIsNotReadAgain() throws {
        let (root, folder) = try projects()
        let url = folder.appendingPathComponent("\(windowId).jsonl")
        try Data((link + "\n").utf8).write(to: url)
        // whole seconds: setting a date back doesn't keep sub-second digits
        let stamp = Date(timeIntervalSince1970: 1_793_980_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        var continuations = ClaudeContinuations()
        continuations.update([entry], projectsDirectory: root)
        // same size and date, different contents: only a re-read would see it
        let other = link.replacingOccurrences(of: "continued-in", with: "continued-xx")
        try Data((other + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        continuations.update([entry], projectsDirectory: root)
        #expect(continuations.successors[windowId] == jobSession)
    }

    @Test func aDeletedTranscriptTakesItsLinkWithIt() throws {
        let (root, folder) = try projects()
        let url = folder.appendingPathComponent("\(windowId).jsonl")
        try Data((link + "\n").utf8).write(to: url)
        var continuations = ClaudeContinuations()
        continuations.update([entry], projectsDirectory: root)
        try FileManager.default.removeItem(at: url)
        continuations.update([entry], projectsDirectory: root)
        #expect(continuations.successors.isEmpty)
    }

    @Test func aChainIsFollowedThroughSessionsNotInAnySavedSet() throws {
        let (root, folder) = try projects()
        let third = "c0000000-0000-4000-8000-000000000000"
        try Data((link + "\n").utf8).write(to: folder.appendingPathComponent("\(windowId).jsonl"))
        let next = #"{"type":"continued-in","continuedInSessionId":"\#(third)"}"#
        try Data((next + "\n").utf8).write(to: folder.appendingPathComponent("\(jobSession).jsonl"))
        var continuations = ClaudeContinuations()
        continuations.update([entry], projectsDirectory: root)
        let successors = continuations.successors
        #expect(WorkspaceRestore.latest(entry, successor: { successors[$0.sessionId] }).sessionId == third)
    }

    @Test func otherProvidersHaveNoLink() throws {
        let (root, folder) = try projects()
        try Data((link + "\n").utf8).write(to: folder.appendingPathComponent("\(windowId).jsonl"))
        var codex = entry
        codex.provider = .codex
        var continuations = ClaudeContinuations()
        continuations.update([codex], projectsDirectory: root)
        #expect(continuations.successors.isEmpty)
    }
}

struct RestoreContinuationTests {
    private let window = WorkspaceEntry(provider: .claude, sessionId: windowId, cwd: "/tmp",
                                        displayName: "troubleshoot-problem", lastSeen: now)
    private let jobEntry = WorkspaceEntry(provider: .claude, sessionId: jobSession, cwd: "/tmp", lastSeen: now)

    private func link(_ entry: WorkspaceEntry) -> String? { entry.sessionId == windowId ? jobSession : nil }

    private func facts(live: Set<String> = [], exists: @escaping (WorkspaceEntry) -> Bool? = { _ in true }) -> WorkspaceRestore.Facts {
        WorkspaceRestore.Facts(live: live, directoryExists: { _ in true }, conversationExists: exists,
                               appHosted: { _ in false }, successor: { $0.sessionId == windowId ? jobSession : nil })
    }

    @Test func aChainEndsAtTheNewestAndCannotLoop() {
        let c = "c0000000-0000-4000-8000-000000000000"
        let chain = [windowId: jobSession, jobSession: c]
        #expect(WorkspaceRestore.latest(window, successor: { chain[$0.sessionId] }).sessionId == c)
        let loop = [windowId: jobSession, jobSession: windowId]
        #expect(WorkspaceRestore.latest(window, successor: { loop[$0.sessionId] }).sessionId == jobSession)
        var codex = window
        codex.provider = .codex
        #expect(WorkspaceRestore.latest(codex, successor: { chain[$0.sessionId] }).sessionId == windowId)
    }

    @Test func aChainIsBounded() {
        var calls = 0
        _ = WorkspaceRestore.latest(window, successor: { _ in calls += 1; return UUID().uuidString })
        #expect(calls == WorkspaceRestore.maxContinuations)
    }

    @Test func theOldIdLaunchesTheNewestConversation() {
        let plan = WorkspaceRestore.plan([window], facts: facts())
        #expect(plan.launches.map(\.entry.sessionId) == [jobSession])
        #expect(plan.launches.first?.commandLine.contains(jobSession) == true)
        #expect(plan.launches.first?.entry.displayName == "troubleshoot-problem")
    }

    @Test func bothIdsInASetLaunchOnce() {
        #expect(WorkspaceRestore.plan([window, jobEntry], facts: facts()).launches.count == 1)
    }

    @Test func aRunningSuccessorIsAlreadyOpen() {
        let plan = WorkspaceRestore.plan([window], facts: facts(live: [jobEntry.key]))
        #expect(plan.launches.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.alreadyOpen])
    }

    @Test func aMissingSuccessorFallsBackToTheEntry() {
        let plan = WorkspaceRestore.plan([window], facts: facts(exists: { $0.sessionId == windowId }))
        #expect(plan.launches.map(\.entry.sessionId) == [windowId])
    }

    @Test func aSkipNamesTheEntryAsSaved() {
        // Locate… rewrites the saved entry, which holds the old id
        let missing = WorkspaceRestore.Facts(
            live: [], directoryExists: { _ in false }, conversationExists: { _ in true },
            appHosted: { _ in false }, successor: { $0.sessionId == windowId ? jobSession : nil })
        let plan = WorkspaceRestore.plan([window], facts: missing)
        #expect(plan.skipped.map(\.entry.sessionId) == [windowId])
        #expect(plan.skipped.map(\.reason) == [.missingDirectory])
    }

    @Test func anEntryRunningUnderANewerIdIsNotOffered() {
        #expect(WorkspaceRestore.continuesInRunningSession(window, live: [jobEntry.key], successor: link))
        #expect(!WorkspaceRestore.continuesInRunningSession(window, live: [], successor: link))
        #expect(!WorkspaceRestore.continuesInRunningSession(jobEntry, live: [jobEntry.key], successor: link))
    }
}

struct ParkedCaptureTests {
    private func capture(window: ClaudeSessionRegistry.Entry?, terminal: WorkspaceCapture.Terminal = .iTerm) -> WorkspaceEntry? {
        WorkspaceCapture.entry(for: jobRow(), registry: jobEntry(), transcriptSessionKind: "bg", codexName: nil,
                               parkedWindow: window, terminal: terminal, now: now)
    }

    @Test func aParkedJobIsCapturedWithTheWindowsName() {
        let entry = capture(window: windowEntry())
        #expect(entry?.sessionId == jobSession)
        #expect(entry?.displayName == "troubleshoot-problem")
    }

    @Test func aGeneratedWindowNameIsNotKept() {
        var derived = windowEntry()
        derived.nameSource = "derived"
        #expect(capture(window: derived)?.displayName == nil)
    }

    @Test func aWindowlessJobIsStillSkipped() {
        #expect(capture(window: nil) == nil)
    }

    @Test func aWindowElsewhereIsStillSkipped() {
        #expect(capture(window: windowEntry(), terminal: .elsewhere) == nil)
    }
}
