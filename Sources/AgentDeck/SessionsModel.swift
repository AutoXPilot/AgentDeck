import AgentDeckCore
import AppKit
import Combine
import Foundation

@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var attentionCount = 0
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var helperInstalled = false

    var onChange: (() -> Void)?

    private let store = SnapshotStore()
    private var acks: [String: Date] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var sweepTimer: Timer?

    private static let acksDefaultsKey = "acknowledgments"

    static var helperURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/bin/agentdeck-hook")
    }

    func start() {
        loadAcks()
        try? FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true
        )
        watchDirectory()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reload()
    }

    func reload() {
        var all = store.loadAll()
        let dead = Set(Liveness.keysToRemove(all))
        dead.forEach { store.remove(key: $0) }
        all.removeAll { dead.contains($0.key) }
        sessions = Attention.sorted(all, acks: acks)
        attentionCount = Attention.count(all, acks: acks)
        refreshHealth()
        onChange?()
    }

    func needsAttention(_ snapshot: SessionSnapshot) -> Bool {
        Attention.needsAttention(snapshot, ackedAt: acks[snapshot.key])
    }

    /// Row click: acknowledge the current event and focus the iTerm pane.
    func activate(_ snapshot: SessionSnapshot) {
        acks[snapshot.key] = Date()
        saveAcks()
        if let url = ITermFocus.revealURL(terminalSessionId: snapshot.terminalSessionId) {
            NSWorkspace.shared.open(url)
        }
        reload()
    }

    func installHooks() -> String {
        // The helper binary sits next to this app's executable in the build
        // products; `agentdeck-hook install` copies it to the stable path and
        // registers hooks for both providers.
        let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("agentdeck-hook")
        guard let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) else {
            return "agentdeck-hook binary not found next to the app"
        }
        let process = Process()
        process.executableURL = bundled
        process.arguments = ["install"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            reload()
            return String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func refreshHealth() {
        helperInstalled = FileManager.default.isExecutableFile(atPath: Self.helperURL.path)
        let installer = HookInstaller(helperPath: Self.helperURL.path)
        claudeHooksInstalled = installer.isInstalled(
            in: HookInstaller.defaultClaudeSettingsURL
        )
        codexHooksInstalled = installer.isInstalled(in: HookInstaller.defaultCodexHooksURL)
    }

    private func watchDirectory() {
        let fd = open(store.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.reload() }
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
