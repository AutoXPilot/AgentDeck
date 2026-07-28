import AgentDeckCore
import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var attentionCount = 0
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var helperInstalled = false
    @Published private(set) var installMessage: String?
    @Published private(set) var isInstalling = false

    var onChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private let store = SnapshotStore()
    private var acks: [String: Date] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var sweepTimer: Timer?

    /// While the popover is visible, row ORDER is frozen so live events and
    /// ack-clicks don't reshuffle rows under the cursor; states and times
    /// still update in place. A fresh sort happens on every popover open.
    private var popoverVisible = false
    private var frozenOrder: [String]?

    /// Single pending focus action, fired when the popover actually closes
    /// (the real signal) rather than after a guessed delay. Single-slot:
    /// rapid clicks replace it instead of racing parallel osascripts.
    private var pendingFocus: (() -> Void)?

    private static let acksDefaultsKey = "acknowledgments"

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
        // keep the helper hooks invoke in lockstep with this build — an app
        // upgrade must never leave hooks running an old helper
        if let bundled = Self.bundledHelperURL,
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            if (try? HelperSync.sync(bundled: bundled, stable: Self.helperURL)) == true {
                installMessage = "helper updated to match this build"
            }
        }
        watchDirectory()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    // MARK: - Popover lifecycle

    /// Always resets the freeze so every open starts from a fresh sort,
    /// even if a previous close's delegate callback got swallowed by a
    /// rapid close→reopen.
    func popoverOpened() {
        frozenOrder = nil
        popoverVisible = true
        reload()
    }

    func popoverClosed() {
        popoverVisible = false
        frozenOrder = nil
        if let focus = pendingFocus {
            pendingFocus = nil
            // small settle for the activation hand-back, anchored to the
            // ACTUAL close instead of the click
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
            // Re-check on disk before deleting: a hook may have rewritten the
            // snapshot between loadAll() and now (e.g. claude --resume). This
            // NARROWS the race to milliseconds rather than eliminating it —
            // a write landing between this check and remove() is still lost,
            // which is benign: the session reappears on its next hook event.
            if let fresh = store.load(key: key),
               Liveness.keysToRemove([fresh]).isEmpty {
                continue
            }
            store.remove(key: key)
            removed.insert(key)
        }
        all.removeAll { removed.contains($0.key) }
        let sorted = Attention.sorted(all, acks: acks)
        if popoverVisible {
            let arranged = RowOrdering.arrange(sorted: sorted, frozenOrder: frozenOrder)
            sessions = arranged.rows
            frozenOrder = arranged.frozenOrder
        } else {
            sessions = sorted
            frozenOrder = nil
        }
        attentionCount = Attention.count(all, acks: acks)
        refreshHealth()
        onChange?()
    }

    func needsAttention(_ snapshot: SessionSnapshot) -> Bool {
        Attention.needsAttention(snapshot, ackedAt: acks[snapshot.key])
    }

    /// Row click: acknowledge, close the popover, then focus the iTerm pane
    /// once the close has actually happened (popoverClosed fires the action).
    func activate(_ snapshot: SessionSnapshot) {
        acks[snapshot.key] = Date()
        saveAcks()
        let guid = ITermFocus.sessionGUID(from: snapshot.terminalSessionId)
        let fallbackURL = ITermFocus.revealURL(terminalSessionId: snapshot.terminalSessionId)
        Self.appLog("activate key=\(snapshot.key) guid=\(guid ?? "nil")")
        if let guid {
            pendingFocus = {
                Task.detached {
                    let result = ITermFocus.focusViaAppleScript(guid: guid)
                    Self.appLog("applescript focus: \(result)")
                    if result != "focused", let fallbackURL {
                        await MainActor.run {
                            NSWorkspace.shared.open(fallbackURL)
                            Self.appLog("fell back to reveal URL")
                        }
                    }
                }
            }
        }
        if popoverVisible {
            onRequestClose?()  // popoverClosed() will fire pendingFocus
        } else if let focus = pendingFocus {
            pendingFocus = nil
            focus()
        }
        reload()
    }

    /// Runs `agentdeck-hook install` off the main actor; result lands in
    /// `installMessage` for the footer to display.
    func installHooks() {
        guard !isInstalling else { return }  // no concurrent installers
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
                // drain BEFORE waiting: waitUntilExit-first deadlocks once
                // output exceeds the pipe buffer
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

    // MARK: - Logging

    /// POSIX O_APPEND: atomic for small writes, safe across the main actor
    /// and detached tasks without coordination.
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
        // executability isn't enough: a stale helper must show as unhealthy
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
            // if the directory itself vanished, re-arm on the new inode —
            // otherwise the watcher silently dies and we degrade to
            // sweep-only latency forever
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
        // Drop acks for sessions that no longer exist to keep prefs tidy.
        let liveKeys = Set(sessions.map(\.key))
        acks = acks.filter { liveKeys.contains($0.key) || $0.value.timeIntervalSinceNow > -86400 }
        UserDefaults.standard.set(
            acks.mapValues { $0.timeIntervalSince1970 }, forKey: Self.acksDefaultsKey
        )
    }
}
