import Foundation

public enum InstallerError: Error, CustomStringConvertible {
    case notAJSONObject(String)

    public var description: String {
        switch self {
        case .notAJSONObject(let path):
            return "\(path) exists but is not a JSON object; refusing to modify it"
        }
    }
}

/// Adds AgentDeck hook entries to ~/.claude/settings.json and
/// ~/.codex/hooks.json. Idempotent; preserves every existing key and hook;
/// takes a timestamped backup before any write.
public struct HookInstaller: Sendable {
    public let helperPath: String

    public init(helperPath: String) {
        self.helperPath = helperPath
    }

    public static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]
    // Codex's hook engine ships a subset of events (no SessionEnd/StopFailure);
    // registering only what exists avoids config-validation noise.
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "Stop"]

    public static var defaultClaudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
    public static var defaultCodexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    public func command(for provider: Provider) -> String {
        "\(helperPath) \(provider.rawValue)"
    }

    @discardableResult
    public func installClaude(settingsURL: URL = defaultClaudeSettingsURL) throws -> Bool {
        try install(
            events: Self.claudeEvents, command: command(for: .claude), fileURL: settingsURL
        )
    }

    @discardableResult
    public func installCodex(hooksURL: URL = defaultCodexHooksURL) throws -> Bool {
        try install(
            events: Self.codexEvents, command: command(for: .codex), fileURL: hooksURL
        )
    }

    public func isInstalled(in fileURL: URL) -> Bool {
        // Parse rather than string-search: JSON writers escape "/" so a raw
        // text scan misses our own entries.
        guard let root = try? Self.readJSONObject(at: fileURL) else { return false }
        return Self.contains(helperPath, in: root)
    }

    // MARK: - Internals

    private func install(events: [String], command: String, fileURL: URL) throws -> Bool {
        var root = try Self.readJSONObject(at: fileURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            var entries = hooks[event] as? [Any] ?? []
            guard !Self.contains(helperPath, in: entries) else { continue }
            entries.append([
                "hooks": [["type": "command", "command": command, "timeout": 10]]
            ])
            hooks[event] = entries
            changed = true
        }
        if changed {
            root["hooks"] = hooks
            try Self.backupAndWrite(root, to: fileURL)
        }
        return changed
    }

    static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.notAJSONObject(url.path)
        }
        return obj
    }

    /// True if any string anywhere in `value` mentions `needle`.
    static func contains(_ needle: String, in value: Any) -> Bool {
        switch value {
        case let s as String:
            return s.contains(needle)
        case let arr as [Any]:
            return arr.contains { contains(needle, in: $0) }
        case let dict as [String: Any]:
            return dict.values.contains { contains(needle, in: $0) }
        default:
            return false
        }
    }

    static func backupAndWrite(_ object: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: url.path) {
            let stamp = Self.timestamp()
            let backup = URL(fileURLWithPath: url.path + ".agentdeck-\(stamp).bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    }

    static func timestamp(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
