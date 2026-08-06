import AgentDeckCore
import AppKit
import Combine
import Darwin
import Foundation
import UserNotifications

@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    /// Menu-bar badge: blocked sessions only (waiting/error).
    @Published private(set) var alertCount = 0
    /// Finished-but-unacknowledged; shown muted, never in the badge.
    @Published private(set) var doneCount = 0
    @Published private(set) var mostUrgent: SessionState?
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var helperInstalled = false
    @Published private(set) var installMessage: String?
    @Published private(set) var isInstalling = false
    /// iTerm session GUID → tab title. Kept across opens so rows don't
    /// re-label under the cursor a second after the popover appears.
    @Published private(set) var terminalTitles: [String: String] = [:]
    /// Codex session id → name set via its `/rename`.
    @Published private(set) var codexNames: [String: String] = [:]
    @Published private(set) var codexThreads: [String: CodexThread] = [:]
    /// Why a session is blocked, once we know: "permission prompt", …
    @Published private(set) var waitingReasons: [String: String] = [:]
    /// Last pane-focus failure, surfaced in the footer instead of a log file.
    @Published private(set) var focusProblem: String?
    @Published private(set) var iTermRunning = false
    @Published var filterText = ""

    var onChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private let store = SnapshotStore()
    private var acks: [String: Date] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var sweepTimer: Timer?
    private var claudeRegistry: [Int32: ClaudeSessionRegistry.Entry] = [:]
    private var waitingTracker = WaitingTracker()
    private var notificationsAuthorized = false

    /// While the popover is visible, row ORDER is frozen so live events and
    /// ack-clicks don't reshuffle rows under the cursor; states and times
    /// still update in place. A fresh sort happens on every popover open.
    private var popoverVisible = false
    private var frozenOrder: [String]?
    private var pendingFocus: (() -> Void)?

    private static let acksDefaultsKey = "acknowledgments"
    private static let waitAlertMinutesKey = "waitAlertMinutes"

    /// Minutes a session may sit blocked before we interrupt the user.
    /// 0 disables notifications entirely.
    var waitAlertMinutes: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: Self.waitAlertMinutesKey) as? Int
            return stored ?? 5
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.waitAlertMinutesKey) }
    }

    static var helperURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/bin/agentdeck-hook")
    }

    static var bundledHelperURL: URL? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("agentdeck-hook")
    }

    func start() {
        loadAcks()
        try? FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true
        )
        if let bundled = Self.bundledHelperURL,
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            if (try? HelperSync.sync(bundled: bundled, stable: Self.helperURL)) == true {
                installMessage = "helper updated to match this build"
            }
        }
        requestNotificationAuthorization()
        watchDirectory()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        refreshTerminalTitles()
        reload()
    }

    // MARK: - Popover lifecycle

    func popoverOpened() {
        frozenOrder = nil
        popoverVisible = true
        filterText = ""
        codexNames = CodexSessionIndex.load()
        codexThreads = CodexThreads.load()
        reload()
        refreshTerminalTitles()
    }

    func popoverClosed() {
        popoverVisible = false
        frozenOrder = nil
        if let focus = pendingFocus {
            pendingFocus = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: focus)
        }
        reload()
    }

    // MARK: - Data

    func reload() {
        var all = store.loadAll()
        store.sweepOrphans()
        var removed = Set<String>()
        for key in Liveness.keysToRemove(all) {
            if let fresh = store.load(key: key), Liveness.keysToRemove([fresh]).isEmpty {
                continue
            }
            store.remove(key: key)
            removed.insert(key)
        }
        all.removeAll { removed.contains($0.key) }

        claudeRegistry = ClaudeSessionRegistry.load()
        all = reconcile(all)

        let sorted = Attention.sorted(all, acks: acks)
        if popoverVisible {
            let arranged = RowOrdering.arrange(sorted: sorted, frozenOrder: frozenOrder)
            sessions = arranged.rows
            frozenOrder = arranged.frozenOrder
        } else {
            sessions = sorted
            frozenOrder = nil
        }
        alertCount = Attention.alertCount(all, acks: acks)
        doneCount = Attention.doneCount(all, acks: acks)
        mostUrgent = Attention.mostUrgent(all, acks: acks)
        escalateLongWaits(all)
        refreshHealth()
        onChange?()
    }

    /// Hooks never fire when a permission prompt is answered, so a `waiting`
    /// row can outlive the block by hours. Claude's own registry knows, and
    /// also spots blocks no hook reported. Newer observation wins.
    private func reconcile(_ snapshots: [SessionSnapshot]) -> [SessionSnapshot] {
        var reasons: [String: String] = [:]
        let result: [SessionSnapshot] = snapshots.map { snapshot in
            var adjusted = snapshot
            // Re-judge waits recorded by older builds, which counted an idle
            // nudge as a block. Done before registry reconciliation so a
            // stale `waiting` doesn't survive on disk-age alone.
            if adjusted.state == .waiting, let type = snapshot.notificationType,
               !EventMapping.isBlockingNotification(type) {
                adjusted.state = .ready
            }
            if snapshot.provider == .claude, let pid = snapshot.agentPid {
                let outcome = StateReconciler.reconcile(
                    snapshot: snapshot, entry: claudeRegistry[pid]
                )
                adjusted.state = outcome.state
                if let reason = outcome.waitingFor { reasons[snapshot.key] = reason }
            } else if snapshot.state == .waiting, let type = snapshot.notificationType {
                reasons[snapshot.key] = type.replacingOccurrences(of: "_", with: " ")
            }
            return adjusted
        }
        waitingReasons = reasons
        return result
    }

    var visibleSessions: [SessionSnapshot] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            title(for: $0).lowercased().contains(query)
                || $0.projectPath.lowercased().contains(query)
        }
    }

    func needsAttention(_ snapshot: SessionSnapshot) -> Bool {
        Attention.needsAttention(snapshot, ackedAt: acks[snapshot.key])
    }

    /// Row title, best available. Claude publishes a session name in its
    /// registry (cleaner than the tab title and available outside iTerm);
    /// Codex publishes one in its session index.
    func title(for snapshot: SessionSnapshot) -> String {
        if snapshot.provider == .claude, let pid = snapshot.agentPid,
           let entry = claudeRegistry[pid], entry.sessionId == snapshot.sessionId,
           entry.isUserNamed, let name = entry.name {
            return name
        }
        if snapshot.provider == .codex {
            if let name = codexNames[snapshot.sessionId], !name.isEmpty { return name }
            if let title = codexThreads[snapshot.sessionId]?.displayTitle { return title }
        }
        if let guid = ITermFocus.sessionGUID(from: snapshot.terminalSessionId),
           let name = terminalTitles[guid], !name.isEmpty {
            return name
        }
        if snapshot.provider == .claude, let pid = snapshot.agentPid,
           let name = claudeRegistry[pid]?.name, !name.isEmpty {
            return name
        }
        return snapshot.projectName
    }

    func subtitle(for snapshot: SessionSnapshot) -> String {
        PathFormat.abbreviate(snapshot.projectPath)
    }

    /// Extra badges: why it's waiting, unsupervised mode, model.
    func detail(for snapshot: SessionSnapshot) -> String? {
        if snapshot.state == .waiting, let reason = waitingReasons[snapshot.key] {
            return ITermFocus.humanizeReason(reason)
        }
        return nil
    }

    func isUnsupervised(_ snapshot: SessionSnapshot) -> Bool {
        if snapshot.isUnsupervised { return true }
        if snapshot.provider == .codex,
           let thread = codexThreads[snapshot.sessionId] {
            return thread.isUnsupervised
        }
        return false
    }

    func canFocus(_ snapshot: SessionSnapshot) -> Bool {
        ITermFocus.sessionGUID(from: snapshot.terminalSessionId) != nil
    }

    // MARK: - Actions

    /// Row click: acknowledge, close the popover, then focus the iTerm pane
    /// once the close has actually happened.
    func activate(_ snapshot: SessionSnapshot) {
        acknowledge(snapshot)
        guard let guid = ITermFocus.sessionGUID(from: snapshot.terminalSessionId) else {
            focusProblem = "This session isn't in iTerm2, so there's no pane to focus."
            if popoverVisible { onRequestClose?() }
            return
        }
        guard NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) else {
            focusProblem = "iTerm2 isn't running."
            if popoverVisible { onRequestClose?() }
            return
        }
        let fallbackURL = ITermFocus.revealURL(terminalSessionId: snapshot.terminalSessionId)
        Self.appLog("activate key=\(snapshot.key) guid=\(guid)")
        pendingFocus = { [weak self] in
            // The osascript call blocks, so it runs detached — capturing only
            // the guid string, never self, to stay Sendable-clean.
            Task { @MainActor in
                let result = await Task.detached {
                    ITermFocus.focusViaAppleScript(guid: guid)
                }.value
                SessionsModel.appLog("applescript focus: \(result)")
                guard let self else { return }
                if result == "focused" {
                    self.focusProblem = nil
                } else {
                    self.focusProblem = SessionsModel.describeFocusFailure(result)
                    if let fallbackURL { NSWorkspace.shared.open(fallbackURL) }
                }
            }
        }
        if popoverVisible {
            onRequestClose?()
        } else if let focus = pendingFocus {
            pendingFocus = nil
            focus()
        }
        reload()
    }

    /// Acknowledge without focusing anything.
    func acknowledge(_ snapshot: SessionSnapshot) {
        acks[snapshot.key] = Date()
        saveAcks()
        reload()
    }

    func acknowledgeAllDone() {
        let now = Date()
        for snapshot in sessions where snapshot.state == .done {
            acks[snapshot.key] = now
        }
        saveAcks()
        reload()
    }

    nonisolated static func describeFocusFailure(_ result: String) -> String {
        if result.contains("timed out") || result.lowercased().contains("not allowed")
            || result.contains("-1743") {
            return "AgentDeck needs Automation permission to control iTerm2."
        }
        if result == "not-found" {
            return "That iTerm2 pane no longer exists."
        }
        return "Couldn't focus the pane: \(result)"
    }

    func openAutomationSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func copyDiagnostics() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var lines = [
            "AgentDeck \(AgentDeckVersion.current)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "sessions: \(sessions.count) (alerts \(alertCount), done \(doneCount))",
            "hooks: helper=\(helperInstalled) claude=\(claudeHooksInstalled) "
                + "codex=\(codexHooksInstalled)",
            "iTerm running: \(iTermRunning), titles cached: \(terminalTitles.count)",
            "claude registry entries: \(claudeRegistry.count), "
                + "codex threads: \(codexThreads.count)",
        ]
        if let problem = focusProblem { lines.append("last focus problem: \(problem)") }
        let logURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/app.log")
        if let log = try? String(contentsOf: logURL, encoding: .utf8) {
            lines.append("--- app.log (tail) ---")
            lines.append(contentsOf: log.split(separator: "\n").suffix(40).map(String.init))
        }
        let text = lines.joined(separator: "\n")
            .replacingOccurrences(of: home, with: "~")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        installMessage = "Diagnostics copied to clipboard"
    }

    func installHooks() {
        guard !isInstalling else { return }
        let bundled = Self.bundledHelperURL
        guard let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) else {
            installMessage = "agentdeck-hook binary not found next to the app"
            return
        }
        isInstalling = true
        installMessage = "Installing…"
        Task.detached {
            var text: String
            do {
                let process = Process()
                process.executableURL = bundled
                process.arguments = ["install"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus != 0 {
                    text = "install failed (exit \(process.terminationStatus)): \(text)"
                }
            } catch {
                text = "install failed: \(error.localizedDescription)"
            }
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { [weak self] in
                self?.installMessage = message.isEmpty ? "done" : message
                self?.isInstalling = false
                self?.reload()
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        guard waitAlertMinutes > 0 else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                Task { @MainActor in self?.notificationsAuthorized = granted }
                if let error {
                    Self.appLog("notifications unavailable: \(error.localizedDescription)")
                } else {
                    Self.appLog("notifications authorized: \(granted)")
                }
            }
    }

    private func escalateLongWaits(_ snapshots: [SessionSnapshot]) {
        let minutes = waitAlertMinutes
        guard minutes > 0 else { return }
        let due = waitingTracker.update(
            snapshots, threshold: TimeInterval(minutes * 60)
        )
        guard !due.isEmpty else { return }
        for key in due {
            guard let snapshot = snapshots.first(where: { $0.key == key }) else { continue }
            let heading = "\(snapshot.provider.displayName) is waiting on you"
            var body = title(for: snapshot)
            if let reason = waitingReasons[key] { body += " — \(reason)" }
            post(title: heading, body: body, key: key)
            Self.appLog("notified: \(key) waiting > \(minutes)m")
        }
    }

    private func post(title heading: String, body: String, key: String) {
        if notificationsAuthorized {
            let content = UNMutableNotificationContent()
            content.title = heading
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: key, content: content, trigger: nil)
            )
            return
        }
        // Ad-hoc signed builds are refused by UNUserNotificationCenter
        // ("Notifications are not allowed for this application"), which is
        // every Homebrew --HEAD install. osascript still gets a banner
        // through; it's attributed to Script Editor, which is the price of
        // not having a $99 Developer ID.
        Task.detached {
            _ = ITermFocus.runAppleScript(
                """
                on run argv
                    display notification (item 2 of argv) with title (item 1 of argv)
                end run
                """,
                arguments: [heading, body],
                timeout: 10
            )
        }
    }

    // MARK: - Logging

    nonisolated static func appLog(_ message: String) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck")
        let url = dir.appendingPathComponent("app.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 256 * 1024 {
            let old = dir.appendingPathComponent("app.log.old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let line = "\(Date()) \(message)\n"
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = Data(line.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    // MARK: - Private

    private static let bundledHelperHash: String? = {
        bundledHelperURL.flatMap { HelperSync.sha256(of: $0) }
    }()
    private var stableHashCache: (mtime: Date, size: Int, hash: String)?
    private var titleFetchGeneration = 0

    private func stableHelperHash() -> String? {
        let path = Self.helperURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue
        else { return nil }
        if let cached = stableHashCache, cached.mtime == mtime, cached.size == size {
            return cached.hash
        }
        guard let hash = HelperSync.sha256(of: Self.helperURL) else { return nil }
        stableHashCache = (mtime, size, hash)
        return hash
    }

    private func refreshHealth() {
        var helperOK = FileManager.default.isExecutableFile(atPath: Self.helperURL.path)
        if helperOK, let bundledHash = Self.bundledHelperHash {
            helperOK = stableHelperHash() == bundledHash
        }
        helperInstalled = helperOK
        let installer = HookInstaller(helperPath: Self.helperURL.path)
        claudeHooksInstalled = installer.isInstalled(
            provider: .claude, in: HookInstaller.defaultClaudeSettingsURL
        )
        codexHooksInstalled = installer.isInstalled(
            provider: .codex, in: HookInstaller.defaultCodexHooksURL
        )
        iTermRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
    }

    private func refreshTerminalTitles() {
        guard iTermRunning || NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) else {
            Self.appLog("titles: iTerm not running; skipping fetch")
            return
        }
        titleFetchGeneration += 1
        let generation = titleFetchGeneration
        Task.detached {
            let outcome = ITermFocus.fetchSessionNames()
            let names: [String: String]
            switch outcome {
            case .success(let raw):
                names = ITermFocus.parseSessionNames(raw)
                Self.appLog("titles: fetched \(names.count) session titles")
            case .failure(let err):
                Self.appLog("titles: fetch FAILED: \(err)")
                return
            }
            guard !names.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.titleFetchGeneration else { return }
                self.terminalTitles = names
                self.onChange?()
            }
        }
    }

    private func watchDirectory() {
        dirWatcher?.cancel()
        dirWatcher = nil
        let fd = open(store.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: self.store.directory.path) {
                try? FileManager.default.createDirectory(
                    at: self.store.directory, withIntermediateDirectories: true
                )
                self.watchDirectory()
            }
            self.reload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatcher = source
    }

    private func loadAcks() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.acksDefaultsKey)
        else { return }
        acks = stored.compactMapValues { value in
            (value as? Double).map { Date(timeIntervalSince1970: $0) }
        }
    }

    private func saveAcks() {
        let liveKeys = Set(sessions.map(\.key))
        acks = acks.filter { liveKeys.contains($0.key) || $0.value.timeIntervalSinceNow > -86400 }
        UserDefaults.standard.set(
            acks.mapValues { $0.timeIntervalSince1970 }, forKey: Self.acksDefaultsKey
        )
    }
}
