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
            == "'/Users/x/Library/Application Support/AgentDeck/bin/agentdeck-hook' claude")
    }

    @Test func aHostilePathIsOneLiteralWordToARealShell() throws {
        // what sh actually receives, not what the quoting should produce
        for path in ["/tmp/a b/$(touch /tmp/agentdeck-pwned)/hook", "/tmp/`id`/hook",
                     "/tmp/it's/hook", "/tmp/back\\slash/\"q\"/hook"] {
            let command = HookInstaller(helperPath: path).command(for: .claude)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // replace the program with printf to see the argv sh builds
            p.arguments = ["-c", "set -- \(command); printf '%s\\n' \"$1\" \"$2\""]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(lines.prefix(2) == [path, "claude"], "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/agentdeck-pwned"))
    }

    @Test func anInstallFromBeforeTheQuotingChangeStaysHealthyAndIsRewritten() throws {
        let url = dir.appendingPathComponent("settings.json")
        let legacy = "\"\(helperPath)\" claude"
        var hooks: [String: Any] = [:]
        for event in HookInstaller.events(for: .claude) {
            hooks[event] = [["hooks": [["type": "command", "command": legacy, "timeout": 10]]]]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: url)
        #expect(installer.isInstalled(provider: .claude, in: url),
                "the same command for a plain path; no forced reinstall")
        #expect(try installer.install(.claude, fileURL: url))
        // read back as commands, not by searching the JSON text — the
        // serializer escapes "/" so a text search can never match a path
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let written = HookInstaller.commandStrings(in: (root["hooks"] as! [String: Any])["Stop"] ?? [])
        #expect(written == [installer.command(for: .claude)], "legacy form replaced, not duplicated")
        #expect(installer.isInstalled(provider: .claude, in: url))
        #expect(try !installer.install(.claude, fileURL: url), "and then it is a no-op")
    }

    @Test func installWritesQuotedCommand() throws {
        let url = dir.appendingPathComponent("settings.json")
        #expect(try installer.install(.claude, fileURL: url))
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let entry = ((hooks["Stop"] as! [Any])[0] as! [String: Any])["hooks"] as! [[String: Any]]
        let command = entry[0]["command"] as! String
        #expect(command.hasPrefix("'"), "command must be quoted for sh")
        #expect(command == installer.command(for: .claude))
    }

    @Test func aPathWithAnApostropheIsReinstalledInPlace() throws {
        let path = "/Users/o'brien/Library/Application Support/AgentDeck/bin/agentdeck-hook"
        let quirky = HookInstaller(helperPath: path)
        let url = dir.appendingPathComponent("settings.json")
        #expect(try quirky.install(.claude, fileURL: url))
        #expect(try !quirky.install(.claude, fileURL: url), "second install is a no-op")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let stop = HookInstaller.commandStrings(in: (root["hooks"] as! [String: Any])["Stop"] ?? [])
        #expect(stop == [quirky.command(for: .claude)], "one hook, not one per install")
    }

    @Test func aSymlinkedConfigStaysASymlink() throws {
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try Data("{}".utf8).write(to: real)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(try installer.install(.claude, fileURL: link))
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(installer.isInstalled(provider: .claude, in: real), "the target got the hooks")
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

        #expect(try installer.install(.claude, fileURL: url), "repair counts as a change")
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [Any]
        let ours = stop.filter { HookInstaller.contains(helperPath, in: $0) }
        #expect(ours.count == 1, "stale entry replaced, not duplicated")
        #expect(HookInstaller.contains(installer.command(for: .claude), in: ours))
        #expect(HookInstaller.contains("/usr/bin/say", in: stop), "unrelated hook preserved")

        // and running again is a no-op
        #expect(try !installer.install(.claude, fileURL: url))
    }
}
