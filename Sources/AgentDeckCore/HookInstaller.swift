import Foundation

public enum InstallerError: Error, CustomStringConvertible {
    case notAJSONObject(String)
    /// Someone else wrote the file between reading and writing it.
    case changedWhileInstalling(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notAJSONObject(let path):
            return "\(path) exists but is not a JSON object; refusing to modify it"
        case .changedWhileInstalling(let path):
            return "\(path) changed while installing — nothing was written. "
                + "Close anything editing it and try again."
        case .writeFailed(let path):
            return "couldn't create \(path) — nothing was written"
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
        // Serialize AgentDeck's own installs. Two of them racing would each
        // read, modify and write the whole file, and the loser's hooks
        // would vanish.
        try Self.withInstallLock(for: fileURL) {
            try self.installLocked(provider: provider, fileURL: fileURL)
        }
    }

    private func installLocked(provider: Provider, fileURL: URL) throws -> Bool {
        // the exact bytes this edit is based on, so a change by anyone else
        // between here and the write is detected instead of overwritten
        let basis = try? Data(contentsOf: fileURL)
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
            try Self.backupAndWrite(root, to: fileURL, basis: basis)
        }
        return changed
    }

    /// flock on a sidecar beside the config. Held only for the
    /// read-modify-write, and never created inside the config file itself.
    static func withInstallLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent(".\(url.lastPathComponent).agentdeck-install.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }  // best-effort
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
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

    /// Replace `url`'s contents, but only if it still holds `basis`.
    ///
    /// Three things here are load-bearing, and each was previously wrong:
    /// the backup must *succeed* before anything is overwritten (it was
    /// `try?`, so a full disk silently skipped it while the README promised
    /// one); the staging file holds the user's entire config and so must be
    /// created private rather than at the mercy of umask; and the file must
    /// not have changed since we read it, or a concurrent save by Claude or
    /// an editor is destroyed. Atomic replacement prevents a *torn* file —
    /// it does nothing about a lost update.
    static func backupAndWrite(
        _ object: [String: Any], to url: URL, basis: Data? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let current = try? Data(contentsOf: url)
        if current != basis {
            throw InstallerError.changedWhileInstalling(url.path)
        }

        var originalPermissions: NSNumber?
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            originalPermissions =
                (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            // UTC + a uniqueness suffix so two saves in the same second (or
            // across a DST fall-back) can't produce the same name and clobber
            // each other. Never pre-delete a collision target.
            let stamp = "\(timestamp())-\(String(UInt32.random(in: 0..<0xFFFF), radix: 16))"
            let destination = URL(fileURLWithPath: url.path + ".agentdeck-\(stamp).bak")
            // not `try?`: no backup, no edit
            try fm.copyItem(at: url, to: destination)
            backup = destination
        }

        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            // create private, then write: a default-permission temp copy of
            // a 0600 config is readable by anyone who can traverse the dir
            guard fm.createFile(
                atPath: tmp.path, contents: nil,
                attributes: [.posixPermissions: originalPermissions ?? NSNumber(value: 0o600)]
            ) else {
                throw InstallerError.writeFailed(tmp.path)
            }
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // never strand a copy of the config, and don't leave a backup
            // implying an edit that didn't happen
            try? fm.removeItem(at: tmp)
            if let backup { try? fm.removeItem(at: backup) }
            throw error
        }
        // a previously locked-down config (0600) must not come back 0644
        if let originalPermissions {
            try? fm.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: url.path)
        }
        // only once the edit is committed, or a failed install prunes the
        // history that would have let the user recover
        pruneBackups(for: url)
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
        // UTC: local wall-clock names sort wrong across a DST change and can
        // repeat, which the lexicographic prune then mis-orders.
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
