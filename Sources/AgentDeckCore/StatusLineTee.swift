import CryptoKit
import Foundation

/// Installs AgentDeck's status line tee for Claude or agy. Both allow only
/// one status line command, so the tee takes its place and runs the
/// user's original command behind it (`ChainRunner`), keeping a copy of the
/// original setting in a chain record.
///
/// This is the one place AgentDeck rewrites a settings entry it didn't
/// create. Hence:
/// - The record holds the entire original `statusLine` value, or that
///   there was none, and is written before the settings file. A crash in
///   between leaves the settings untouched, and status reads it as not
///   installed.
/// - Only `command` (and `type`) change. Every other field
///   (`padding`, `refreshInterval`, agy's `enabled`) stays as it was.
/// - Uninstall restores the original only while the setting still holds
///   the command AgentDeck wrote. A missing record is never read as
///   "there was nothing".
public struct StatusLineTee: Sendable {
    public let helperPath: String
    public let chainDirectory: URL

    public static var productionChainDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/statusline-chain", isDirectory: true)
    }

    public init(helperPath: String, chainDirectory: URL = StatusLineTee.productionChainDirectory) {
        self.helperPath = helperPath
        self.chainDirectory = chainDirectory
    }

    public static let providers: [Provider] = [.claude, .antigravity]

    /// Where each provider keeps its status line setting.
    public static func settingsURL(for provider: Provider,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        switch provider {
        case .claude: return HookInstaller.configURL(for: .claude)
        case .antigravity: return home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        case .codex: return nil
        }
    }

    public enum Status: Equatable, Sendable {
        case installed
        case notInstalled
        /// Managed Claude policy runs only the managed status line.
        case blockedByPolicy
        /// The setting runs AgentDeck's tee but the record that holds the
        /// original is gone, so it can't be undone automatically.
        case orphaned
        case notApplicable
    }

    public enum TeeError: Error, CustomStringConvertible, Equatable {
        case blockedByPolicy
        case notACommand(String)
        case orphaned(String)
        case missingRecord(String)

        public var description: String {
            switch self {
            case .blockedByPolicy:
                return "your organization's Claude Code policy runs only its own status line, "
                    + "so AgentDeck's would never run — nothing was written"
            case .notACommand(let path):
                return "the status line in \(path) isn't a shell command; it was left alone"
            case .orphaned(let path):
                return "\(path) already runs AgentDeck's status line but the saved original "
                    + "is missing; set your status line by hand, then try again"
            case .missingRecord(let path):
                return "AgentDeck has no saved original for \(path), so it can't restore it; "
                    + "nothing was changed"
            }
        }
    }

    public enum UninstallResult: Equatable, Sendable {
        case restored
        /// The user changed the status line since; it was left as it is.
        case leftUserChange
    }

    // MARK: - Records

    static let absentMarker = "originalAbsent"

    func recordName(provider: Provider, settingsURL: URL) -> String {
        let digest = SHA256.hash(data: Data(settingsURL.resolvingSymlinksInPath().path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue)-\(hex).json"
    }

    func recordURL(provider: Provider, settingsURL: URL) -> URL {
        chainDirectory.appendingPathComponent(recordName(provider: provider, settingsURL: settingsURL))
    }

    public func installedCommand(provider: Provider, settingsURL: URL) -> String {
        "\(WorkspaceRestore.shellQuote(helperPath)) statusline \(provider.rawValue) "
            + recordName(provider: provider, settingsURL: settingsURL)
    }

    /// The original command to run behind the tee, from a record name
    /// passed on the tee's argv. nil = nothing to chain.
    public func chainedCommand(recordName: String) -> String? {
        guard !recordName.contains("/"),
              let record = loadRecord(at: chainDirectory.appendingPathComponent(recordName)),
              let original = record["original"] as? [String: Any],
              let command = original["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return command
    }

    func loadRecord(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["installedCommand"] is String,
              object["original"] != nil || object[Self.absentMarker] as? Bool == true
        else { return nil }
        return object
    }

    func writeRecord(_ record: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: chainDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let temp = chainDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        // the saved command can hold anything the user typed: owner-only
        guard fm.createFile(atPath: temp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw InstallerError.writeFailed(temp.path)
        }
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
            throw InstallerError.writeFailed(url.path)
        }
    }

    // MARK: - Status

    private func command(of value: Any?) -> String? {
        (value as? [String: Any])?["command"] as? String
    }

    /// A tee command from any AgentDeck install (another helper path or
    /// settings file), which this record can't restore.
    private func looksLikeTee(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("agentdeck-hook") && command.contains(" statusline ")
    }

    public func status(for provider: Provider, settingsURL: URL? = nil,
                       policy: ClaudePolicy = .load(), applicable: Bool? = nil) -> Status {
        guard let settingsURL = settingsURL ?? Self.settingsURL(for: provider) else { return .notApplicable }
        if provider == .claude, policy.hooksBlocked { return .blockedByPolicy }
        if !(applicable ?? provider.spec.applicability.isApplicable()) { return .notApplicable }
        let current = (try? HookInstaller.readJSONObject(at: settingsURL))?["statusLine"]
        let ours = installedCommand(provider: provider, settingsURL: settingsURL)
        if command(of: current) == ours {
            return loadRecord(at: recordURL(provider: provider, settingsURL: settingsURL)) == nil
                ? .orphaned : .installed
        }
        return looksLikeTee(command(of: current)) ? .orphaned : .notInstalled
    }

    // MARK: - Install / uninstall

    /// Returns whether the settings file changed.
    @discardableResult
    public func install(_ provider: Provider, settingsURL: URL? = nil,
                        policy: @autoclosure () -> ClaudePolicy = .load()) throws -> Bool {
        guard let requested = settingsURL ?? Self.settingsURL(for: provider) else { return false }
        if provider == .claude, policy().hooksBlocked { throw TeeError.blockedByPolicy }
        let url = requested.resolvingSymlinksInPath()
        return try HookInstaller.withInstallLock(for: url) {
            let basis = try? Data(contentsOf: url)
            var root = try HookInstaller.readJSONObject(at: url)
            let current = root["statusLine"]
            let ours = installedCommand(provider: provider, settingsURL: url)
            let recordURL = recordURL(provider: provider, settingsURL: url)

            if command(of: current) == ours {
                guard loadRecord(at: recordURL) != nil else { throw TeeError.orphaned(url.path) }
                return false
            }
            if looksLikeTee(command(of: current)) { throw TeeError.orphaned(url.path) }
            var installed: [String: Any]
            if let current {
                guard let dict = current as? [String: Any] else { throw TeeError.notACommand(url.path) }
                // "" is agy's "built-in line"; anything else non-command is
                // a status line kind the tee can't run behind
                if let type = dict["type"] as? String, !type.isEmpty, type != "command" {
                    throw TeeError.notACommand(url.path)
                }
                if let cmd = dict["command"], !(cmd is String) { throw TeeError.notACommand(url.path) }
                installed = dict
            } else {
                installed = [:]
            }
            let hadCommand = !(command(of: current) ?? "").trimmingCharacters(in: .whitespaces).isEmpty

            var record: [String: Any] = [
                "version": 1,
                "provider": provider.rawValue,
                "settingsPath": url.path,
                "installedCommand": ours,
            ]
            if let current { record["original"] = current } else { record[Self.absentMarker] = true }
            try writeRecord(record, to: recordURL)

            installed["type"] = "command"
            installed["command"] = ours
            // with no command of the user's to chain the tee prints nothing;
            // agy can stack its built-in line above a custom one
            if provider == .antigravity, !hadCommand { installed["stack_with_default"] = true }
            root["statusLine"] = installed
            try HookInstaller.backupAndWrite(root, to: url, basis: basis)
            return true
        }
    }

    public func uninstall(_ provider: Provider, settingsURL: URL? = nil) throws -> UninstallResult {
        guard let requested = settingsURL ?? Self.settingsURL(for: provider) else { return .leftUserChange }
        let url = requested.resolvingSymlinksInPath()
        return try HookInstaller.withInstallLock(for: url) {
            let recordURL = recordURL(provider: provider, settingsURL: url)
            guard let record = loadRecord(at: recordURL) else { throw TeeError.missingRecord(url.path) }
            let basis = try? Data(contentsOf: url)
            var root = try HookInstaller.readJSONObject(at: url)
            guard command(of: root["statusLine"]) == record["installedCommand"] as? String else {
                try? FileManager.default.removeItem(at: recordURL)
                return .leftUserChange
            }
            if let original = record["original"] {
                root["statusLine"] = original
            } else {
                root.removeValue(forKey: "statusLine")
            }
            try HookInstaller.backupAndWrite(root, to: url, basis: basis)
            try? FileManager.default.removeItem(at: recordURL)
            return .restored
        }
    }
}
