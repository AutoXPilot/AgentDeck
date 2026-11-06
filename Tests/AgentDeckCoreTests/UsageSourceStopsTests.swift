import Foundation
import Testing
@testable import AgentDeckCore

/// What the usage lines do when a source stops reporting: a tee removed,
/// blocked or overridden by policy, an account with no limits, a Codex
/// account whose rollouts carry no figures. The line goes rather than
/// showing figures that can't update or that may be another account's.

private func dir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdeck-stops-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func rateLimits(_ limits: String, at timestamp: String) -> String {
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":\#(limits)}}"#
}

private let codexFigures = #"{"limit_id":"codex","primary":{"used_percent":70.0,"window_minutes":300,"resets_at":1793592286},"secondary":{"used_percent":91.0,"window_minutes":10080,"resets_at":1793790185},"plan_type":"plus"}"#

private func rollout(_ dir: URL, _ name: String, _ lines: [String], modified: TimeInterval) throws {
    let url = dir.appendingPathComponent("rollout-\(name).jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                          ofItemAtPath: url.path)
}

struct CodexNotReportingTests {
    @Test func nullRateLimitsNewerThanTheFiguresHideThem() throws {
        let d = try dir()
        try rollout(d, "old", [rateLimits(codexFigures, at: "2026-10-30T10:00:00.000Z")], modified: 1_793_400_000)
        try rollout(d, "new", [rateLimits("null", at: "2026-11-01T10:00:00.000Z")], modified: 1_793_500_000)
        #expect(CodexUsage.Reader(directory: d).load() == nil)
    }

    @Test func anUnknownBucketNewerThanTheFiguresHidesThem() throws {
        let d = try dir()
        try rollout(d, "old", [rateLimits(codexFigures, at: "2026-10-30T10:00:00.000Z")], modified: 1_793_400_000)
        let other = #"{"limit_id":"org-plan","primary":{"used_percent":5.0,"window_minutes":300}}"#
        try rollout(d, "new", [rateLimits(other, at: "2026-11-01T10:00:00.000Z")], modified: 1_793_500_000)
        #expect(CodexUsage.Reader(directory: d).load() == nil)
    }

    @Test func anEmptySubscriptionReportHidesOlderFigures() throws {
        for empty in ["{}", #"{"limit_id":"codex","primary":null,"secondary":null}"#] {
            let d = try dir()
            try rollout(d, "old", [rateLimits(codexFigures, at: "2026-10-30T10:00:00.000Z")], modified: 1_793_400_000)
            try rollout(d, "new", [rateLimits(empty, at: "2026-11-01T10:00:00.000Z")], modified: 1_793_500_000)
            #expect(CodexUsage.Reader(directory: d).load() == nil, "\(empty)")
        }
    }

    @Test func anOlderNotReportingRecordDoesNotHideNewerFigures() throws {
        let d = try dir()
        try rollout(d, "old", [rateLimits("null", at: "2026-10-30T10:00:00.000Z")], modified: 1_793_400_000)
        try rollout(d, "new", [rateLimits(codexFigures, at: "2026-11-01T10:00:00.000Z")], modified: 1_793_500_000)
        #expect(CodexUsage.Reader(directory: d).load()?.groups.first?.weekly?.usedPercent == 91)
    }

    @Test func aPremiumRecordAfterTheFiguresStillSaysNothing() throws {
        let d = try dir()
        let premium = #"{"limit_id":"premium","primary":null,"secondary":null}"#
        try rollout(d, "a", [rateLimits(codexFigures, at: "2026-11-01T10:00:00.000Z"),
                             rateLimits(premium, at: "2026-11-01T10:00:01.000Z")], modified: 1_793_500_000)
        #expect(CodexUsage.Reader(directory: d).load()?.groups.first?.session?.usedPercent == 70)
    }

    @Test func codexHomeFollowsTheEnvironment() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        #expect(CodexHome.directory(environment: [:], home: home).path == "/Users/me/.codex")
        #expect(CodexHome.directory(environment: ["CODEX_HOME": "/opt/codex"], home: home).path == "/opt/codex")
        #expect(CodexHome.directory(environment: ["CODEX_HOME": "~/work-codex"], home: home).path
                == "/Users/me/work-codex")
        // relative isn't a usable location
        #expect(CodexHome.directory(environment: ["CODEX_HOME": "codex"], home: home).path == "/Users/me/.codex")
    }
}

struct UsageExpiryTests {
    let now = Date(timeIntervalSince1970: 1_793_600_000)

    private func usage(session: TimeInterval?, weekly: TimeInterval?, changed: TimeInterval = -3600,
                       provider: Provider = .codex) -> ProviderUsage {
        func window(_ offset: TimeInterval?) -> UsageWindow? {
            offset.map { UsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval($0)) }
        }
        return ProviderUsage(provider: provider,
                             groups: [UsageGroup(session: window(session), weekly: window(weekly))],
                             observedAt: now.addingTimeInterval(changed))
    }

    @Test func expiresOnceEveryWindowOnTheLineHasReset() {
        #expect(usage(session: -60, weekly: -60).isExpired(now: now))
        #expect(!usage(session: -60, weekly: 86400).isExpired(now: now))
        #expect(usage(session: -60, weekly: nil).isExpired(now: now))
    }

    @Test func expiresAfterAWeekWithoutMoving() {
        #expect(!usage(session: 3600, weekly: 86400, changed: -7 * 86400).isExpired(now: now))
        #expect(usage(session: 3600, weekly: 86400, changed: -9 * 86400).isExpired(now: now))
    }

    @Test func tooltipOnlyGroupsDoNotKeepALineAlive() {
        var u = usage(session: -60, weekly: -60)
        u.groups.append(UsageGroup(label: "model", weekly: UsageWindow(usedPercent: 1, resetsAt: now + 86400),
                                   inLine: false))
        #expect(u.isExpired(now: now))
    }

    @Test func aTeeLineShowsOnlyWhileTheTeeRunsAndReports() {
        let claude = usage(session: 3600, weekly: 86400, provider: .claude)
        #expect(UsageFormat.shows(claude, tee: .installed, activity: .reporting, now: now))
        #expect(!UsageFormat.shows(claude, tee: nil, activity: nil, now: now))
        #expect(!UsageFormat.shows(claude, tee: .notInstalled, activity: nil, now: now))
        #expect(!UsageFormat.shows(claude, tee: .overriddenByPolicy, activity: .reporting, now: now))
        #expect(!UsageFormat.shows(claude, tee: .installed, activity: .waiting, now: now))
        #expect(!UsageFormat.shows(claude, tee: .installed, activity: .noFigures, now: now))
        #expect(!UsageFormat.shows(claude, tee: .installed, activity: .notRunning, now: now))
        let expired = usage(session: -60, weekly: -60, provider: .claude)
        #expect(!UsageFormat.shows(expired, tee: .installed, activity: .reporting, now: now))
    }

    @Test func codexNeedsNoTeeButStillExpires() {
        #expect(UsageFormat.shows(usage(session: 3600, weekly: 86400), tee: nil, activity: nil, now: now))
        #expect(!UsageFormat.shows(usage(session: -60, weekly: -60), tee: nil, activity: nil, now: now))
    }

    @Test func removeAllDeletesOnlyThatProvidersRecords() throws {
        let store = UsageStore(directory: try dir())
        var a = usage(session: 3600, weekly: 86400, provider: .claude)
        a.account = "aaaa1111"
        try store.record(a)
        try store.record(usage(session: 3600, weekly: 86400, provider: .claude))
        try store.record(usage(session: 3600, weekly: 86400, provider: .antigravity))
        try store.removeAll(.claude)
        #expect(store.loadAll(.claude).isEmpty)
        #expect(store.load(.antigravity) != nil)
    }
}

struct TeeActivityTests {
    let helper = "/Users/me/Library/Application Support/AgentDeck/bin/agentdeck-hook"
    let original = #"{"type":"command","command":"echo mine"}"#
    let withFigures = #"{"cwd":"/x","rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1793598600}}}"#
    let withoutFigures = #"{"cwd":"/x"}"#

    private func setup() throws -> (StatusLineTee, URL, UsageStore) {
        let d = try dir()
        let settings = d.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":\#(original)}"#.utf8).write(to: settings)
        let tee = StatusLineTee(helperPath: helper, chainDirectory: d.appendingPathComponent("chain"))
        try tee.install(.claude, settingsURL: settings, policy: .none)
        return (tee, settings, UsageStore(directory: d.appendingPathComponent("usage")))
    }

    private func run(_ tee: StatusLineTee, _ url: URL, _ store: UsageStore, _ payload: String, at now: Date) {
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        _ = tee.run(provider: .claude, recordName: name, input: Data(payload.utf8), store: store,
                    claudeAccount: { "aaaa1111" }, now: now)
    }

    @Test func installedButNeverRunIsWaitingThenNotRunning() throws {
        let (tee, url, _) = try setup()
        #expect(tee.activity(for: .claude, settingsURL: url) == .waiting)
        let later = Date().addingTimeInterval(StatusLineTee.notRunningAfter + 60)
        #expect(tee.activity(for: .claude, settingsURL: url, now: later) == .notRunning)
    }

    @Test func aRunWithoutFiguresIsNoFiguresAndOneWithThemIsReporting() throws {
        let (tee, url, store) = try setup()
        run(tee, url, store, withoutFigures, at: Date())
        #expect(tee.activity(for: .claude, settingsURL: url) == .noFigures)
        run(tee, url, store, withFigures, at: Date())
        #expect(tee.activity(for: .claude, settingsURL: url) == .reporting)
        // a run without figures soon after doesn't undo it (a session
        // that hasn't heard from the server yet)
        run(tee, url, store, withoutFigures, at: Date().addingTimeInterval(120))
        #expect(tee.activity(for: .claude, settingsURL: url) == .reporting)
        // half an hour of runs without figures: the account stopped
        run(tee, url, store, withoutFigures, at: Date().addingTimeInterval(StatusLineTee.figuresLapseAfter + 180))
        #expect(tee.activity(for: .claude, settingsURL: url) == .noFigures)
    }

    @Test func aRunStillInFlightAtUninstallRecordsNothing() throws {
        let (tee, url, store) = try setup()
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        _ = tee.uninstallReport([.claude], store: store, settingsURL: { _ in url })
        // the tee started before the settings were restored and finishes now
        let result = tee.run(provider: .claude, recordName: name, input: Data(withFigures.utf8),
                             store: store, claudeAccount: { "aaaa1111" })
        #expect(String(decoding: result?.stdout ?? Data(), as: UTF8.self) == "mine\n")
        #expect(store.loadAll(.claude).isEmpty)
        #expect(tee.loadHeartbeat(recordName: name) == nil)
    }

    @Test func aRecentRunOutweighsAPolicyThatShouldHaveStoppedIt() throws {
        let (tee, url, store) = try setup()
        var blocked = ClaudePolicy()
        blocked.statusLineManaged = true
        #expect(tee.status(for: .claude, settingsURL: url, policy: blocked, applicable: true) == .overriddenByPolicy)
        run(tee, url, store, withFigures, at: Date())
        #expect(tee.status(for: .claude, settingsURL: url, policy: blocked, applicable: true) == .installed)
        let later = Date().addingTimeInterval(StatusLineTee.notRunningAfter + 60)
        #expect(tee.status(for: .claude, settingsURL: url, policy: blocked, applicable: true, now: later)
                == .overriddenByPolicy)
    }

    @Test func anInstallFromBeforeHeartbeatsWaitsForItsFirstRun() {
        #expect(StatusLineTee.activity(installedAt: nil, heartbeat: nil, now: Date()) == .waiting)
        let ran = StatusLineTee.Heartbeat(ranAt: Date(), figuresAt: Date())
        #expect(StatusLineTee.activity(installedAt: nil, heartbeat: ran, now: Date()) == .reporting)
    }

    @Test func aHeartbeatFromBeforeSetupDoesNotCount() {
        let installed = Date(timeIntervalSince1970: 1_793_600_000)
        let before = StatusLineTee.Heartbeat(ranAt: installed - 60, figuresAt: installed - 60)
        #expect(StatusLineTee.activity(installedAt: installed, heartbeat: before, now: installed + 30) == .waiting)
        let after = StatusLineTee.Heartbeat(ranAt: installed + 5, figuresAt: installed - 60)
        #expect(StatusLineTee.activity(installedAt: installed, heartbeat: after, now: installed + 30) == .noFigures)
    }

    @Test func runsWithinAMinuteWriteOnce() throws {
        let (tee, url, store) = try setup()
        // whole seconds: the heartbeat stores seconds since 1970 as JSON
        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        run(tee, url, store, withFigures, at: t0)
        run(tee, url, store, withFigures, at: t0.addingTimeInterval(10))
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        #expect(tee.loadHeartbeat(recordName: name)?.ranAt == t0)
        run(tee, url, store, withFigures, at: t0.addingTimeInterval(61))
        #expect(tee.loadHeartbeat(recordName: name)?.ranAt == t0.addingTimeInterval(61))
    }

    @Test func uninstallDeletesTheSavedFiguresAndTheHeartbeat() throws {
        let (tee, url, store) = try setup()
        run(tee, url, store, withFigures, at: Date())
        #expect(!store.loadAll(.claude).isEmpty)
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        let report = tee.uninstallReport([.claude], store: store, settingsURL: { _ in url })
        #expect(report.lines == ["Claude: original status line restored"])
        #expect(!report.failed)
        #expect(tee.loadHeartbeat(recordName: name) == nil)
        #expect(store.loadAll(.claude).isEmpty)
        #expect(tee.activity(for: .claude, settingsURL: url) == nil)
    }

    @Test func aManagedStatusLineBlocksTheTee() throws {
        let policy = ClaudePolicy.from([("managed-settings.json",
                                         ["statusLine": ["type": "command", "command": "corp-line"]])])
        #expect(policy.statusLineManaged)
        #expect(!policy.hooksBlocked)
        #expect(!ClaudePolicy.from([("managed-settings.json", ["statusLine": NSNull()])]).statusLineManaged)
        #expect(policy.statusLineBlocked)
        let d = try dir()
        let settings = d.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":\#(original)}"#.utf8).write(to: settings)
        let tee = StatusLineTee(helperPath: helper, chainDirectory: d.appendingPathComponent("chain"))
        #expect(throws: StatusLineTee.TeeError.blockedByPolicy) {
            try tee.install(.claude, settingsURL: settings, policy: policy)
        }
        #expect(tee.status(for: .claude, settingsURL: settings, policy: policy, applicable: true) == .blockedByPolicy)
        // agy isn't governed by Claude's policy
        #expect(try tee.install(.antigravity, settingsURL: settings, policy: policy))
    }

    @Test func noToolFolderMeansNotApplicable() throws {
        let d = try dir()
        let missing = d.appendingPathComponent("no-claude/settings.json")
        let tee = StatusLineTee(helperPath: helper, chainDirectory: d.appendingPathComponent("chain"))
        #expect(tee.status(for: .claude, settingsURL: missing, policy: .none) == .notApplicable)
        let present = d.appendingPathComponent("settings.json")
        #expect(tee.status(for: .claude, settingsURL: present, policy: .none) == .notInstalled)
    }

    @Test func theMenuSaysWhyAnInstalledTeeShowsNothing() {
        #expect(UsageFormat.teeNote(.claude, status: .installed, activity: .reporting) == nil)
        #expect(UsageFormat.teeNote(.claude, status: .installed, activity: .notRunning)?
                .contains("hasn't run") == true)
        #expect(UsageFormat.teeNote(.claude, status: .installed, activity: .noFigures)?
                .contains("no usage figures") == true)
        #expect(UsageFormat.teeNote(.claude, status: .overriddenByPolicy, activity: .reporting)?
                .contains("policy") == true)
        #expect(UsageFormat.teeNote(.antigravity, status: .notInstalled, activity: nil) == nil)
    }
}
