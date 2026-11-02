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

    @Test func aMissKeepsThePreviousObservation() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("rollout-a.jsonl")
        try Data((tokenCount() + "\n").utf8).write(to: url)
        let reader = CodexUsage.Reader(directory: dir)
        #expect(reader.load() != nil)
        try Data((userMessage + "\n").utf8).write(to: url)
        #expect(reader.load()?.groups.first?.weekly?.usedPercent == 91)
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
