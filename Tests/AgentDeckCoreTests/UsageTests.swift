import Foundation
import Testing
@testable import AgentDeckCore

/// Shapes recorded from codex-cli 0.165.0 rollouts (keys and figures only).
private func tokenCount(limitID: String? = "codex", primary: String? = nil, secondary: String? = nil,
                        timestamp: String = "2026-11-02T02:02:38.791Z", plan: String = "plus") -> String {
    let id = limitID.map { "\"\($0)\"" } ?? "null"
    let p = primary ?? #"{"used_percent":70.0,"window_minutes":300,"resets_at":1793592286}"#
    let s = secondary ?? #"{"used_percent":91.0,"window_minutes":10080,"resets_at":1793790185}"#
    return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":\#(id),"limit_name":null,"primary":\#(p),"secondary":\#(s),"credits":{"has_credits":false},"plan_type":"\#(plan)"}}}"#
}

private let userMessage =
    #"{"timestamp":"2026-11-02T02:02:30.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"SECRET-PROMPT mentions token_count and rate_limits"}]}}"#

struct CodexUsageTests {
    @Test func readsBothWindowsAndThePlan() throws {
        let usage = try #require(CodexUsage.parse(line: Data(tokenCount().utf8)))
        let group = try #require(usage.groups.first)
        #expect(group.session?.usedPercent == 70)
        #expect(group.session?.windowMinutes == 300)
        #expect(group.weekly?.usedPercent == 91)
        #expect(group.weekly?.resetsAt == Date(timeIntervalSince1970: 1793790185))
        #expect(usage.plan == "plus")
        #expect(usage.observedAt == SnapshotStore.isoFractional.date(from: "2026-11-02T02:02:38.791Z"))
    }

    @Test func aTrailingPremiumRecordDoesNotHideTheSubscription() throws {
        // recorded 2026-10-28: the last two records were codex 100/46, then
        // premium with null windows
        let premium = tokenCount(limitID: "premium", primary: "null", secondary: "null")
        let data = Data((tokenCount(primary: #"{"used_percent":100.0,"window_minutes":300,"resets_at":1}"#)
            + "\n" + premium + "\n").utf8)
        let usage = try #require(CodexUsage.latest(in: data, isWholeFile: true))
        #expect(usage.groups.first?.session?.usedPercent == 100)
    }

    @Test func aPremiumRecordWithFiguresIsStillNotTheSubscription() {
        #expect(CodexUsage.parse(line: Data(tokenCount(limitID: "premium").utf8)) == nil)
    }

    @Test func olderRecordsWithoutALimitIDAreAccepted() {
        #expect(CodexUsage.parse(line: Data(tokenCount(limitID: nil).utf8)) != nil)
        let noKey = tokenCount().replacingOccurrences(of: #""limit_id":"codex","#, with: "")
        #expect(CodexUsage.parse(line: Data(noKey.utf8)) != nil)
    }

    @Test func windowsAreMappedByDurationNotPosition() throws {
        let swapped = tokenCount(
            primary: #"{"used_percent":91.0,"window_minutes":10080,"resets_at":2}"#,
            secondary: #"{"used_percent":70.0,"window_minutes":300,"resets_at":1}"#)
        let group = try #require(CodexUsage.parse(line: Data(swapped.utf8))?.groups.first)
        #expect(group.session?.usedPercent == 70)
        #expect(group.weekly?.usedPercent == 91)
    }

    @Test func messageTextMentioningTokenCountIsRejected() {
        #expect(CodexUsage.parse(line: Data(userMessage.utf8)) == nil)
        // an event_msg of another type carrying a rate_limits-shaped object
        let other = tokenCount().replacingOccurrences(of: #""type":"token_count""#, with: #""type":"agent_message""#)
        #expect(CodexUsage.parse(line: Data(other.utf8)) == nil)
    }

    @Test func incompleteLinesInATailAreSkipped() {
        let full = tokenCount()
        // tail starting mid-record, and a record still being appended
        let midStart = String(full.dropFirst(10))
        let tail = Data((midStart + "\n" + userMessage + "\n" + String(full.prefix(60))).utf8)
        #expect(CodexUsage.latest(in: tail, isWholeFile: false) == nil)
        // the same bytes as a whole file still drop the unterminated last line
        let whole = Data((full + "\n" + String(full.prefix(60))).utf8)
        #expect(CodexUsage.latest(in: whole, isWholeFile: true) != nil)
    }

    @Test func theResultCarriesNoMessageText() throws {
        let data = Data((userMessage + "\n" + tokenCount() + "\n" + userMessage + "\n").utf8)
        let usage = try #require(CodexUsage.latest(in: data, isWholeFile: true))
        let encoded = String(decoding: try UsageStore.encoder.encode(usage), as: UTF8.self)
        #expect(!encoded.contains("SECRET-PROMPT"))
    }

    @Test func theTailGrowsPastAMultiMegabyteLine() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("rollout-2026-11-01T00-00-00-a.jsonl")
        let huge = #"{"type":"response_item","payload":{"text":""# + String(repeating: "x", count: 3_000_000) + #""}}"#
        try Data((tokenCount() + "\n" + huge + "\n").utf8).write(to: url)
        #expect(CodexUsage.latest(inFile: url)?.groups.first?.weekly?.usedPercent == 91)
    }

    @Test func aNewerRolloutWithoutUsageFallsBackToAnOlderOne() throws {
        let dir = try temporaryDirectory()
        let day1 = dir.appendingPathComponent("2026/10/22", isDirectory: true)
        let day2 = dir.appendingPathComponent("2026/11/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)
        let old = day1.appendingPathComponent("rollout-old.jsonl")
        let new = day2.appendingPathComponent("rollout-new.jsonl")
        try Data((tokenCount(timestamp: "2026-10-30T10:00:00.000Z") + "\n").utf8).write(to: old)
        try Data((userMessage + "\n").utf8).write(to: new)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_793_400_000)], ofItemAtPath: old.path)
        let reader = CodexUsage.Reader(directory: dir)
        #expect(reader.load()?.groups.first?.session?.usedPercent == 70)
    }

    @Test func aMissKeepsTheLastFigureUntilARecordSaysNotReporting() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("rollout-a.jsonl")
        try Data((tokenCount() + "\n").utf8).write(to: url)
        let reader = CodexUsage.Reader(directory: dir)
        #expect(reader.load() != nil)
        // newest files without a record (short exec threads): keep it
        try Data((userMessage + "\n").utf8).write(to: url)
        #expect(reader.load()?.groups.first?.weekly?.usedPercent == 91)
        // a newer record from an account that reports nothing: drop it
        let notReporting = #"{"timestamp":"2026-11-03T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#
        try Data((notReporting + "\n").utf8).write(to: dir.appendingPathComponent("rollout-b.jsonl"))
        #expect(reader.load() == nil)
    }
}

struct UsageStoreTests {
    private func usage(_ percent: Double, at seconds: TimeInterval) -> ProviderUsage {
        ProviderUsage(provider: .claude,
                      groups: [UsageGroup(session: UsageWindow(usedPercent: percent))],
                      observedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func roundTripsAndKeepsChangedAtWhileFiguresHold() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.record(usage(40, at: 100))
        try store.record(usage(40, at: 200))
        var loaded = try #require(store.load(.claude))
        #expect(loaded.observedAt == Date(timeIntervalSince1970: 200))
        #expect(loaded.changedAt == Date(timeIntervalSince1970: 100))
        try store.record(usage(41, at: 300))
        loaded = try #require(store.load(.claude))
        #expect(loaded.changedAt == Date(timeIntervalSince1970: 300))
    }

    @Test func theFileIsOwnerOnly() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.record(usage(1, at: 1))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url(for: .claude).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

struct UsageWindowTests {
    @Test func resetPassedAtAndAfterTheResetTime() {
        let w = UsageWindow(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 1000))
        #expect(!w.resetPassed(now: Date(timeIntervalSince1970: 999)))
        #expect(w.resetPassed(now: Date(timeIntervalSince1970: 1000)))
        #expect(!UsageWindow(usedPercent: 5).resetPassed(now: .distantFuture))
    }

    @Test func staleAfterSixHours() {
        let u = ProviderUsage(provider: .codex, groups: [], observedAt: Date(timeIntervalSince1970: 0))
        #expect(!u.isStale(now: Date(timeIntervalSince1970: 6 * 3600)))
        #expect(u.isStale(now: Date(timeIntervalSince1970: 6 * 3600 + 1)))
    }
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdeck-usage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct UsageFormatTests {
    let now = Date(timeIntervalSince1970: 1_793_600_000)
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func percentRoundsAndSaysResetOnceTheWindowRolledOver() {
        #expect(UsageFormat.percent(UsageWindow(usedPercent: 71.6), now: now) == "72%")
        #expect(UsageFormat.percent(UsageWindow(usedPercent: 100, resetsAt: now), now: now) == "reset")
        #expect(UsageFormat.percent(nil, now: now) == "–")
    }

    @Test func highFromNinetyButNotAfterAReset() {
        #expect(UsageFormat.isHigh(UsageWindow(usedPercent: 90), now: now))
        #expect(!UsageFormat.isHigh(UsageWindow(usedPercent: 89.9), now: now))
        #expect(!UsageFormat.isHigh(UsageWindow(usedPercent: 100, resetsAt: now), now: now))
        #expect(UsageFormat.isFull(UsageWindow(usedPercent: 100), now: now))
    }

    @Test func compactFormIsSessionSlashWeekly() {
        let g = UsageGroup(session: UsageWindow(usedPercent: 2), weekly: UsageWindow(usedPercent: 67))
        #expect(UsageFormat.compact(g, now: now) == "2/67")
    }

    @Test func tooltipOnlyGroupsStayOffTheLineButAppearInTheTooltip() {
        let usage = ProviderUsage(provider: .antigravity, groups: [
            UsageGroup(label: "Gemini", session: UsageWindow(usedPercent: 2)),
            UsageGroup(label: "Gemini 4 Argon", weekly: UsageWindow(usedPercent: 12), inLine: false),
            UsageGroup(label: "Empty"),
        ], observedAt: now)
        #expect(UsageFormat.lineGroups(usage).map(\.label) == ["Gemini"])
        let tip = UsageFormat.tooltip(usage, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(tip.contains("Gemini 4 Argon Weekly: 12% used"))
        #expect(!tip.contains("Empty"))
    }

    @Test func codexTooltipSaysTheAccountIsNotVerified() {
        let usage = ProviderUsage(provider: .codex, groups: [UsageGroup(
            session: UsageWindow(usedPercent: 72, resetsAt: now.addingTimeInterval(3600)))],
            plan: "plus", observedAt: now)
        let tip = UsageFormat.tooltip(usage, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(tip.contains("Account not verified"))
        #expect(tip.contains("Plan: Plus"))
        #expect(tip.contains("5-hour: 72% used, resets"))
    }

    @Test func tooltipSaysWhenCachedFiguresHaveNotMoved() {
        let usage = ProviderUsage(provider: .claude, groups: [UsageGroup(weekly: UsageWindow(usedPercent: 17))],
                                  observedAt: now, changedAt: now.addingTimeInterval(-3600))
        let tip = UsageFormat.tooltip(usage, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(tip.contains("Unchanged since"))
    }

    @Test func accessibilityLabelSpellsOutPercentUsed() {
        let usage = ProviderUsage(provider: .claude, groups: [UsageGroup(
            session: UsageWindow(usedPercent: 100), weekly: UsageWindow(usedPercent: 17))], observedAt: now)
        #expect(UsageFormat.accessibilityLabel(usage, now: now)
                == "Claude: 5-hour 100 percent used, weekly 17 percent used")
    }
}

struct UsageAccountTests {
    private func claude(_ five: Double, resets: TimeInterval = 1_793_598_600, account: String?,
                        at seconds: TimeInterval) -> ProviderUsage {
        ProviderUsage(provider: .claude,
                      groups: [UsageGroup(session: UsageWindow(usedPercent: five,
                                                               resetsAt: Date(timeIntervalSince1970: resets)))],
                      account: account, observedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func twoAccountsKeepSeparateRecords() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.recordUnlessEcho(claude(40, account: "aaaa1111", at: 1))
        try store.recordUnlessEcho(claude(90, resets: 1_793_590_000, account: "bbbb2222", at: 2))
        #expect(store.load(.claude, account: "aaaa1111")?.groups.first?.session?.usedPercent == 40)
        #expect(store.load(.claude, account: "bbbb2222")?.groups.first?.session?.usedPercent == 90)
        #expect(store.loadAll(.claude).count == 2)
    }

    @Test func anIdleSessionEchoingTheOldAccountIsNotFiledUnderTheNewOne() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.recordUnlessEcho(claude(40, account: "aaaa1111", at: 1))
        // after /login to bbbb2222, an idle session re-sends aaaa1111's figures
        #expect(try store.recordUnlessEcho(claude(40, account: "bbbb2222", at: 2)) == false)
        #expect(store.load(.claude, account: "bbbb2222") == nil)
        // a session that has heard from the new account is recorded
        #expect(try store.recordUnlessEcho(claude(5, resets: 1_793_610_000, account: "bbbb2222", at: 3)))
    }

    @Test func pickShowsTheSignedInAccountAndListsTheOthers() {
        let a = claude(40, account: "aaaa1111", at: 1)
        let b = claude(90, account: "bbbb2222", at: 5)
        let legacy = claude(70, account: nil, at: 9)
        let picked = UsageStore.pick([a, b, legacy], signedIn: "aaaa1111")
        #expect(picked.shown == a)
        #expect(picked.others == [b])
        // signed in to an account with no record yet: no line, not the other's
        #expect(UsageStore.pick([a], signedIn: "cccc3333").shown == nil)
        // account unknown: never a record filed under an account, which
        // could be another login's (a personal one on a work Mac)
        #expect(UsageStore.pick([a, b], signedIn: nil).shown == nil)
        #expect(UsageStore.pick([a, b], signedIn: nil).others.isEmpty)
        // only a record that couldn't name its account either
        #expect(UsageStore.pick([a, b, legacy], signedIn: nil).shown == legacy)
    }

    @Test func anAttributedRecordRetiresTheAccountlessFile() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.record(claude(70, account: nil, at: 1))
        try store.recordUnlessEcho(claude(40, account: "aaaa1111", at: 2))
        #expect(store.load(.claude) == nil)
        #expect(store.loadAll(.claude).map(\.account) == ["aaaa1111"])
    }

    @Test func accountNamesCannotEscapeTheDirectory() {
        let store = UsageStore(directory: URL(fileURLWithPath: "/x"))
        #expect(store.url(for: .claude, account: "../../etc").lastPathComponent == "claude.json")
        #expect(store.url(for: .claude, account: "aaaa1111").lastPathComponent == "claude-aaaa1111.json")
    }

    @Test func readsOnlyTheAccountIdPrefixFromTheRightFile() throws {
        let home = try temporaryDirectory()
        let json = #"{"oauthAccount":{"accountUuid":"17ca1970-aaaa-bbbb","emailAddress":"x@example.com"},"projects":{}}"#
        try Data(json.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let defaultDir = home.appendingPathComponent(".claude", isDirectory: true)
        #expect(ClaudeAccount.current(configDirectory: defaultDir, home: home) == "17ca1970")
        // a moved config folder holds its own .claude.json
        let moved = home.appendingPathComponent("alt", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        #expect(ClaudeAccount.current(configDirectory: moved, home: home) == nil)
        try Data(#"{"oauthAccount":{"accountUuid":"12116530-cccc"}}"#.utf8)
            .write(to: moved.appendingPathComponent(".claude.json"))
        #expect(ClaudeAccount.current(configDirectory: moved, home: home) == "12116530")
    }

    @Test func tooltipListsTheOtherAccount() {
        let now = Date(timeIntervalSince1970: 1_793_590_000)
        let shown = claude(40, account: "aaaa1111", at: 1_793_589_000)
        let other = claude(90, resets: 1_793_595_000, account: "bbbb2222", at: 1_793_588_000)
        let tip = UsageFormat.tooltip(shown, others: [other], now: now)
        #expect(tip.contains("Signed-in account aaaa1111."))
        #expect(tip.contains("Other account bbbb2222: 5-hour 90%"))
    }
}


struct UsageMergeTests {
    private func claude(_ five: Double, resets: TimeInterval, account: String? = "aaaa1111",
                        at seconds: TimeInterval) -> ProviderUsage {
        ProviderUsage(provider: .claude,
                      groups: [UsageGroup(session: UsageWindow(usedPercent: five,
                                                               resetsAt: Date(timeIntervalSince1970: resets)))],
                      account: account, observedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func anIdleSessionsOlderFigureDoesNotPullUsageBack() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.recordUnlessEcho(claude(77, resets: 5000, at: 100))
        try store.recordUnlessEcho(claude(76, resets: 5000, at: 200))
        #expect(store.load(.claude, account: "aaaa1111")?.groups.first?.session?.usedPercent == 77)
    }

    @Test func anOlderWindowNeverReplacesANewerOne() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        try store.recordUnlessEcho(claude(5, resets: 9000, at: 100))
        try store.recordUnlessEcho(claude(90, resets: 5000, at: 200))
        #expect(store.load(.claude, account: "aaaa1111")?.groups.first?.session?.usedPercent == 5)
        // a new window does replace it
        try store.recordUnlessEcho(claude(1, resets: 12000, at: 300))
        #expect(store.load(.claude, account: "aaaa1111")?.groups.first?.session?.usedPercent == 1)
    }

    @Test func anEchoOfAnyRecentFigureOfTheOtherAccountIsDropped() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        // account A seen at 40% then 45% in the same window, then a new window
        try store.recordUnlessEcho(claude(40, resets: 5000, at: 100))
        try store.recordUnlessEcho(claude(45, resets: 5000, at: 200))
        try store.recordUnlessEcho(claude(2, resets: 9000, at: 300))
        // after /login to B, idle sessions re-send A's cached 40% (old window)
        #expect(try store.recordUnlessEcho(claude(40, resets: 5000, account: "bbbb2222", at: 400)) == false)
        #expect(store.load(.claude, account: "bbbb2222") == nil)
    }

    @Test func unchangedFiguresAreNotRewrittenWithinAMinute() throws {
        let store = UsageStore(directory: try temporaryDirectory())
        #expect(try store.recordUnlessEcho(claude(10, resets: 5000, at: 100)))
        #expect(try store.recordUnlessEcho(claude(10, resets: 5000, at: 130)) == false)
        #expect(try store.recordUnlessEcho(claude(10, resets: 5000, at: 170)))
    }

    @Test func staleMeansTheFiguresHaventChanged() {
        let u = ProviderUsage(provider: .claude, groups: [], observedAt: Date(timeIntervalSince1970: 7 * 3600),
                              changedAt: Date(timeIntervalSince1970: 0))
        #expect(u.isStale(now: Date(timeIntervalSince1970: 7 * 3600)))
    }
}

struct DaemonRunningEvidenceTests {
    @Test func aDaemonHeldThreadCountsAsRunning() {
        let key = SessionKey.make(.codex, "01a19a81-2544-7700-a234-09859685e7db")
        let evidence = RunningEvidence(claudeRegistryLive: [], daemonLive: [key],
                                       pidTrusted: { _, _, _ in false }, processScan: { _, _ in [] })
        let row = SessionSnapshot(provider: .codex, sessionId: "01a19a81-2544-7700-a234-09859685e7db",
                                  projectPath: "/x", state: .working, event: "Stop", updatedAt: Date())
        #expect(evidence.runningKeys(rows: [row]).contains(key))
        let entry = WorkspaceEntry(provider: .codex, sessionId: row.sessionId, cwd: "/x", lastSeen: Date())
        #expect(evidence.isRunning(entry, snapshot: row))
        #expect(!RunningEvidence(claudeRegistryLive: [], pidTrusted: { _, _, _ in false },
                                 processScan: { _, _ in [] }).isRunning(entry, snapshot: row))
    }
}
