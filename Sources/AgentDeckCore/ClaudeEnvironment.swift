import Foundation

/// What an organization's Claude Code policy says, as far as AgentDeck is
/// concerned. Read-only: AgentDeck never writes policy.
///
/// Admins deliver policy as `/Library/Application Support/ClaudeCode/
/// managed-settings.json` (plus `managed-settings.d/*.json`) or as an MDM
/// profile in the `com.anthropic.claudecode` domain. Claude Code uses the
/// highest-ranked source that has any policy and ignores the rest; this
/// reads them all and treats a restriction in any of them as in force,
/// which can only make AgentDeck more careful, never less.
public struct ClaudePolicy: Equatable, Sendable {
    /// `allowManagedHooksOnly`, or `disableAllHooks` at the managed level:
    /// hooks AgentDeck adds to the user's settings would never run.
    public var hooksBlocked = false
    /// `permissions.disableBypassPermissionsMode = "disable"`.
    public var bypassPermissionsDisabled = false
    /// `permissions.disableAutoMode = "disable"`.
    public var autoModeDisabled = false
    /// `env.CLAUDE_CONFIG_DIR` set by policy.
    public var configDirectory: String?
    /// Where policy was found, for diagnostics.
    public var sources: [String] = []

    public init() {}

    public static let none = ClaudePolicy()

    public static var managedSettingsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_MANAGED_SETTINGS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true)
    }

    public static var managedPreferencesDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_MANAGED_PREFS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true)
    }

    /// The policy in force on this machine now.
    public static func load(
        settingsDirectory: URL = managedSettingsDirectory,
        preferencesDirectory: URL = managedPreferencesDirectory,
        user: String = NSUserName()
    ) -> ClaudePolicy {
        var found: [(String, [String: Any])] = []
        // MDM first: it outranks the file, so its CLAUDE_CONFIG_DIR wins
        for plist in [
            preferencesDirectory.appendingPathComponent(user)
                .appendingPathComponent("com.anthropic.claudecode.plist"),
            preferencesDirectory.appendingPathComponent("com.anthropic.claudecode.plist"),
        ] {
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                   as? [String: Any] {
                found.append((plist.path, dict))
            }
        }
        let main = settingsDirectory.appendingPathComponent("managed-settings.json")
        let dropIns = ((try? FileManager.default.contentsOfDirectory(
            at: settingsDirectory.appendingPathComponent("managed-settings.d"),
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in [main] + dropIns {
            if let data = try? Data(contentsOf: file),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                found.append((file.path, dict))
            }
        }
        return from(found)
    }

    static func from(_ sources: [(String, [String: Any])]) -> ClaudePolicy {
        var policy = ClaudePolicy()
        for (name, dict) in sources {
            policy.sources.append(name)
            if truthy(dict["allowManagedHooksOnly"]) || truthy(dict["disableAllHooks"]) {
                policy.hooksBlocked = true
            }
            let permissions = dict["permissions"] as? [String: Any] ?? [:]
            if (permissions["disableBypassPermissionsMode"] as? String) == "disable" {
                policy.bypassPermissionsDisabled = true
            }
            if (permissions["disableAutoMode"] as? String) == "disable" {
                policy.autoModeDisabled = true
            }
            if policy.configDirectory == nil,
               let env = dict["env"] as? [String: Any],
               let dir = env["CLAUDE_CONFIG_DIR"] as? String, !dir.isEmpty {
                policy.configDirectory = dir
            }
        }
        return policy
    }

    /// JSON gives Bool or NSNumber; a plist can also give a string.
    static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return false
        }
    }

    /// Permission modes this policy refuses, so restore never builds a
    /// command Claude Code would reject.
    public var refusedPermissionModes: Set<String> {
        var refused = Set<String>()
        if bypassPermissionsDisabled { refused.insert("bypassPermissions") }
        if autoModeDisabled { refused.insert("auto") }
        return refused
    }
}

/// Where Claude Code keeps its files: `~/.claude` unless `CLAUDE_CONFIG_DIR`
/// says otherwise. Session files, transcripts and settings all move with
/// it, and AgentDeck used to assume the default for all three.
///
/// A menu-bar app is started by launchd, not a shell, so it doesn't see a
/// `CLAUDE_CONFIG_DIR` exported in a shell profile. It also checks the two
/// settings files Claude Code reads it from: policy, then the user's own.
public enum ClaudeConfig {
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        policy: ClaudePolicy,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let defaultDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        if let dir = environment["CLAUDE_CONFIG_DIR"], let url = absolute(dir, home: home) {
            return url
        }
        if let dir = policy.configDirectory, let url = absolute(dir, home: home) {
            return url
        }
        let userSettings = defaultDirectory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: userSettings),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = dict["env"] as? [String: Any],
           let dir = env["CLAUDE_CONFIG_DIR"] as? String, let url = absolute(dir, home: home) {
            return url
        }
        return defaultDirectory
    }

    static func absolute(_ path: String, home: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true)
        }
        guard trimmed.hasPrefix("/") else { return nil }  // relative paths aren't valid here
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Resolved once per process: policy and settings files are read here,
    /// and the answer only changes when an admin or the user moves Claude's
    /// files, which a relaunch picks up.
    public static let current: URL = directory(policy: .load())
}
