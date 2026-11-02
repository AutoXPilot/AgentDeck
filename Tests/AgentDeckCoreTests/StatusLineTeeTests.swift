import Foundation
import Testing
@testable import AgentDeckCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdeck-tee-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let now = Date(timeIntervalSince1970: 1_793_600_000)

/// Claude Code 2.1.316 status line payload, keys as recorded; values synthetic.
private let claudePayload = #"""
{"session_id":"s-1","transcript_path":"/Users/me/.claude/projects/x/s-1.jsonl","cwd":"/Users/me/Code/webapp",
 "model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"workspace":{"current_dir":"/Users/me/Code/webapp"},
 "rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1793598600},
                "seven_day":{"used_percentage":17.4,"resets_at":1794100000}}}
"""#

/// agy 1.4.9 status line payload: key paths from the probe, values synthetic.
private let agyPayload = #"""
{"cwd":"/Users/me/Code/webapp","session_id":"c-1","conversation_id":"c-1","conversation_title":"SECRET-TITLE",
 "transcript_path":"/x","email":"someone@example.com","plan_tier":"SECRET-TIER","product":"agy",
 "quota":{"3p-5h":{"remaining_fraction":1,"reset_time":"2026-11-02T07:57:01Z","reset_in_seconds":100},
          "3p-weekly":{"remaining_fraction":0.3280332,"reset_time":"2026-11-02T16:34:41Z","reset_in_seconds":100},
          "gemini-5h":{"remaining_fraction":0.9734819,"reset_time":"2026-11-02T07:53:25Z","reset_in_seconds":100},
          "gemini-weekly":{"remaining_fraction":0.9836835,"reset_time":"2026-11-02T15:15:00Z","reset_in_seconds":100},
          "gemini-argon-wtu-weekly":{"remaining_fraction":0,"reset_time":"2026-11-02T16:44:12Z","reset_in_seconds":100}}}
"""#

struct StatusLineCaptureTests {
    @Test func claudeKeepsOnlyTheTwoWindows() throws {
        let usage = try #require(StatusLineCapture.extract(provider: .claude, data: Data(claudePayload.utf8), now: now))
        let group = try #require(usage.groups.first)
        #expect(group.session?.usedPercent == 100)
        #expect(group.session?.resetsAt == Date(timeIntervalSince1970: 1793598600))
        #expect(group.weekly?.usedPercent == 17.4)
        let stored = String(decoding: try UsageStore.encoder.encode(usage), as: UTF8.self)
        for leaked in ["webapp", "s-1", "transcript", "Opus"] { #expect(!stored.contains(leaked)) }
    }

    @Test func claudeWithoutRateLimitsRecordsNothing() {
        let apiKey = #"{"session_id":"s","model":{"id":"x"}}"#
        #expect(StatusLineCapture.extract(provider: .claude, data: Data(apiKey.utf8), now: now) == nil)
        let empty = #"{"rate_limits":{}}"#
        #expect(StatusLineCapture.extract(provider: .claude, data: Data(empty.utf8), now: now) == nil)
    }

    @Test func agyGroupsBucketsByIdAndConvertsRemainingToUsed() throws {
        let usage = try #require(StatusLineCapture.extract(provider: .antigravity, data: Data(agyPayload.utf8), now: now))
        #expect(usage.groups.map(\.label) == ["Gemini", "Claude/GPT", "gemini-argon-wtu"])
        #expect(usage.groups.map(\.inLine) == [true, true, false])
        let thirdParty = usage.groups[1]
        // an integer 1 is a fraction, not a boolean
        #expect(thirdParty.session?.usedPercent == 0)
        #expect(abs((thirdParty.weekly?.usedPercent ?? 0) - 67.19668) < 0.001)
        #expect(thirdParty.weekly?.resetsAt == SnapshotStore.isoPlain.date(from: "2026-11-02T16:34:41Z"))
        #expect(usage.groups[2].weekly?.usedPercent == 100)
    }

    @Test func agyKeepsNoTitleEmailOrPath() throws {
        let usage = try #require(StatusLineCapture.extract(provider: .antigravity, data: Data(agyPayload.utf8), now: now))
        let stored = String(decoding: try UsageStore.encoder.encode(usage), as: UTF8.self)
        for leaked in ["SECRET-TITLE", "example.com", "webapp", "SECRET-TIER"] { #expect(!stored.contains(leaked)) }
    }

    @Test func agyFallsBackToSecondsUntilReset() throws {
        let payload = #"{"quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_in_seconds":60}}}"#
        let usage = try #require(StatusLineCapture.extract(provider: .antigravity, data: Data(payload.utf8), now: now))
        #expect(usage.groups.first?.session?.resetsAt == now.addingTimeInterval(60))
    }

    @Test func agyBucketWithoutAFractionIsSkipped() {
        let payload = #"{"quota":{"gemini-5h":{"reset_time":"2026-11-02T07:53:25Z"}}}"#
        #expect(StatusLineCapture.extract(provider: .antigravity, data: Data(payload.utf8), now: now) == nil)
    }

    @Test func oversizedInputIsNotParsed() {
        let big = claudePayload + String(repeating: " ", count: StatusLineCapture.maxInput)
        #expect(StatusLineCapture.extract(provider: .claude, data: Data(big.utf8), now: now) == nil)
    }
}

struct ChainRunnerTests {
    @Test func passesStdinThroughAndReturnsStdoutAndStatus() {
        let input = Data("{\"a\":1}\nsecond line".utf8)
        let r = ChainRunner.run(command: "cat; exit 3", input: input)
        #expect(r.stdout == input)
        #expect(r.status == 3)
        #expect(!r.timedOut)
    }

    @Test func stderrNeverReachesTheStatusLine() {
        let r = ChainRunner.run(command: "echo shown; echo hidden >&2", input: Data())
        #expect(String(decoding: r.stdout, as: UTF8.self) == "shown\n")
    }

    @Test func aCommandThatNeverReadsStdinDoesNotBlock() {
        let big = Data(repeating: 65, count: 4 * 1024 * 1024)
        let start = Date()
        let r = ChainRunner.run(command: "echo ok", input: big, timeout: 5)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "ok\n")
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func aTimeoutKillsTheWholeProcessGroup() throws {
        let marker = try tempDir().appendingPathComponent("survived")
        // the grandchild would touch the marker after the timeout
        let r = ChainRunner.run(command: "(sleep 1.5; touch '\(marker.path)') & sleep 10",
                                input: Data(), timeout: 0.3)
        #expect(r.timedOut)
        Thread.sleep(forTimeInterval: 2)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func runsInTheCallersDirectoryAndEnvironment() {
        setenv("AGENTDECK_CHAIN_TEST", "inherited", 1)
        let r = ChainRunner.run(command: "pwd; printf %s \"$AGENTDECK_CHAIN_TEST\"", input: Data())
        #expect(String(decoding: r.stdout, as: UTF8.self)
                == FileManager.default.currentDirectoryPath + "\ninherited")
    }

    @Test func theCommandGetsDefaultSignalHandlingBack() {
        // the helper ignores SIGPIPE; a status line script relying on it
        // (`producer | head -1`) must not inherit that
        signal(SIGPIPE, SIG_IGN)
        let r = ChainRunner.run(
            command: #"perl -e 'print defined $SIG{PIPE} ? $SIG{PIPE} : "DEFAULT"'"#, input: Data())
        #expect(String(decoding: r.stdout, as: UTF8.self) == "DEFAULT")
    }
}

struct StatusLineTeeInstallTests {
    let helper = "/Users/me/Library/Application Support/AgentDeck/bin/agentdeck-hook"

    private func setup(_ json: String?) throws -> (StatusLineTee, URL) {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("settings.json")
        if let json { try Data(json.utf8).write(to: settings) }
        return (StatusLineTee(helperPath: helper, chainDirectory: dir.appendingPathComponent("chain")), settings)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try HookInstaller.readJSONObject(at: url)
    }

    private let original = #"{"type":"command","command":"python3 ~/.claude/statusline-usage.py","refreshInterval":60,"padding":1,"hideVimModeIndicator":true}"#

    @Test func installReplacesOnlyTheCommandAndKeepsEveryOtherField() throws {
        let (tee, url) = try setup(#"{"model":"opus","hooks":{"Stop":[]},"statusLine":\#(original)}"#)
        #expect(try tee.install(.claude, settingsURL: url, policy: .none))
        let root = try read(url)
        let line = try #require(root["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == tee.installedCommand(provider: .claude, settingsURL: url))
        #expect(line["refreshInterval"] as? Int == 60)
        #expect(line["padding"] as? Int == 1)
        #expect(line["hideVimModeIndicator"] as? Bool == true)
        #expect(line["stack_with_default"] == nil)
        #expect(Set(line.keys) == ["type", "command", "refreshInterval", "padding", "hideVimModeIndicator"])
        #expect(root["model"] as? String == "opus")
        #expect(HookInstaller.jsonEqual(root["hooks"] as Any, ["Stop": []]))
        #expect(tee.status(for: .claude, settingsURL: url, policy: .none, applicable: true) == .installed)
    }

    @Test func theTeeRunsTheSavedOriginalCommand() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        #expect(tee.chainedCommand(recordName: name) == "python3 ~/.claude/statusline-usage.py")
        // a record outside the chain directory is never read, even when present
        let outside = tee.chainDirectory.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.copyItem(at: tee.chainDirectory.appendingPathComponent(name), to: outside)
        #expect(tee.chainedCommand(recordName: "../\(name)") == nil)
    }

    @Test func installIsIdempotent() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        let once = try Data(contentsOf: url)
        #expect(try tee.install(.claude, settingsURL: url, policy: .none) == false)
        #expect(try Data(contentsOf: url) == once)
    }

    @Test func uninstallRestoresTheOriginalExactly() throws {
        let (tee, url) = try setup(#"{"a":1,"statusLine":\#(original)}"#)
        let before = try read(url)
        try tee.install(.claude, settingsURL: url, policy: .none)
        #expect(try tee.uninstall(.claude, settingsURL: url) == .restored)
        #expect(HookInstaller.jsonEqual(try read(url), before))
        #expect(tee.status(for: .claude, settingsURL: url, policy: .none, applicable: true) == .notInstalled)
    }

    @Test func uninstallRemovesAStatusLineThatWasAbsent() throws {
        let (tee, url) = try setup(#"{"a":1}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        #expect(try tee.uninstall(.claude, settingsURL: url) == .restored)
        #expect(HookInstaller.jsonEqual(try read(url), ["a": 1]))
    }

    @Test func agyGetsTheBuiltInLineStackedOnlyWhenThereWasNoCommand() throws {
        let (tee, url) = try setup(#"{"statusLine":{"type":"","command":"","enabled":true}}"#)
        try tee.install(.antigravity, settingsURL: url, policy: .none)
        let line = try #require(try read(url)["statusLine"] as? [String: Any])
        #expect(line["stack_with_default"] as? Bool == true)
        #expect(line["enabled"] as? Bool == true)
        #expect(try tee.uninstall(.antigravity, settingsURL: url) == .restored)
        #expect(HookInstaller.jsonEqual(try read(url),
                                        ["statusLine": ["type": "", "command": "", "enabled": true]]))

        let (tee2, url2) = try setup(#"{"statusLine":{"type":"command","command":"my-line"}}"#)
        try tee2.install(.antigravity, settingsURL: url2, policy: .none)
        #expect((try read(url2)["statusLine"] as? [String: Any])?["stack_with_default"] == nil)
    }

    @Test func aUserEditAfterInstallIsLeftAlone() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        let edited = #"{"statusLine":{"type":"command","command":"my-new-line"}}"#
        try Data(edited.utf8).write(to: url)
        #expect(try tee.uninstall(.claude, settingsURL: url) == .leftUserChange)
        #expect(try Data(contentsOf: url) == Data(edited.utf8))
    }

    @Test func aMissingRecordRefusesUninstallAndReportsOrphaned() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        try FileManager.default.removeItem(at: tee.chainDirectory)
        let before = try Data(contentsOf: url)
        #expect(throws: StatusLineTee.TeeError.self) { try tee.uninstall(.claude, settingsURL: url) }
        #expect(try Data(contentsOf: url) == before)
        #expect(tee.status(for: .claude, settingsURL: url, policy: .none, applicable: true) == .orphaned)
        #expect(throws: StatusLineTee.TeeError.self) { try tee.install(.claude, settingsURL: url, policy: .none) }
    }

    @Test func anotherInstallsTeeIsOrphanedNotChained() throws {
        let other = #"{"statusLine":{"type":"command","command":"'/old/agentdeck-hook' statusline claude claude-0000.json"}}"#
        let (tee, url) = try setup(other)
        #expect(throws: StatusLineTee.TeeError.self) { try tee.install(.claude, settingsURL: url, policy: .none) }
        #expect(tee.status(for: .claude, settingsURL: url, policy: .none, applicable: true) == .orphaned)
    }

    @Test func aNonCommandStatusLineIsUntouched() throws {
        let (tee, url) = try setup(#"{"statusLine":{"type":"static","text":"hi"}}"#)
        let before = try Data(contentsOf: url)
        #expect(throws: StatusLineTee.TeeError.self) { try tee.install(.claude, settingsURL: url, policy: .none) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func managedPolicyBlocksClaudeButNotAgy() throws {
        var blocked = ClaudePolicy()
        blocked.hooksBlocked = true
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        let before = try Data(contentsOf: url)
        #expect(throws: StatusLineTee.TeeError.blockedByPolicy) {
            try tee.install(.claude, settingsURL: url, policy: blocked)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tee.status(for: .claude, settingsURL: url, policy: blocked, applicable: true) == .blockedByPolicy)
        #expect(try tee.install(.antigravity, settingsURL: url, policy: blocked))
    }

    @Test func twoSettingsFilesGetTwoRecords() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        let second = url.deletingLastPathComponent().appendingPathComponent("other.json")
        try Data(#"{"statusLine":{"type":"command","command":"second"}}"#.utf8).write(to: second)
        try tee.install(.claude, settingsURL: url, policy: .none)
        try tee.install(.claude, settingsURL: second, policy: .none)
        #expect(tee.recordName(provider: .claude, settingsURL: url) != tee.recordName(provider: .claude, settingsURL: second))
        #expect(try tee.uninstall(.claude, settingsURL: second) == .restored)
        #expect((try read(second)["statusLine"] as? [String: Any])?["command"] as? String == "second")
        #expect(tee.status(for: .claude, settingsURL: url, policy: .none, applicable: true) == .installed)
    }

    @Test func theRecordIsOwnerOnly() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        let record = tee.recordURL(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        let perms = try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }
}


struct StatusLineTeeReviewTests {
    let helper = "/Users/me/Library/Application Support/AgentDeck/bin/agentdeck-hook"
    let original = #"{"type":"command","command":"echo mine","refreshInterval":60,"padding":1}"#

    private func setup(_ json: String) throws -> (StatusLineTee, URL) {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: settings)
        return (StatusLineTee(helperPath: helper, chainDirectory: dir.appendingPathComponent("chain")), settings)
    }

    @Test func uninstallKeepsEditsMadeToOtherFieldsWhileInstalled() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        var root = try HookInstaller.readJSONObject(at: url)
        var line = root["statusLine"] as! [String: Any]
        line["padding"] = 4                 // the user's edit
        line.removeValue(forKey: "refreshInterval")
        root["statusLine"] = line
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        #expect(try tee.uninstall(.claude, settingsURL: url) == .restored)
        let restored = try HookInstaller.readJSONObject(at: url)["statusLine"] as! [String: Any]
        #expect(restored["command"] as? String == "echo mine")
        #expect(restored["padding"] as? Int == 4)
        #expect(restored["refreshInterval"] == nil)
    }

    @Test func aRefreshAfterUninstallStillRunsTheUsersCommand() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        try tee.uninstall(.claude, settingsURL: url)
        #expect(tee.chainedCommand(recordName: name) == "echo mine")
        // and the retired record is cleaned up after the grace period
        tee.pruneRetired(now: Date().addingTimeInterval(StatusLineTee.retiredGrace + 60))
        #expect(tee.chainedCommand(recordName: name) == nil)
    }

    @Test func anInstalledTeeStaysRemovableUnderALaterPolicy() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        var blocked = ClaudePolicy()
        blocked.hooksBlocked = true
        #expect(tee.status(for: .claude, settingsURL: url, policy: blocked, applicable: true) == .installed)
    }

    @Test func aTeeRunRecordsUnderTheAccountAndPrintsTheUsersLine() throws {
        let (tee, url) = try setup(#"{"statusLine":\#(original)}"#)
        try tee.install(.claude, settingsURL: url, policy: .none)
        let name = tee.recordName(provider: .claude, settingsURL: url.resolvingSymlinksInPath())
        let store = UsageStore(directory: try tempDir())
        let payload = #"{"cwd":"/x","rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1793598600}}}"#
        let result = tee.run(provider: .claude, recordName: name, input: Data(payload.utf8),
                             store: store, claudeAccount: { "aaaa1111" })
        #expect(String(decoding: result?.stdout ?? Data(), as: UTF8.self) == "mine\n")
        #expect(store.load(.claude, account: "aaaa1111")?.groups.first?.session?.usedPercent == 30)
    }
}
