import Foundation
import Testing
@testable import AgentDeckCore

private let dir = "/Users/me/.gemini/antigravity-cli/presence"
private func id(_ n: Int) -> String { String(format: "%08d-0000-4000-8000-000000000000", n) }
private func lock(_ n: Int) -> String { "\(dir)/\(id(n)).lock" }

struct AgyPresenceResolveTests {
    @Test func eachHeldLockMapsToTheProcessHoldingItOpen() {
        let p = AgyPresence.resolve(held: [id(1), id(2)],
                                    lockPaths: [10: [lock(1)], 20: [lock(2), lock(2)]],
                                    presenceDirectory: dir)
        #expect(p.listed)
        #expect(p.holderOf == [id(1): 10, id(2): 20], "a duplicate fd is one")
        #expect(p.heldBy == [10: id(1), 20: id(2)])
    }

    @Test func anOpenFileWhoseLockIsntHeldProvesNothing() {
        let p = AgyPresence.resolve(held: [], lockPaths: [10: [lock(1)]], presenceDirectory: dir)
        #expect(p.holderOf.isEmpty && p.heldBy.isEmpty)
    }

    @Test func ambiguityEitherWayMapsNeither() {
        let twoPids = AgyPresence.resolve(held: [id(1)], lockPaths: [10: [lock(1)], 20: [lock(1)]],
                                          presenceDirectory: dir)
        #expect(twoPids.holderOf.isEmpty && twoPids.heldBy.isEmpty && twoPids.ambiguous == [id(1)])
        let twoIds = AgyPresence.resolve(held: [id(1), id(2)], lockPaths: [10: [lock(1), lock(2)]],
                                         presenceDirectory: dir)
        #expect(twoIds.holderOf.isEmpty && twoIds.heldBy.isEmpty && twoIds.ambiguous == [id(1), id(2)])
    }

    @Test func onlyPresenceLocksInTheResolvedFolderCount() {
        let p = AgyPresence.resolve(
            held: [id(1)],
            lockPaths: [10: ["/elsewhere/presence/\(id(1)).lock", "\(dir)/not-a-uuid.lock",
                             "\(dir)/sub/\(id(1)).lock", "\(dir)/\(id(1)).db"]],
            presenceDirectory: dir + "/")
        #expect(p.holderOf.isEmpty)
    }

    @Test func anUnreadableProcessIsMarkedNotTreatedAsHoldingNothing() {
        let p = AgyPresence.resolve(held: [id(1)], lockPaths: [10: nil], presenceDirectory: dir)
        #expect(p.unreadable == [10])
        #expect(!p.movedOn(pid: 10, from: id(1)))
    }

    @Test func anUnlistedFolderIsNoEvidence() {
        let p = AgyPresence.resolve(held: nil, lockPaths: [10: [lock(2)]], presenceDirectory: dir)
        #expect(!p.listed)
        #expect(!p.movedOn(pid: 10, from: id(1)))
    }

    @Test func aProcessMovedOnOnlyWhenItHoldsAnotherConversation() {
        let p = AgyPresence.resolve(held: [id(2)], lockPaths: [10: [lock(2)], 30: []],
                                    presenceDirectory: dir)
        #expect(p.movedOn(pid: 10, from: id(1)))
        #expect(!p.movedOn(pid: 10, from: id(2)))
        #expect(!p.movedOn(pid: 30, from: id(1)), "a process holding nothing may still be in it")
    }

    @Test func theFolderIsNamedAsTheKernelNamesItThroughASymlink() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("presence"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"),
                                                   withDestinationURL: real)
        // the production helper, given the symlinked folder agy's home might be
        let named = AgyPresence.presenceDirectory(base.appendingPathComponent("link"))
        #expect(!named.contains("/link/"))
        let kernelPath = real.appendingPathComponent("presence/\(id(1)).lock").resolvingSymlinksInPath().path
        let p = AgyPresence.resolve(held: [id(1)], lockPaths: [10: [kernelPath]], presenceDirectory: named)
        #expect(p.holderOf == [id(1): 10])
    }
}

struct AgyRunningTests {
    private func row(_ n: Int, pid: Int32?) -> SessionSnapshot {
        SessionSnapshot(provider: .antigravity, sessionId: id(n), projectPath: "/tmp",
                        state: .done, event: "Stop", updatedAt: Date(timeIntervalSince1970: 1000),
                        agentPid: pid)
    }
    private func evidence(_ agy: AgyPresence) -> RunningEvidence {
        RunningEvidence(claudeRegistryLive: [],
                        presenceLive: Set(agy.held.map { SessionKey.make(.antigravity, $0) }),
                        agy: agy, pidTrusted: { _, _, _ in true })
    }
    // 13146 ran child-care (1), then switched to travel-planning (2)
    private let switched = AgyPresence.resolve(held: [id(2)], lockPaths: [13146: [lock(2)], 12780: []],
                                               presenceDirectory: dir)

    @Test func aPidThatMovedToAnotherConversationNoLongerKeepsTheOldOneRunning() {
        let keys = evidence(switched).runningKeys(rows: [row(1, pid: 13146), row(2, pid: 13146)])
        #expect(keys == [SessionKey.make(.antigravity, id(2))])
    }

    @Test func aLocklessProcessStillCounts() {
        let keys = evidence(switched).runningKeys(rows: [row(3, pid: 12780)])
        #expect(keys == [SessionKey.make(.antigravity, id(3)), SessionKey.make(.antigravity, id(2))],
                "3 on its lockless pid, 2 held")
    }

    @Test func withoutTheFolderThePidRuleStands() {
        let keys = evidence(.unknown).runningKeys(rows: [row(1, pid: 13146)])
        #expect(keys == [SessionKey.make(.antigravity, id(1))])
    }

    @Test func theFreshCheckBeforeALaunchAgrees() {
        let entry = WorkspaceEntry(provider: .antigravity, sessionId: id(1), cwd: "/tmp", lastSeen: .distantPast)
        #expect(!evidence(switched).isRunning(entry, snapshot: row(1, pid: 13146)))
        #expect(evidence(.unknown).isRunning(entry, snapshot: row(1, pid: 13146)))
        let fresh = RunningEvidence.reading(for: .antigravity, claudeLive: { ["x"] },
                                            agy: { self.switched }, codexDaemonThreads: { ["y"] })
        #expect(fresh.presenceLive == [SessionKey.make(.antigravity, id(2))])
        #expect(fresh.claudeRegistryLive.isEmpty && fresh.daemonLive.isEmpty, "only agy's source is read")
    }
}

struct AgyPipelineTests {
    let now = Date(timeIntervalSince1970: 10_000)
    let presence = AgyPresence.resolve(held: [id(2), id(5)],
                                       lockPaths: [13146: [lock(2)], 12222: [lock(5)], 12780: []],
                                       presenceDirectory: dir)

    private func row(_ n: Int, pid: Int32?, age: TimeInterval, pane: String? = "w0t0p0:PANE") -> SessionSnapshot {
        SessionSnapshot(provider: .antigravity, sessionId: id(n), projectPath: "/tmp", state: .done,
                        event: "Stop", updatedAt: now.addingTimeInterval(-age),
                        terminalSessionId: pane, agentPid: pid)
    }
    private func fix(_ r: SessionSnapshot, trusted: Bool = true) -> (SessionSnapshot, Int32?) {
        let out = SessionPipeline.correctAgy(r, agy: presence, now: now, pidTrusted: { _, _ in trusted })
        return (out.row, out.adopted)
    }

    @Test func aRowWhoseProcessMovedOnLosesItsPaneAfterTheGrace() {
        let (stale, adopted) = fix(row(1, pid: 13146, age: 61))
        #expect(stale.agentPid == nil && stale.terminalSessionId == nil && adopted == nil)
        let (fresh, _) = fix(row(1, pid: 13146, age: 59))
        #expect(fresh.agentPid == 13146 && fresh.terminalSessionId != nil, "a new conversation's first hook")
    }

    @Test func aLocklessProcessKeepsItsHookPane() {
        // 12780 ran a turn in 5 while 12222 held its lock
        let (kept, adopted) = fix(row(5, pid: 12780, age: 600))
        #expect(kept.agentPid == 12780 && kept.terminalSessionId == "w0t0p0:PANE" && adopted == nil)
    }

    @Test func aRowWithNoUsablePidAdoptsTheHolder() {
        let (discovered, a) = fix(row(5, pid: nil, age: 600, pane: nil))
        #expect(discovered.agentPid == 12222 && a == 12222)
        let (dead, b) = fix(row(5, pid: 999, age: 600), trusted: false)
        #expect(dead.agentPid == 12222 && dead.terminalSessionId == nil && b == 12222)
        // moved on and past the grace, with a holder elsewhere: that holder
        let p = AgyPresence.resolve(held: [id(2), id(1)], lockPaths: [13146: [lock(2)], 40: [lock(1)]],
                                    presenceDirectory: dir)
        let moved = SessionPipeline.correctAgy(row(1, pid: 13146, age: 120), agy: p, now: now,
                                               pidTrusted: { _, _ in true })
        #expect(moved.row.agentPid == 40 && moved.adopted == 40)
    }

    @Test func theHoldersOwnRowIsUnchanged() {
        let r = row(2, pid: 13146, age: 600)
        let (same, adopted) = fix(r)
        #expect(same == r && adopted == nil)
    }

    @Test func otherProvidersAndAnUnlistedFolderAreUntouched() {
        let claude = SessionSnapshot(provider: .claude, sessionId: id(1), projectPath: "/tmp", state: .done,
                                     event: "Stop", updatedAt: now.addingTimeInterval(-600), agentPid: 13146)
        #expect(SessionPipeline.correctAgy(claude, agy: presence, now: now, pidTrusted: { _, _ in true }).row == claude)
        let r = row(1, pid: 13146, age: 600)
        #expect(SessionPipeline.correctAgy(r, agy: .unknown, now: now, pidTrusted: { _, _ in true }).row == r)
    }

    @Test func theRunReportsAdoptedHolders() {
        let out = SessionPipeline.run(
            snapshots: [], registry: [:],
            discovered: [row(5, pid: nil, age: 600, pane: nil)],
            acks: [:], frozenOrder: nil, popoverVisible: false,
            agy: presence, agyPidTrusted: { _, _ in true }, now: now)
        #expect(out.adoptedAgyPids == [SessionKey.make(.antigravity, id(5)): 12222])
        #expect(out.rows.first?.agentPid == 12222)
    }
}

struct AgyLivenessTests {
    let now = Date(timeIntervalSince1970: 10_000)
    let presence = AgyPresence.resolve(held: [id(2)], lockPaths: [13146: [lock(2)], 12780: []],
                                       presenceDirectory: dir)
    private func row(_ n: Int, pid: Int32, age: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(provider: .antigravity, sessionId: id(n), projectPath: "/tmp", state: .done,
                        event: "Stop", updatedAt: now.addingTimeInterval(-age), agentPid: pid)
    }
    private func removed(_ s: SessionSnapshot, live: Set<String> = []) -> Bool {
        !Liveness.keysToRemove([s], now: now, confirmedLive: live, agy: presence,
                               // every process alive since long before its snapshot
                               probe: .init(startTime: { _ in Date(timeIntervalSince1970: 0) })).isEmpty
    }

    @Test func aConversationItsProcessLeftIsRemovedAfterTheGrace() {
        #expect(removed(row(1, pid: 13146, age: 61)))
        #expect(!removed(row(1, pid: 13146, age: 59)))
    }

    @Test func aHeldOrLocklessConversationStays() {
        #expect(!removed(row(1, pid: 13146, age: 600), live: [SessionKey.make(.antigravity, id(1))]),
                "open in another process")
        #expect(!removed(row(3, pid: 12780, age: 600)), "a lockless process proves nothing either way")
        #expect(!removed(row(2, pid: 13146, age: 600)))
    }
}

struct AgyMayActTests {
    private func may(adopted: Bool, age: TimeInterval = 600, paths: [String]?,
                     held: Set<String> = [id(1), id(2)]) -> Bool {
        AgyPresence.mayAct(pid: 10, id: id(1).uppercased(), adopted: adopted, snapshotAge: age,
                           lockPaths: paths, presenceDirectory: dir, isHeld: held.contains)
    }

    @Test func anAdoptedHolderMustStillHoldTheLock() {
        #expect(may(adopted: true, paths: [lock(1)]), "id case doesn't matter")
        #expect(!may(adopted: true, paths: [lock(2)]))
        #expect(!may(adopted: true, paths: []))
        #expect(!may(adopted: true, paths: nil), "an exited holder isn't proof")
        #expect(!may(adopted: true, paths: [lock(1)], held: [id(2)]), "an open file whose lock isn't held")
    }

    @Test func aHookPidIsRefusedOnlyWhenItHoldsAnotherConversationPastTheGrace() {
        #expect(!may(adopted: false, paths: [lock(2)]))
        #expect(may(adopted: false, age: 30, paths: [lock(2)]), "a new conversation's first hook")
        #expect(may(adopted: false, paths: []), "a lockless process may still be in it")
        #expect(may(adopted: false, paths: nil), "can't tell")
        #expect(may(adopted: false, paths: [lock(1)]))
        #expect(may(adopted: false, paths: [lock(2)], held: [id(1)]), "an unheld lock isn't another conversation")
        #expect(may(adopted: false, paths: ["/elsewhere/presence/\(id(2)).lock"]), "outside the folder")
    }
}

struct RunningEvidenceReadingTests {
    @Test func eachProviderReadsOnlyItsOwnSource() {
        var read: [String] = []
        func reading(_ p: Provider) -> RunningEvidence {
            RunningEvidence.reading(for: p, claudeLive: { read.append("claude"); return ["c"] },
                                    agy: { read.append("agy"); return .unknown },
                                    codexDaemonThreads: { read.append("codex"); return ["t"] })
        }
        #expect(reading(.claude).claudeRegistryLive == ["c"])
        #expect(reading(.codex).daemonLive == [SessionKey.make(.codex, "t")])
        _ = reading(.antigravity)
        #expect(read == ["claude", "codex", "agy"])
    }
}

struct AgyPromptTests {
    let now = Date(timeIntervalSince1970: 10_000)
    private func row(event: String = "PreToolUse", tool: String? = "run_command", age: TimeInterval = 30,
                     state: SessionState = .working, provider: Provider = .antigravity,
                     pid: Int32? = 12222) -> SessionSnapshot {
        SessionSnapshot(provider: provider, sessionId: id(1), projectPath: "/tmp", state: state,
                        event: event, updatedAt: now.addingTimeInterval(-age), agentPid: pid,
                        pendingTool: tool)
    }
    /// Two looks, `gap` apart, both with `child`.
    private func twoLooks(_ r: SessionSnapshot, gap: TimeInterval = 6, child: Bool? = false) -> [String: Date] {
        var watch = AgyPromptWatch()
        _ = watch.observe([r], now: now, hasChild: { _ in child })
        return watch.observe([r], now: now.addingTimeInterval(gap), hasChild: { _ in child })
    }

    @Test func aStartedCommandWithNothingRunningOnTwoLooksIsAPrompt() {
        let r = row()
        var watch = AgyPromptWatch()
        #expect(watch.observe([r], now: now, hasChild: { _ in false }).isEmpty, "one look isn't enough")
        #expect(watch.observe([r], now: now.addingTimeInterval(6), hasChild: { _ in false }) == [r.key: r.updatedAt])
    }

    @Test func looksCloserThanTheGapOrInterruptedDontCount() {
        #expect(twoLooks(row(), gap: 2).isEmpty)
        var watch = AgyPromptWatch()
        let r = row()
        _ = watch.observe([r], now: now, hasChild: { _ in false })
        _ = watch.observe([r], now: now.addingTimeInterval(3), hasChild: { _ in true })
        #expect(watch.observe([r], now: now.addingTimeInterval(7), hasChild: { _ in false }).isEmpty,
                "a command ran in between: start over")
        // a new call (another PreToolUse) starts over too
        var other = AgyPromptWatch()
        _ = other.observe([row(age: 30)], now: now, hasChild: { _ in false })
        #expect(other.observe([row(age: 20)], now: now.addingTimeInterval(6), hasChild: { _ in false }).isEmpty)
    }

    @Test func aRunningOrJustStartedOrUnreadableCommandIsNot() {
        #expect(twoLooks(row(), child: true).isEmpty, "the command is running")
        #expect(twoLooks(row(age: 9)).isEmpty, "under the threshold at the first look: that look doesn't count")
        #expect(!twoLooks(row(age: 10)).isEmpty, "at the threshold on both looks")
        #expect(twoLooks(row(age: 3)).isEmpty, "a command just approved hasn't started its shell yet")
        #expect(twoLooks(row(), child: nil).isEmpty, "can't tell")
    }

    @Test func eachConditionIsNeeded() {
        #expect(twoLooks(row(event: "PostToolUse")).isEmpty, "the call finished, even if the tool lingered")
        #expect(twoLooks(row(tool: nil)).isEmpty, "another tool, or none recorded")
        #expect(twoLooks(row(state: .waiting)).isEmpty)
        #expect(twoLooks(row(provider: .claude)).isEmpty)
        #expect(twoLooks(row(pid: nil)).isEmpty)
    }

    @Test func thePipelineShowsItAsMayNeedYou() {
        let r = row()
        let out = SessionPipeline.run(snapshots: [r], registry: [:], inferredWaiting: twoLooks(r),
                                      acks: [:], frozenOrder: nil, popoverVisible: false, now: now)
        #expect(out.rows.first?.state == .waiting)
        #expect(out.waitingReasons[r.key] == SessionPipeline.inferredWaitingReason)
        #expect(out.alertCount == 1)
    }

    @Test func theCheckRunsOnThePidThatHoldsTheConversationNow() {
        // the snapshot's pid moved on to another conversation; the holder is 40
        let presence = AgyPresence.resolve(held: [id(1), id(2)],
                                           lockPaths: [12222: [lock(2)], 40: [lock(1)]], presenceDirectory: dir)
        let fixed = SessionPipeline.correctedAgyRow(row(age: 120), agy: presence, now: now)
        #expect(fixed.agentPid == 40)
    }
}

struct AgyChildProbeTests {
    @Test func aRunningChildIsSeenAndAGoneProcessIsUnknown() throws {
        let me = getpid()
        // a system binary, never deleted (see ProcessFixtures)
        let child = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        defer { child.terminate(); child.waitUntilExit() }
        #expect(ProcessTree.agyHasCommandChild(me) == true)
        #expect(ProcessTree.agyHasCommandChild(999_999) == nil, "no such process")
    }

    @Test func anUpdaterIsKnownByItsExactArgument() throws {
        let child = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        defer { child.terminate(); child.waitUntilExit() }
        #expect(!ProcessTree.hasArgument("--bg-updater", pid: child.processIdentifier))
        #expect(ProcessTree.hasArgument("5", pid: child.processIdentifier))
        #expect(!ProcessTree.hasArgument("/bin/sleep", pid: child.processIdentifier), "not the program name")
    }
}
