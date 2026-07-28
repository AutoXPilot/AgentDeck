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
/// ~/.codex/hooks.json. Idempotent; preserves every existing key and every
/// hook that isn't ours (including foreign sub-hooks sharing a group with
/// ours); takes a timestamped backup before any write and prunes old backups.
///
/// Known trade-off: the file is rewritten via JSONSerialization, which does
/// not preserve key order, formatting, or exact float representation
/// (e.g. 1.1 → 1.1000000000000001). Backups retain the original bytes.
public struct HookInstaller: Sendable {
    public let helperPath: String

    public init(helperPath: String) {
        self.helperPath = helperPath
    }

    public static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]
    /// Verified against codex-cli 0.145.0: SessionStart/UserPromptSubmit/
    /// Stop/SessionEnd all fire (SessionEnd's timeout is clamped to 3s).
    /// PermissionRequest is accepted without warning; firing not yet
    /// observed (exec mode never prompts) — registered so interactive
    /// approvals surface as "waiting" if/when codex emits it.
    public static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd",
    ]

    public static var defaultClaudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
    public static var defaultCodexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    public static func events(for provider: Provider) -> [String] {
        provider == .claude ? claudeEvents : codexEvents
    }

    public func command(for provider: Provider) -> String {
        // path contains "Application Support" — unquoted, sh splits it
        "\"\(helperPath)\" \(provider.rawValue)"
    }

    @discardableResult
    public func installClaude(settingsURL: URL = defaultClaudeSettingsURL) throws -> Bool {
        try install(provider: .claude, fileURL: settingsURL)
    }

    @discardableResult
    public func installCodex(hooksURL: URL = defaultCodexHooksURL) throws -> Bool {
        try install(provider: .codex, fileURL: hooksURL)
    }

    /// Strict health check: every required event must carry our exact
    /// canonical command. A single surviving entry (or a mention of the path
    /// elsewhere in the file) must not paint the integration green.
    public func isInstalled(provider: Provider, in fileURL: URL) -> Bool {
        guard let root = try? Self.readJSONObject(at: fileURL),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let canonical = command(for: provider)
        return Self.events(for: provider).allSatisfy { event in
            Self.commandStrings(in: hooks[event] ?? []).contains(canonical)
        }
    }

    // MARK: - Internals

    private func install(provider: Provider, fileURL: URL) throws -> Bool {
        var root = try Self.readJSONObject(at: fileURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let canonical = command(for: provider)
        var changed = false

        for event in Self.events(for: provider) {
            let original = hooks[event] as? [Any] ?? []
            var entries: [Any] = []
            for entry in original {
                guard var group = entry as? [String: Any],
                      let subs = group["hooks"] as? [Any] else {
                    entries.append(entry)  // unrecognized shape: never touch
                    continue
                }
                // remove only OUR sub-hooks; keep foreign ones in the group
                let kept = subs.filter { sub in
                    let cmd = (sub as? [String: Any])?["command"] as? String
                    return !(cmd?.contains(helperPath) ?? false)
                }
                if kept.isEmpty && kept.count != subs.count {
                    continue  // group contained only our hooks — drop it
                }
                group["hooks"] = kept
                entries.append(group)
            }
            entries.append([
                "hooks": [["type": "command", "command": canonical, "timeout": 10]]
            ])
            if !Self.jsonEqual(original, entries) {
                hooks[event] = entries
                changed = true
            }
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

    /// Every "command" string value anywhere under `value`.
    static func commandStrings(in value: Any) -> [String] {
        switch value {
        case let arr as [Any]:
            return arr.flatMap { commandStrings(in: $0) }
        case let dict as [String: Any]:
            var out: [String] = []
            if let cmd = dict["command"] as? String { out.append(cmd) }
            out += dict.filter { $0.key != "command" }.values
                .flatMap { commandStrings(in: $0) }
            return out
        default:
            return []
        }
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

    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        return da != nil && da == db
    }

    static func backupAndWrite(_ object: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var originalPermissions: NSNumber?
        if fm.fileExists(atPath: url.path) {
            originalPermissions =
                (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            let backup = URL(fileURLWithPath: url.path + ".agentdeck-\(timestamp()).bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            pruneBackups(for: url)
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        // a previously locked-down config (0600) must not come back 0644
        if let originalPermissions {
            try? fm.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: url.path)
        }
    }

    static func pruneBackups(for url: URL, keep: Int = 5) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".agentdeck-"
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }.sorted()
        for old in backups.dropLast(keep) {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
    }

    static func timestamp(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
