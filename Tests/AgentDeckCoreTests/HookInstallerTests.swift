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
        #expect(installer.isInstalled(in: url))
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
        #expect(!installer.isInstalled(in: dir.appendingPathComponent("nope.json")))
        let url = dir.appendingPathComponent("other.json")
        try write(fixtureSettings(), to: url)
        #expect(!installer.isInstalled(in: url))
    }
}
