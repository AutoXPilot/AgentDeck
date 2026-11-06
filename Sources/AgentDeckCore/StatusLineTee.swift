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
        /// Installed, but Claude policy (arrived since) means the user's
        /// status line no longer runs. Still removable.
        case overriddenByPolicy
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
                return "your organization's Claude Code policy sets the status line or allows only "
                    + "its own hooks, so AgentDeck's would never run — nothing was written"
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
    /// passed on the tee's argv. nil = nothing to chain. A retired record
    /// still counts: a refresh that started before uninstall must still
    /// show the user's own line.
    public func chainedCommand(recordName: String) -> String? {
        guard !recordName.contains("/"),
              let record = loadRecord(at: chainDirectory.appendingPathComponent(recordName),
                                      includingRetired: true),
              let original = record["original"] as? [String: Any],
              let command = original["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return command
    }

    func loadRecord(at url: URL, includingRetired: Bool = false) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["installedCommand"] is String,
              object["original"] != nil || object[Self.absentMarker] as? Bool == true
        else { return nil }
        if !includingRetired, object[Self.retiredKey] != nil { return nil }
        return object
    }

    static let retiredKey = "retiredAt"
    static let retiredGrace: TimeInterval = 3600

    /// Uninstall marks the record retired instead of deleting it, and
    /// records retired over an hour ago are removed on the next install or
    /// uninstall.
    func retire(_ record: [String: Any], at url: URL, now: Date = Date()) {
        var record = record
        record[Self.retiredKey] = now.timeIntervalSince1970
        try? writeRecord(record, to: url)
    }

    func pruneRetired(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: chainDirectory.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let url = chainDirectory.appendingPathComponent(name)
            guard let record = loadRecord(at: url, includingRetired: true),
                  let retired = record[Self.retiredKey] as? Double,
                  now.timeIntervalSince1970 - retired > Self.retiredGrace
            else { continue }
            try? fm.removeItem(at: url)
        }
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
                       policy: ClaudePolicy = .load(), applicable: Bool? = nil,
                       now: Date = Date()) -> Status {
        guard let settingsURL = settingsURL ?? Self.settingsURL(for: provider) else { return .notApplicable }
        let current = (try? HookInstaller.readJSONObject(at: settingsURL))?["statusLine"]
        let ours = installedCommand(provider: provider, settingsURL: settingsURL)
        // checked before policy: a tee installed before a policy arrived
        // must still be removable from the menu
        if command(of: current) == ours {
            guard loadRecord(at: recordURL(provider: provider, settingsURL: settingsURL)) != nil
            else { return .orphaned }
            guard provider == .claude, policy.statusLineBlocked else { return .installed }
            // the policy reading is partly assumption (a managed statusLine
            // overriding the user's isn't observed); a tee that ran lately
            // proves Claude still runs it
            let name = recordName(provider: provider, settingsURL: settingsURL.resolvingSymlinksInPath())
            if let ran = loadHeartbeat(recordName: name)?.ranAt,
               now.timeIntervalSince(ran) < Self.notRunningAfter {
                return .installed
            }
            return .overriddenByPolicy
        }
        if looksLikeTee(command(of: current)) { return .orphaned }
        if provider == .claude, policy.statusLineBlocked { return .blockedByPolicy }
        if !(applicable ?? Self.isApplicable(settingsURL: settingsURL)) { return .notApplicable }
        return .notInstalled
    }

    /// The tool is set up here: the folder that holds its settings exists
    /// (`~/.claude` or the `CLAUDE_CONFIG_DIR` one, `~/.gemini/
    /// antigravity-cli`). Installing otherwise would create a settings file
    /// for a tool that isn't there.
    static func isApplicable(settingsURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: settingsURL.deletingLastPathComponent().path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Activity

    /// When the tee last ran behind this settings file, and when it last
    /// saw figures. Written by the tee itself, so it proves the tool really
    /// runs the status line AgentDeck installed: a managed status line, a
    /// `CLAUDE_CONFIG_DIR` the app can't see, or a helper the Mac won't run
    /// all leave the settings looking installed but this unwritten.
    public struct Heartbeat: Codable, Equatable, Sendable {
        public var ranAt: Date
        public var figuresAt: Date?

        public init(ranAt: Date, figuresAt: Date? = nil) {
            self.ranAt = ranAt
            self.figuresAt = figuresAt
        }
    }

    public enum Activity: Equatable, Sendable {
        /// Ran since setup and has passed usage figures.
        case reporting
        /// Ran since setup but the tool never passed figures (an account
        /// without subscription limits, such as an API key or a plan that
        /// doesn't report them).
        case noFigures
        /// Not run since setup yet.
        case waiting
        /// Not run in the `notRunningAfter` since setup.
        case notRunning
    }

    /// Runs without figures for this long mean the account stopped
    /// reporting them (another login, a plan without limits). Every open
    /// session of an account with limits passes its cached figures on each
    /// refresh, so a gap this long isn't an idle session.
    public static let figuresLapseAfter: TimeInterval = 30 * 60

    /// How long after setup a tee that never ran counts as not running.
    /// Any status line refresh runs it, and a session refreshes within
    /// seconds of activity.
    public static let notRunningAfter: TimeInterval = 10 * 60
    static let heartbeatInterval: TimeInterval = 60

    static func activity(installedAt: Date?, heartbeat: Heartbeat?, now: Date) -> Activity {
        let since = installedAt ?? .distantPast
        if let heartbeat, heartbeat.ranAt >= since {
            if let figures = heartbeat.figuresAt, figures >= since,
               heartbeat.ranAt.timeIntervalSince(figures) <= figuresLapseAfter {
                return .reporting
            }
            return .noFigures
        }
        if let installedAt, now.timeIntervalSince(installedAt) > notRunningAfter { return .notRunning }
        return .waiting
    }

    func heartbeatURL(recordName: String) -> URL {
        chainDirectory.appendingPathComponent("\(recordName).ran")
    }

    func loadHeartbeat(recordName: String) -> Heartbeat? {
        guard let data = try? Data(contentsOf: heartbeatURL(recordName: recordName)) else { return nil }
        return try? UsageStore.decoder.decode(Heartbeat.self, from: data)
    }

    /// Notes a run. At most once a minute unless figures first appear:
    /// the status line can refresh several times a second. Called under
    /// the usage store's lock, so concurrent tees don't lose `figuresAt`.
    func noteRun(recordName: String, figures: Bool, now: Date) {
        guard !recordName.contains("/") else { return }
        let previous = loadHeartbeat(recordName: recordName)
        let next = Heartbeat(ranAt: now, figuresAt: figures ? now : previous?.figuresAt)
        if let previous, now.timeIntervalSince(previous.ranAt) < Self.heartbeatInterval,
           (previous.figuresAt != nil) == (next.figuresAt != nil) {
            return
        }
        guard let data = try? UsageStore.encoder.encode(next) else { return }
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: chainDirectory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return }
        let temp = chainDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return }
        if rename(temp.path, heartbeatURL(recordName: recordName).path) != 0 {
            try? fm.removeItem(at: temp)
        }
    }

    /// Whether the installed tee behind `provider`'s settings is running
    /// and reporting. nil when no tee of this install is in place.
    public func activity(for provider: Provider, settingsURL: URL? = nil, now: Date = Date()) -> Activity? {
        guard let settingsURL = (settingsURL ?? Self.settingsURL(for: provider))?.resolvingSymlinksInPath()
        else { return nil }
        let name = recordName(provider: provider, settingsURL: settingsURL)
        guard let record = loadRecord(at: chainDirectory.appendingPathComponent(name)) else { return nil }
        let installedAt = (record["installedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Self.activity(installedAt: installedAt, heartbeat: loadHeartbeat(recordName: name), now: now)
    }

    /// The original entry, plus whatever the user changed in other fields
    /// while the tee was installed (`padding`, `refreshInterval`, agy's
    /// `enabled`…): a field whose current value differs from what install
    /// wrote is the user's, and is kept. nil = remove the key.
    static func restoredEntry(original: Any?, installed: [String: Any]?,
                              current: [String: Any]) -> Any? {
        guard let installed else { return original }  // record from before this was kept
        var edits: [String: Any] = [:]
        var removed: [String] = []
        for (key, value) in current where key != "command" && key != "type" {
            if let wrote = installed[key], HookInstaller.jsonEqual([wrote], [value]) { continue }  // wrapped: a bare scalar isn't a JSON document
            edits[key] = value
        }
        for key in installed.keys where key != "command" && key != "type" && current[key] == nil {
            removed.append(key)
        }
        guard !edits.isEmpty || !removed.isEmpty else { return original }
        var entry = original as? [String: Any] ?? [:]
        guard original == nil || original is [String: Any] else { return original }
        for (key, value) in edits { entry[key] = value }
        for key in removed { entry.removeValue(forKey: key) }
        return entry
    }

    // MARK: - Running

    /// One tee run: record the figures (Claude's under the signed-in
    /// account), then run the user's original command with the same input.
    /// nil = nothing to chain (the tee prints nothing).
    public func run(provider: Provider, recordName: String, input: Data, store: UsageStore,
                    claudeAccount: () -> String?, now: Date = Date()) -> ChainRunner.Result? {
        let captured = StatusLineCapture.extract(provider: provider, data: input, now: now)
        // a run that began before uninstall still chains the user's
        // command, but records nothing: uninstall has deleted the figures
        let active = {
            !recordName.contains("/")
                && self.loadRecord(at: self.chainDirectory.appendingPathComponent(recordName)) != nil
        }
        if var usage = captured {
            if provider == .claude { usage.account = claudeAccount() }
            _ = try? store.recordUnlessEcho(usage, onlyIf: active)
        }
        _ = try? store.locked(provider) {
            if active() { noteRun(recordName: recordName, figures: captured != nil, now: now) }
        }
        guard let chained = chainedCommand(recordName: recordName) else { return nil }
        return ChainRunner.run(command: chained, input: input)
    }

    // MARK: - Install / uninstall

    /// Returns whether the settings file changed.
    @discardableResult
    public func install(_ provider: Provider, settingsURL: URL? = nil,
                        policy: @autoclosure () -> ClaudePolicy = .load()) throws -> Bool {
        guard let requested = settingsURL ?? Self.settingsURL(for: provider) else { return false }
        if provider == .claude, policy().statusLineBlocked { throw TeeError.blockedByPolicy }
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
                "installedAt": Date().timeIntervalSince1970,
            ]
            if let current { record["original"] = current } else { record[Self.absentMarker] = true }
            installed["type"] = "command"
            installed["command"] = ours
            // with no command of the user's to chain the tee prints nothing;
            // agy can stack its built-in line above a custom one
            if provider == .antigravity, !hadCommand { installed["stack_with_default"] = true }
            // what was written, so uninstall can tell the user's later
            // edits to other fields from the tee's own
            record["installed"] = installed
            pruneRetired()
            try writeRecord(record, to: recordURL)
            root["statusLine"] = installed
            try HookInstaller.backupAndWrite(root, to: url, basis: basis)
            return true
        }
    }

    /// Uninstalls each provider's tee and deletes its saved figures, which
    /// nothing will update any more. One line of outcome per provider, and
    /// whether any failed. Shared by the helper and the app, which runs it
    /// in-process so the tee can be removed even when the helper can't run.
    public func uninstallReport(_ providers: [Provider], store: UsageStore,
                                settingsURL: (Provider) -> URL? = { StatusLineTee.settingsURL(for: $0) })
        -> (lines: [String], failed: Bool) {
        var lines: [String] = []
        var failed = false
        for provider in providers {
            let name = provider.spec.displayName
            do {
                let url = settingsURL(provider)
                switch try uninstall(provider, settingsURL: url) {
                case .restored: lines.append("\(name): original status line restored")
                case .leftUserChange: lines.append("\(name): status line was changed since; left as it is")
                }
                // after the record is retired, under the lock tees record
                // under, so a run already in flight can't put them back
                _ = try? store.locked(provider) {
                    store.removeAllLocked(provider)
                    if let resolved = url?.resolvingSymlinksInPath() {
                        try? FileManager.default.removeItem(at: heartbeatURL(
                            recordName: recordName(provider: provider, settingsURL: resolved)))
                    }
                }
            } catch TeeError.missingRecord(let path) {
                if status(for: provider, settingsURL: settingsURL(provider), policy: .none) == .orphaned {
                    lines.append("\(name): \(TeeError.missingRecord(path))")
                    failed = true
                } else {
                    lines.append("\(name): no status line tee installed")
                }
            } catch {
                lines.append("\(name): \(error)")
                failed = true
            }
        }
        return (lines, failed)
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
                retire(record, at: recordURL)
                return .leftUserChange
            }
            let restored = Self.restoredEntry(
                original: record["original"], installed: record["installed"] as? [String: Any],
                current: root["statusLine"] as? [String: Any] ?? [:])
            if let restored {
                root["statusLine"] = restored
            } else {
                root.removeValue(forKey: "statusLine")
            }
            try HookInstaller.backupAndWrite(root, to: url, basis: basis)
            retire(record, at: recordURL)
            pruneRetired()
            return .restored
        }
    }
}
