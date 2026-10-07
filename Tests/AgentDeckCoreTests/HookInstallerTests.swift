import Foundation
import Testing
@testable import AgentDeckCore

final class HookInstallerTests {
    let dir: URL
    let helperPath = "/Stable/Path/agentdeck-hook"
    let installer: HookInstaller

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HookInstaller(helperPath: helperPath)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func fixtureSettings() -> [String: Any] {
        [
            "permissions": ["allow": ["Bash(*)"], "ask": ["Bash(git push*)"]],
            "model": "claude-fable-5",
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "/usr/bin/say done"]]]
                ]
            ],
        ]
    }

    @Test func aConcurrentSaveIsDetectedInsteadOfOverwritten() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(fixtureSettings(), to: url)
        let basis = try Data(contentsOf: url)

        // someone (Claude, an editor) saves between our read and our write
        var theirs = fixtureSettings()
        theirs["model"] = "claude-opus-5-5"
        try write(theirs, to: url)

        #expect(throws: InstallerError.self) {
            try HookInstaller.backupAndWrite(["hooks": [:]], to: url, basis: basis)
        }
        // their save survived untouched
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        #expect((after as? [String: Any])?["model"] as? String == "claude-opus-5-5")
    }

    /// Note: this pins the *committed* file's mode and the absence of
    /// stranded staging files. The related fix — creating the temp 0600 so
    /// a copy of a private config is never briefly world-readable — is not
    /// directly observable from here, since the temp is gone by the time
    /// the call returns. It passes with or without that change.
    @Test func aPrivateConfigStaysPrivateAndLeavesNoCopies() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(fixtureSettings(), to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path
        )
        let basis = try Data(contentsOf: url)
        try HookInstaller.backupAndWrite(fixtureSettings(), to: url, basis: basis)

        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o077 == 0, "config must stay private")
        // and no copy of it is left lying around
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "staging files must not be stranded")
    }

    @Test func aFailedEditLeavesNoBackupAndNoTempFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(fixtureSettings(), to: url)
        // a basis mismatch aborts before writing anything
        #expect(throws: InstallerError.self) {
            try HookInstaller.backupAndWrite(["hooks": [:]], to: url, basis: Data("stale".utf8))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains(".agentdeck-") && $0.hasSuffix(".bak") },
                "a backup implies an edit that did not happen")
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    func write(_ obj: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    func read(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func installPreservesExistingSettingsAndHooks() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(fixtureSettings(), to: url)

        #expect(try installer.installClaude(settingsURL: url))
        let after = try read(url)

        #expect(after["model"] as? String == "claude-fable-5")
        let perms = after["permissions"] as? [String: Any]
        #expect((perms?["allow"] as? [String])?.first == "Bash(*)")

        let hooks = try #require(after["hooks"] as? [String: Any])
        let stopEntries = try #require(hooks["Stop"] as? [Any])
        #expect(stopEntries.count == 2)
        #expect(HookInstaller.contains("/usr/bin/say", in: stopEntries))
        #expect(HookInstaller.contains(helperPath, in: stopEntries))

        for event in HookInstaller.claudeEvents {
            let entries = try #require(hooks[event] as? [Any], "missing hook for \(event)")
            #expect(HookInstaller.contains(helperPath, in: entries))
        }
    }

    @Test func installIsIdempotent() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(fixtureSettings(), to: url)
        #expect(try installer.installClaude(settingsURL: url))
        #expect(try !installer.installClaude(settingsURL: url))

        let hooks = try #require(try read(url)["hooks"] as? [String: Any])
        for event in HookInstaller.claudeEvents {
            let entries = try #require(hooks[event] as? [Any])
            let ours = entries.filter { HookInstaller.contains(helperPath, in: $0) }
            #expect(ours.count == 1, "duplicate entries for \(event)")
        }
    }

    @Test func backupCreatedOnChange() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(fixtureSettings(), to: url)
        _ = try installer.installClaude(settingsURL: url)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".agentdeck-") && $0.hasSuffix(".bak") }
        #expect(backups.count == 1)

        let backup = try read(dir.appendingPathComponent(backups[0]))
        let hooks = try #require(backup["hooks"] as? [String: Any])
        #expect(!HookInstaller.contains(helperPath, in: hooks))
    }

    @Test func installIntoMissingFileCreatesIt() throws {
        let url = dir.appendingPathComponent("hooks.json")
        #expect(try installer.installCodex(hooksURL: url))
        let after = try read(url)
        let hooks = try #require(after["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookInstaller.codexEvents))
        #expect(installer.isInstalled(provider: .codex, in: url))
    }

    @Test func partialInstallIsUnhealthy() throws {
        let url = dir.appendingPathComponent("settings.json")
        // only one of the required events carries our canonical command
        try write([
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command",
                                "command": installer.command(for: .claude)]]]
                ]
            ]
        ], to: url)
        #expect(!installer.isInstalled(provider: .claude, in: url),
                "one surviving entry must not paint the integration green")
        // and install repairs it to fully healthy
        #expect(try installer.installClaude(settingsURL: url))
        #expect(installer.isInstalled(provider: .claude, in: url))
    }

    @Test func pathMentionOutsideHooksDoesNotCountAsInstalled() throws {
        let url = dir.appendingPathComponent("settings.json")
        try write(["permissions": ["allow": ["Bash(\(helperPath)*)"]]], to: url)
        #expect(!installer.isInstalled(provider: .claude, in: url))
    }

    @Test func sharedGroupKeepsForeignSubHooks() throws {
        let url = dir.appendingPathComponent("settings.json")
        // a user merged their own hook into the same group as ours
        try write([
            "hooks": [
                "Stop": [
                    ["hooks": [
                        ["type": "command", "command": "\(helperPath) claude"],  // stale ours
                        ["type": "command", "command": "/usr/bin/say done"],
                    ]]
                ]
            ]
        ], to: url)
        _ = try installer.installClaude(settingsURL: url)
        let hooks = try #require(try read(url)["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [Any])
        #expect(HookInstaller.contains("/usr/bin/say", in: stop),
                "foreign sub-hook sharing our group must survive reinstall")
        let ours = HookInstaller.commandStrings(in: stop)
            .filter { $0.contains(helperPath) }
        #expect(ours == [installer.command(for: .claude)])
    }

    @Test func refusesToClobberNonObjectJSON() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data("[1,2,3]".utf8).write(to: url)
        #expect(throws: InstallerError.self) {
            try self.installer.installClaude(settingsURL: url)
        }
        #expect(try Data(contentsOf: url) == Data("[1,2,3]".utf8))
    }

    @Test func isInstalledFalseForMissingOrForeignFile() throws {
        #expect(!installer.isInstalled(
            provider: .claude, in: dir.appendingPathComponent("nope.json")
        ))
        let url = dir.appendingPathComponent("other.json")
        try write(fixtureSettings(), to: url)
        #expect(!installer.isInstalled(provider: .claude, in: url))
    }
}
