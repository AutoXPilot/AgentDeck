import Foundation
import Testing
@testable import AgentDeckCore

struct ClaudePolicyTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    @Test func noPolicyMeansNoRestrictions() throws {
        let p = ClaudePolicy.load(settingsDirectory: try tempDir(), preferencesDirectory: try tempDir())
        #expect(p == .none)
    }

    @Test func aManagedHooksOnlyPolicyBlocksAgentDecksHooks() throws {
        // the shape seen on a real managed Mac (keys trimmed)
        let dir = try tempDir()
        try write("""
            {"allowManagedHooksOnly": true,
             "hooks": {"UserPromptSubmit": []},
             "permissions": {"defaultMode": "auto", "disableBypassPermissionsMode": "disable"},
             "env": {"CLAUDE_CODE_USE_BEDROCK": 1}}
            """, to: dir.appendingPathComponent("managed-settings.json"))
        let p = ClaudePolicy.load(settingsDirectory: dir, preferencesDirectory: try tempDir())
        #expect(p.hooksBlocked)
        #expect(p.bypassPermissionsDisabled)
        #expect(!p.autoModeDisabled)
        #expect(p.refusedPermissionModes == ["bypassPermissions"])
        #expect(p.configDirectory == nil)
    }

    @Test func dropInsAndManagedDisableAllHooksCountToo() throws {
        let dir = try tempDir()
        try write(#"{"model": "opus"}"#, to: dir.appendingPathComponent("managed-settings.json"))
        try write(#"{"disableAllHooks": true, "permissions": {"disableAutoMode": "disable"}}"#,
                  to: dir.appendingPathComponent("managed-settings.d/50-hooks.json"))
        let p = ClaudePolicy.load(settingsDirectory: dir, preferencesDirectory: try tempDir())
        #expect(p.hooksBlocked)
        #expect(p.refusedPermissionModes == ["auto"])
        #expect(p.sources.count == 2)
    }

    @Test func anMDMProfileIsReadAndOutranksTheFileForTheConfigDir() throws {
        let files = try tempDir(), prefs = try tempDir()
        try write(#"{"env": {"CLAUDE_CONFIG_DIR": "/from/file"}}"#,
                  to: files.appendingPathComponent("managed-settings.json"))
        let plist: [String: Any] = ["allowManagedHooksOnly": "true",
                                    "env": ["CLAUDE_CONFIG_DIR": "/from/mdm"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: prefs.appendingPathComponent("someone"), withIntermediateDirectories: true)
        try data.write(to: prefs.appendingPathComponent("someone/com.anthropic.claudecode.plist"))
        let p = ClaudePolicy.load(settingsDirectory: files, preferencesDirectory: prefs, user: "someone")
        #expect(p.hooksBlocked, "a plist string 'true' counts")
        #expect(p.configDirectory == "/from/mdm")
    }

    @Test func anUnreadablePolicyFileIsIgnoredNotFatal() throws {
        let dir = try tempDir()
        try write("{not json", to: dir.appendingPathComponent("managed-settings.json"))
        #expect(ClaudePolicy.load(settingsDirectory: dir, preferencesDirectory: try tempDir()) == .none)
    }
}

struct ClaudeConfigTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func theDefaultIsDotClaude() {
        #expect(ClaudeConfig.directory(environment: [:], policy: .none, home: home).path
                == "/Users/someone/.claude")
    }

    @Test func theEnvironmentWinsThenPolicy() {
        var p = ClaudePolicy()
        p.configDirectory = "/policy/claude"
        #expect(ClaudeConfig.directory(environment: ["CLAUDE_CONFIG_DIR": "/env/claude"],
                                       policy: p, home: home).path == "/env/claude")
        #expect(ClaudeConfig.directory(environment: [:], policy: p, home: home).path == "/policy/claude")
    }

    @Test func aTildePathExpandsAndARelativeOneIsIgnored() {
        var p = ClaudePolicy()
        p.configDirectory = "~/work-claude"
        #expect(ClaudeConfig.directory(environment: [:], policy: p, home: home).path
                == "/Users/someone/work-claude")
        p.configDirectory = "relative/dir"
        #expect(ClaudeConfig.directory(environment: [:], policy: p, home: home).path
                == "/Users/someone/.claude", "settings files require an absolute path")
    }

    @Test func theUserSettingsEnvBlockIsRead() throws {
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let settings = fakeHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"env": {"CLAUDE_CONFIG_DIR": "/elsewhere"}}"#.utf8).write(to: settings)
        #expect(ClaudeConfig.directory(environment: [:], policy: .none, home: fakeHome).path
                == "/elsewhere")
    }
}

struct HookStatusTests {
    @Test func policyBlockWinsOverWhateverIsInSettings() {
        var blocked = ClaudePolicy()
        blocked.hooksBlocked = true
        #expect(HookStatus.claude(installed: true, policy: blocked) == .blockedByPolicy,
                "hooks left in settings.json still won't run")
        #expect(HookStatus.claude(installed: false, policy: .none) == .missing)
        #expect(HookStatus.claude(installed: true, policy: .none) == .installed)
    }

    @Test func noCodexMeansNothingToInstall() {
        #expect(HookStatus.codex(installed: false, codexPresent: false) == .notApplicable)
        #expect(HookStatus.codex(installed: false, codexPresent: true) == .missing)
        #expect(HookStatus.codex(installed: true, codexPresent: false) == .installed)
    }

    @Test func theInstallerLeavesSettingsUntouchedWhenPolicyBlocksHooks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"model": "opus"}"#.utf8)
        try original.write(to: settings)
        var blocked = ClaudePolicy()
        blocked.hooksBlocked = true
        #expect(throws: InstallerError.self) {
            try HookInstaller(helperPath: "/x/agentdeck-hook")
                .installClaude(settingsURL: settings, policy: blocked)
        }
        #expect(try Data(contentsOf: settings) == original, "not a byte changed")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings == ["settings.json"], "no backup, no temp file: \(siblings)")
    }
}

struct OlderClaudeRegistryTests {
    // shapes taken from real session files: 2.1.206 and 2.1.221 on the
    // development Mac, and the key list a managed Mac's 2.1.219 reported
    @Test func olderBuildsParseWithEverythingDiscoveryNeeds() throws {
        let v206 = #"{"cwd":"/Users/a/Code","entrypoint":"cli","kind":"interactive","name":"x","nameSource":"derived","peerProtocol":1,"pid":101,"procStart":"Mon","sessionId":"s206","startedAt":1790000000000,"status":"idle","statusUpdatedAt":1790000100000,"updatedAt":1790000100000,"version":"2.1.206"}"#
        let v219 = #"{"cwd":"/Users/a/Code","entrypoint":"cli","kind":"interactive","name":"y","peerProtocol":1,"pid":102,"procStart":"Mon","sessionId":"s219","startedAt":1790000000000,"status":"waiting","statusUpdatedAt":1790000200000,"updatedAt":1790000200000,"version":"2.1.219"}"#
        for (json, id) in [(v206, "s206"), (v219, "s219")] {
            let e = try #require(ClaudeSessionRegistry.parse(Data(json.utf8)))
            #expect(e.sessionId == id)
            #expect(e.cwd == "/Users/a/Code")
            #expect(e.startedAt != nil && e.statusUpdatedAt != nil)
        }
        let e219 = try #require(ClaudeSessionRegistry.parse(Data(v219.utf8)))
        #expect(e219.nameSource == nil)
        #expect(!e219.isUserNamed || e219.nameSource == nil)
        // a name with no recorded source is never stored as a user's
        let row = SessionSnapshot(provider: .claude, sessionId: "s219", projectPath: "/p",
                                  state: .waiting, event: "RegistryDiscovery")
        let captured = WorkspaceCapture.entry(for: row, registry: e219, transcriptSessionKind: nil,
                                              codexName: nil, terminal: .unknown, now: Date())
        #expect(captured?.displayName == nil)
    }

    @Test func aBuildWithoutStatusUpdatedAtFallsBackToTheFileTime() throws {
        // in case the managed build's field really is named differently
        let json = #"{"pid":103,"sessionId":"s","status":"busy","statusUpdateAt":1790000300000,"cwd":"/p"}"#
        let mtime = Date(timeIntervalSince1970: 1_790_000_400)
        let e = try #require(ClaudeSessionRegistry.parse(Data(json.utf8), fileModifiedAt: mtime))
        #expect(e.statusUpdatedAt == nil)
        #expect(e.observedAt == mtime)
    }
}
