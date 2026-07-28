import Foundation
import Testing
@testable import AgentDeckCore

/// Regression tests for the space-in-path bug: the helper lives under
/// "Application Support", so unquoted hook commands silently never ran.
final class CommandQuotingTests {
    let dir: URL
    let helperPath = "/Users/x/Library/Application Support/AgentDeck/bin/agentdeck-hook"
    let installer: HookInstaller

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-quoting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HookInstaller(helperPath: helperPath)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func commandIsQuoted() {
        #expect(installer.command(for: .claude)
            == "\"/Users/x/Library/Application Support/AgentDeck/bin/agentdeck-hook\" claude")
    }

    @Test func installWritesQuotedCommand() throws {
        let url = dir.appendingPathComponent("settings.json")
        #expect(try installer.installClaude(settingsURL: url))
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let entry = ((hooks["Stop"] as! [Any])[0] as! [String: Any])["hooks"] as! [[String: Any]]
        let command = entry[0]["command"] as! String
        #expect(command.hasPrefix("\""), "command must be quoted for sh")
        #expect(command == installer.command(for: .claude))
    }

    @Test func installRepairsStaleUnquotedEntries() throws {
        let url = dir.appendingPathComponent("settings.json")
        // simulate the broken v0 install: unquoted command
        let broken: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "\(helperPath) claude"]]],
                    ["hooks": [["type": "command", "command": "/usr/bin/say done"]]],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: broken).write(to: url)

        #expect(try installer.installClaude(settingsURL: url), "repair counts as a change")
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [Any]
        let ours = stop.filter { HookInstaller.contains(helperPath, in: $0) }
        #expect(ours.count == 1, "stale entry replaced, not duplicated")
        #expect(HookInstaller.contains(installer.command(for: .claude), in: ours))
        #expect(HookInstaller.contains("/usr/bin/say", in: stop), "unrelated hook preserved")

        // and running again is a no-op
        #expect(try !installer.installClaude(settingsURL: url))
    }
}
