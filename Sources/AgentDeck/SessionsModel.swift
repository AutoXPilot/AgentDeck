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
    /// Hook health as the footer shows it: installed, missing, blocked by
    /// the organization's Claude policy, or not applicable (no Codex).
    @Published private(set) var claudeStatus: HookStatus = .missing
    @Published private(set) var codexStatus: HookStatus = .missing
    @Published private(set) var claudePolicy = ClaudePolicy.none
    /// iTerm2 is installed, not merely running. Restore opens tabs in it;
    /// without it there's nowhere to open them.
    @Published private(set) var iTermInstalled = true

    /// Anything the Install button would actually fix.
    var hooksNeedInstalling: Bool {
        !helperInstalled || claudeStatus == .missing || codexStatus == .missing
    }
    @Published private(set) var helperInstalled = false
    /// A message counts as seen only at an open that happens after it was
    /// set. Restore reports while the popover is closed — progress, the
    /// result, the 30-second confirmation — and each of those was being
    /// cleared on the next open because an *earlier* message had been
    /// shown at the open before.
    @Published private(set) var installMessage: String? {
        didSet { if installMessage != oldValue { noteMessageChanged() } }
    }
    @Published private(set) var isInstalling = false
    /// iTerm session GUID → tab title. Kept across opens so rows don't
    /// re-label under the cursor a second after the popover appears.
    @Published private(set) var terminalTitles: [String: String] = [:]
    /// "ttys018" → iTerm session GUID, from the same fetch as the titles.
    private var paneByTTY: [String: String] = [:]
    /// Codex session id → name set via its `/rename`.
    @Published private(set) var codexNames: [String: String] = [:]
    @Published private(set) var codexThreads: [String: CodexThread] = [:]
    /// Claude session id → model from its transcript's last assistant turn.
    @Published private(set) var claudeModels: [String: String] = [:]
    /// Claude session id → how it was launched ("bg" = daemonized
    /// background session, which has no window to focus).
    @Published private(set) var claudeSessionKinds: [String: String] = [:]
    /// Why a session is blocked, once we know: "permission prompt", …
    @Published private(set) var waitingReasons: [String: String] = [:]
    /// Last pane-focus failure, surfaced in the footer instead of a log file.
    @Published private(set) var focusProblem: String? {
        didSet { if focusProblem != oldValue { noteMessageChanged() } }
    }
    @Published private(set) var iTermRunning = false
    @Published var filterText = ""
    /// Bumped on every popover open; the view watches it to reset transient
    /// state (keyboard selection) that must not survive across opens.
    @Published private(set) var openGeneration = 0

    var onChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    // Workspaces: what to bring back after a reboot or an iTerm restart.
    @Published private(set) var restoreOffers: [RestoreOffer] = []
    @Published private(set) var bannerOffer: RestoreOffer?
    @Published private(set) var namedWorkspaces: [NamedWorkspace] = []
    @Published private(set) var isRestoring = false
    /// Sessions a restore skipped because their folder is gone, each
    /// offered a "Locate…" so the rest of the recovery can be finished
    /// from here rather than by hand.
    @Published private(set) var missingFolders: [MissingFolder] = []
    /// Bumped per restore, so a slower, older restore's messages can't
    /// overwrite a newer one's.
    private var restoreGeneration = 0
    /// Reservations (see `WorkspaceStore.reserve`) whose sessions aren't
    /// running: launched, or possibly launched, and not yet seen. Shown in
    /// the footer with a Clear, since nothing expires them on its own.
    @Published private(set) var pendingRestores: [String] = []
    private let workspaceStore = WorkspaceStore()
    private let bootID = WorkspaceStore.currentBootID()
    private static let dismissedRestoreOfferKey = "dismissedRestoreOfferBoot"

    private let store = SnapshotStore()
    private var acks: [String: Date] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var sweepTimer: Timer?
    private var claudeRegistry: [Int32: ClaudeSessionRegistry.Entry] = [:]
    /// Live sessions by session id — the discovery source that makes rows
    /// appear for sessions the hooks never saw.
    private(set) var claudeLiveSessions: [String: ClaudeSessionRegistry.Entry] = [:]
    private var waitingTracker = WaitingTracker()
    private var didSeedWaitingBacklog = false
    private static let waitingMemoryKey = "waitingTrackerMemory"
    private var lastSavedWaitingMemory: WaitingTracker.Memory?
    /// Set once the first discovery-era launch has quieted the backlog it
    /// surfaced. Persisted, so later relaunches don't quiet it again — which
    /// kept a session blocked at startup silent for as long as AgentDeck
    /// kept being restarted.
    private static let discoveryBacklogSeededKey = "discoveryBacklogSeeded"
    private var notificationsAuthorized = false
    /// Render harness: observe only, never delete/sweep/notify — a second
    /// instance must not race the live app over shared files.
    private var readOnly = false

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

    /// `forRendering` = the offscreen --render-popover harness: read
    /// everything, mutate NOTHING. Without this the harness (running from
    /// .build/debug) synced the DEBUG helper over the production one and
    /// fought the live app instance for the file.
    func start(forRendering: Bool = false) {
        loadAcks()
        if forRendering {
            readOnly = true
            // twice: the first applies auto-acknowledgements, the second
            // sorts with them, as consecutive reloads do in the app
            reload()
            reload()
            refreshWorkspaces()
            refreshTerminalTitles()
            return
        }
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
            Task { @MainActor in
                self?.ensureWatching()
                self?.reload(sweep: true)  // the one place that sweeps orphans
            }
        }
        // .common so the 15s sweep keeps firing while a menu/context menu is
        // tracking the run loop (the dispatch watcher covers live updates,
        // but the periodic identity re-check shouldn't stall).
        if let sweepTimer { RunLoop.main.add(sweepTimer, forMode: .common) }
        refreshTerminalTitles()
        reload()
        refreshWorkspaces()
    }

    // MARK: - Popover lifecycle

    func popoverOpened() {
        frozenOrder = nil
        popoverVisible = true
        filterText = ""
        openGeneration += 1
        // A focus queued by a click that raced a fast reopen must not fire
        // on some unrelated close minutes later.
        pendingFocus = nil
        // Clear a transient message only AFTER it has been visible for a full
        // open. focusProblem/installMessage are often set during a CLOSE
        // (the focus fires ~0.1s after popoverClosed), so eagerly clearing at
        // open hid them entirely — the whole "failures are visible" feature.
        if let gen = messageShownAtGen, openGeneration > gen, !isRestoring {
            installMessage = nil
            focusProblem = nil
            messageShownAtGen = nil
        }
        if installMessage != nil || focusProblem != nil {
            messageShownAtGen = openGeneration  // this open displays it
        }
        codexNames = CodexSessionIndex.load()
        reload()
        refreshWorkspaces()
        refreshTerminalTitles()
        loadCodexThreadsAsync()
        loadClaudeModelsAsync()
    }

    private func loadCodexThreadsAsync() {
        // sqlite3 off the main thread; generation-guarded so a slow older read
        // can't clobber a newer one, and an empty result clears stale rows.
        codexThreadGeneration += 1
        let gen = codexThreadGeneration
        Task.detached {
            // Stamped BEFORE the read, not after. The database state we are
            // about to observe is at least this old, and a hook that lands
            // while sqlite3 is still running would otherwise be timestamped
            // earlier than the cache that missed it — letting the older
            // value win.
            let readAt = Date()
            let threads = CodexThreads.load()
            Task { @MainActor [weak self] in
                guard let self, gen == self.codexThreadGeneration else { return }
                self.codexThreads = threads
                self.codexThreadsLoadedAt = readAt
                self.onChange?()
            }
        }
    }

    /// Reads each Claude session's transcript for the model of its last
    /// assistant turn. Off the main thread, and transcripts whose mtime+size
    /// haven't moved since the last read are not re-opened.
    private func loadClaudeModelsAsync() {
        claudeModelGeneration += 1
        let gen = claudeModelGeneration
        let wanted = sessions
            .filter { $0.provider == .claude }
            .map { (id: $0.sessionId, path: $0.projectPath) }
        guard !wanted.isEmpty else {
            // no Claude rows left: drop the caches rather than letting them
            // outlive the sessions they describe
            claudeModels = [:]
            claudeSessionKinds = [:]
            claudeModelFingerprints = [:]
            claudeModelsAttempted = []
            return
        }
        let attempted = Set(wanted.map(\.id))
        let knownFingerprints = claudeModelFingerprints
        let knownModels = claudeModels
        let knownKinds = claudeSessionKinds
        Task.detached {
            var models: [String: String] = [:]
            var kinds: [String: String] = [:]
            var fingerprints: [String: String] = [:]
            for session in wanted {
                guard let url = ClaudeTranscript.url(
                    sessionId: session.id, projectPath: session.path
                ) else { continue }
                // the path is part of the identity: the same id can resolve
                // to a different transcript, and two files can share a
                // size and mtime
                let fingerprint = ClaudeTranscript.fingerprint(of: url)
                    .map { "\(url.path)|\($0)" }
                if let fingerprint, fingerprint == knownFingerprints[session.id],
                   let cached = knownModels[session.id] {
                    models[session.id] = cached
                    kinds[session.id] = knownKinds[session.id]
                    fingerprints[session.id] = fingerprint
                    continue
                }
                guard let reading = ClaudeTranscript.latest(at: url) else { continue }
                models[session.id] = reading.model
                kinds[session.id] = reading.sessionKind
                fingerprints[session.id] = fingerprint
            }
            Task { @MainActor [weak self] in
                guard let self, gen == self.claudeModelGeneration else { return }
                self.claudeModels = models
                self.claudeSessionKinds = kinds
                self.claudeModelFingerprints = fingerprints
                self.claudeModelsAttempted = attempted
                self.onChange?()
            }
        }
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

    /// Watcher-driven entry point: coalesces a storm of hook-write events
    /// (dozens/minute at ten sessions) into one reload. Direct calls
    /// (popover open, clicks, the 15s tick) still use `reload()` immediately.
    func scheduleReload() {
        guard reloadDebounce == nil else { return }
        reloadDebounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                self?.reloadDebounce = nil
                self?.reload()
            }
        }
    }

    func reload(sweep: Bool = false) {
        var all = store.loadAll()

        // Read the registry BEFORE deciding what to delete. Expiring a
        // snapshot whose session is demonstrably still running no longer
        // hides the row — discovery re-adds it — but it does throw away
        // the pane id and hook state, leaving a row that can't be clicked
        // to its terminal. Loading this first lets the sweep skip them.
        claudeRegistry = ClaudeSessionRegistry.load()
        claudeLiveSessions = ClaudeSessionRegistry.liveSessions()
        let confirmedLive = Set(claudeLiveSessions.keys)
        let liveByPid = Dictionary(claudeLiveSessions.values.map { ($0.pid, $0) },
                                   uniquingKeysWith: { a, b in
                                       (a.observedAt ?? .distantPast) >= (b.observedAt ?? .distantPast) ? a : b
                                   })

        var removed = Set<String>()
        if readOnly {
            // hide what the live app would remove, but touch nothing
            removed = Set(Liveness.keysToRemove(all, confirmedLive: confirmedLive,
                                                liveByPid: liveByPid))
        } else {
            // sweepOrphans stats+re-decodes every file; only the 15s tick
            // needs it, not every hook-driven reload.
            if sweep { store.sweepOrphans() }
            for key in Liveness.keysToRemove(all, confirmedLive: confirmedLive,
                                             liveByPid: liveByPid) {
                // Re-read and delete under the SAME lock the helper writes
                // under. Unlocked, a helper could publish a fresh event in
                // the gap between the re-read and the delete, and we would
                // delete that fresh event — losing a live session's row.
                // no lock, no delete: a row kept one more cycle is harmless
                let deleted = (try? store.withKeyLock(key) { () -> Bool in
                    if let fresh = store.load(key: key),
                       Liveness.keysToRemove(
                           [fresh], confirmedLive: confirmedLive, liveByPid: liveByPid
                       ).isEmpty {
                        return false
                    }
                    store.remove(key: key)
                    return true
                }) ?? false
                if deleted { removed.insert(key) }
            }
        }
        all.removeAll { removed.contains($0.key) }

        // All derivation lives in the tested core; this method only reads
        // files, assigns outputs, and performs side effects.
        let output = SessionPipeline.run(
            snapshots: all,
            registry: claudeRegistry,
            liveSessions: claudeLiveSessions,
            acks: acks,
            frozenOrder: frozenOrder,
            popoverVisible: popoverVisible,
            now: Date()
        )
        // Auto-acknowledge done sessions finished > 30 min ago so the
        // done-count reflects only fresh finishes. Persist once, like a
        // manual ack, so it survives relaunch.
        // Applied in read-only mode too, in memory only, so a render shows
        // what the app shows.
        let expired = AutoAck.expiredDoneKeys(output.rows, acks: acks)
        if !expired.isEmpty {
            let now = Date()
            for key in expired { acks[key] = now }
            if !readOnly { saveAcks() }
        }

        sessions = output.rows
        frozenOrder = popoverVisible ? output.frozenOrder : nil
        waitingReasons = output.waitingReasons
        alertCount = output.alertCount
        doneCount = output.doneCount
        mostUrgent = output.mostUrgent
        // recompute the two acked-dependent counts after auto-ack so the
        // header reflects it this cycle, not next
        doneCount = Attention.doneCount(output.rows, acks: acks)
        alertCount = Attention.alertCount(output.rows, acks: acks)
        // The first reload of a process must not fire a banner for every
        // session that was already blocked before the app started — which
        // discovery makes a real possibility, since it surfaces sessions
        // that have been waiting for weeks.
        if !didSeedWaitingBacklog {
            didSeedWaitingBacklog = true
            if let data = UserDefaults.standard.data(forKey: Self.waitingMemoryKey),
               let memory = try? JSONDecoder().decode(WaitingTracker.Memory.self, from: data) {
                waitingTracker = WaitingTracker(memory: memory)
            }
            // Only sessions discovered from the registry. Seeding every
            // waiting row would also mute hook-reported ones, so a session
            // blocked at launch couldn't notify for a full hour even with
            // waitAlertMinutes=5 — which is a behaviour change nobody asked
            // for. The burst risk is specific to rows that were previously
            // invisible.
            let discoveredBacklog = output.rows.filter {
                $0.event == "RegistryDiscovery"
            }
            // Once ever, not once per launch: the remembered cooldowns cover
            // relaunches from then on.
            if !readOnly, !discoveredBacklog.isEmpty,
               !UserDefaults.standard.bool(forKey: Self.discoveryBacklogSeededKey) {
                waitingTracker.suppressExistingBacklog(discoveredBacklog)
                UserDefaults.standard.set(true, forKey: Self.discoveryBacklogSeededKey)
            }
        }
        escalateLongWaits(output.rows)
        recordWorkspaceGeneration(output.rows)
        releaseConfirmedRestores(output.rows)
        refreshHealth()
        // Transcript-derived facts (model, background-session kind) used to
        // refresh only on popover open, so a /model switch or a newly
        // arrived background row stayed wrong for as long as the popover
        // stayed up. Refresh while it's visible, and whenever a Claude
        // session appears that we know nothing about. Unchanged transcripts
        // cost one stat each, not a read.
        // keyed on *attempted*, not on a successful read: a session with no
        // transcript would otherwise re-trigger a load on every reload
        let unknown = output.rows.contains {
            $0.provider == .claude && !claudeModelsAttempted.contains($0.sessionId)
        }
        if popoverVisible || unknown { loadClaudeModelsAsync() }
        onChange?()
    }

    var visibleSessions: [SessionSnapshot] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty ? sessions : sessions.filter {
            title(for: $0).lowercased().contains(query)
                || $0.projectPath.lowercased().contains(query)
        }
        // `sessions` is already deduplicated by SessionPipeline and filtering
        // can't introduce duplicates, so no dedupe/assert is needed here (the
        // guard lives in the pipeline, which has tests for it).
        return matching
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
        if snapshot.provider == .codex,
           let name = codexNames[snapshot.sessionId], !name.isEmpty {
            // only `/rename` — the sqlite title is the first user message
            // when a thread was never renamed, so it is never consulted
            return name
        }
        if let guid = ITermFocus.sessionGUID(from: snapshot.terminalSessionId),
           let name = terminalTitles[guid], !name.isEmpty {
            return name
        }
        if snapshot.provider == .claude, let pid = snapshot.agentPid,
           let entry = claudeRegistry[pid], entry.sessionId == snapshot.sessionId,
           let name = entry.name, !name.isEmpty {
            // registry files outlive their processes; without the sessionId
            // check a recycled pid shows another session's name
            return name
        }
        let folder = snapshot.projectName
        if !folder.isEmpty { return folder }
        // cwd-less snapshot (a Notification arriving before SessionStart): a
        // short session id beats a blank, unidentifiable row.
        return "session " + snapshot.sessionId.prefix(8)
    }

    func subtitle(for snapshot: SessionSnapshot) -> String {
        PathFormat.abbreviate(snapshot.projectPath)
    }

    /// The row's secondary line: why it's waiting, or why it errored.
    func detail(for snapshot: SessionSnapshot) -> String? {
        // reasons arrive pre-humanized from the pipeline
        if snapshot.state == .waiting, let reason = waitingReasons[snapshot.key] {
            return reason
        }
        if snapshot.state == .error, let kind = snapshot.errorKind {
            return kind.replacingOccurrences(of: "_", with: " ")
        }
        return nil
    }

    /// What clicking will do, in words — "Focus this iTerm pane" /
    /// "Bring ChatGPT to the front" / an explanation when neither applies.
    func focusDescription(for snapshot: SessionSnapshot) -> String {
        FocusResolver.describe(
            focusTarget(for: snapshot), sessionKind: sessionKind(for: snapshot)
        )
    }

    /// How Claude launched this session ("bg" for a daemonized background
    /// session). Read from the transcript, which is the only place that
    /// records it — background sessions write no entry in
    /// `~/.claude/sessions/`.
    func sessionKind(for snapshot: SessionSnapshot) -> String? {
        guard snapshot.provider == .claude else { return nil }
        return claudeSessionKinds[snapshot.sessionId]
    }

    func isBackgroundSession(_ snapshot: SessionSnapshot) -> Bool {
        FocusResolver.isBackground(sessionKind: sessionKind(for: snapshot))
    }

    /// The raw model identifier. Which source wins, and why, is decided in
    /// `ModelSource` — it's the part worth testing.
    func rawModel(for snapshot: SessionSnapshot) -> String? {
        switch snapshot.provider {
        case .claude:
            return ModelSource.claude(
                payload: snapshot.model,
                transcript: claudeModels[snapshot.sessionId]
            )
        case .codex:
            return ModelSource.codex(
                payload: snapshot.model,
                payloadObservedAt: snapshot.modelObservedAt,
                cached: codexThreads[snapshot.sessionId]?.model,
                cacheReadAt: codexThreadsLoadedAt,
                snapshotUpdatedAt: snapshot.updatedAt
            )
        }
    }

    /// The model this session is using, in readable form ("Opus 5.5",
    /// "Astra 6").
    func modelLabel(for snapshot: SessionSnapshot) -> String? {
        rawModel(for: snapshot).map(ModelName.display)
    }

    /// Model / effort / tokens for the row tooltip — the fuller picture
    /// behind the compact label shown in the row. The model appears here as
    /// its RAW id: the row already shows the pretty name, and this is where
    /// you go to tell two dated snapshots apart or to check what the
    /// formatter was handed.
    func metaSummary(for snapshot: SessionSnapshot) -> String? {
        var parts: [String] = []
        if let model = rawModel(for: snapshot) { parts.append(model) }
        if let effort = snapshot.effort { parts.append("effort \(effort)") }
        else if let e = codexThreads[snapshot.sessionId]?.effort { parts.append("effort \(e)") }
        if let tokens = codexThreads[snapshot.sessionId]?.tokensUsed {
            parts.append("\(tokens / 1000)k tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func isUnsupervised(_ snapshot: SessionSnapshot) -> Bool {
        if snapshot.isUnsupervised { return true }
        if snapshot.provider == .codex,
           let thread = codexThreads[snapshot.sessionId] {
            return thread.isUnsupervised
        }
        return false
    }

    /// Where clicking this row should take you: its iTerm pane, or the app
    /// that hosts it (Codex inside ChatGPT.app has no pane but does have an
    /// app), or nowhere.
    func focusTarget(for snapshot: SessionSnapshot) -> FocusTarget {
        FocusResolver.resolve(
            terminalSessionId: snapshot.terminalSessionId ?? paneByControllingTTY(snapshot),
            owningAppBundlePath: owningAppBundle(for: snapshot)
        )
    }

    /// A row discovered from Claude's registry has no recorded pane id —
    /// no hook ever ran to capture ITERM_SESSION_ID. Its agent's
    /// controlling terminal identifies the pane exactly. Not cached: the
    /// lookup is one sysctl, and a cache keyed on pid would outlive it.
    ///
    /// The pid must still be the session's: Claude's registry entry for it,
    /// already checked against the process start time, has to name this
    /// same pid. Otherwise a recycled pid would lead to whatever pane its
    /// new owner happens to run in.
    private func paneByControllingTTY(_ snapshot: SessionSnapshot) -> String? {
        guard snapshot.provider == .claude, let pid = snapshot.agentPid,
              claudeLiveSessions[snapshot.sessionId]?.pid == pid,
              // re-checked now, not at the last reload: the click is the
              // action, and the cached registry view can be seconds old
              ProcessTree.looksLikeAgent(pid, provider: .claude),
              let tty = ProcessTree.controllingTTY(of: pid) else { return nil }
        return paneByTTY[tty]
    }

    /// Walking the process tree per row per render is wasteful; the answer
    /// can't change for a given pid.
    private func owningAppBundle(for snapshot: SessionSnapshot) -> String? {
        guard let pid = snapshot.agentPid else { return nil }
        if let cached = owningAppCache[pid] { return cached }
        let bundle = ProcessTree.owningApplicationBundle(of: pid)
        owningAppCache[pid] = .some(bundle)
        return bundle
    }

    func canFocus(_ snapshot: SessionSnapshot) -> Bool {
        focusTarget(for: snapshot).isActionable
    }

    // MARK: - Actions

    /// Row click: acknowledge, close the popover, then focus the iTerm pane
    /// once the close has actually happened.
    ///
    /// A click only acknowledges when it can actually *take you there*. A
    /// pane is precise; an app or a dead end is not. Acknowledging anyway
    /// would clear the badge for a session still blocked on you and leave
    /// you somewhere else — silently losing the one alert this app exists
    /// to raise. That became the common case once discovery started
    /// surfacing sessions with no recorded pane. Right-click → Dismiss is
    /// still there when you do mean "I've handled it".
    func activate(_ snapshot: SessionSnapshot) {
        let target = focusTarget(for: snapshot)
        // A pane is acknowledged once the focus script reports it reached
        // it, not before: a pane id can be stale (the tab closed, or a
        // tty-matched pane went away), and acknowledging up front cleared
        // a blocked session's badge while leaving you somewhere else.
        let isPane: Bool
        if case .itermPane = target { isPane = true } else { isPane = false }
        if !isPane, !Attention.needsAttention(snapshot, ackedAt: acks[snapshot.key]) {
            acknowledge(snapshot)
        }
        let guid: String
        switch target {
        case .itermPane(let paneGuid):
            guid = paneGuid
        case .application(let bundlePath, let name):
            // Agent hosted by a GUI app (e.g. Codex inside ChatGPT.app):
            // no pane to select, but bringing its app forward is the
            // equivalent "take me there".
            Self.appLog("activate key=\(snapshot.key) app=\(name)")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: bundlePath), configuration: config
            ) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    self?.focusProblem = "Couldn't bring \(name) forward: "
                        + error.localizedDescription
                }
            }
            if popoverVisible { onRequestClose?() }
            return
        case .none:
            focusProblem = isBackgroundSession(snapshot)
                ? "Background session — it has no window. Answer it in the "
                    + "agents panel of the session that started it."
                : "This session isn't in a terminal or app we can focus."
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
                    self.acknowledge(snapshot)
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
            "hooks: helper=\(helperInstalled) claude=\(claudeStatus) codex=\(codexStatus)",
            "claude config dir: \(ClaudeConfig.current.path)",
            "claude policy: hooksBlocked=\(claudePolicy.hooksBlocked) "
                + "refusedModes=\(claudePolicy.refusedPermissionModes.sorted()) "
                + "sources=\(claudePolicy.sources.count)",
            "iTerm installed: \(iTermInstalled)",
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
        // UNUserNotificationCenter.current() raises an uncaught ObjC
        // exception ("bundleProxyForCurrentProcess is nil") when the binary
        // runs outside a .app — e.g. `swift run` or the render harness —
        // which would take the whole process down. The osascript fallback
        // covers that case anyway.
        guard Bundle.main.bundleIdentifier != nil else {
            Self.appLog("no bundle identity; using osascript notifications")
            return
        }
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
        guard !readOnly else { return }
        let minutes = waitAlertMinutes
        guard minutes > 0 else { return }
        // Two-phase: get candidates, apply the ack gate, post, THEN commit only
        // what was posted — so a suppressed post doesn't disarm the episode.
        let candidates = waitingTracker.candidates(
            snapshots, threshold: TimeInterval(minutes * 60)
        )
        var posted: [String] = []
        for key in candidates {
            guard let snapshot = snapshots.first(where: { $0.key == key }) else { continue }
            // A dismissal is "I know, leave me alone" — respect it.
            guard needsAttention(snapshot) else { continue }
            let heading = "\(snapshot.provider.displayName) is waiting on you"
            var body = title(for: snapshot)
            if let reason = waitingReasons[key] { body += " — \(reason)" }
            post(title: heading, body: body, key: key)
            posted.append(key)
            Self.appLog("notified: \(key) waiting > \(minutes)m")
        }
        waitingTracker.commit(posted)
        let memory = waitingTracker.memory()
        if memory != lastSavedWaitingMemory,
           let data = try? JSONEncoder().encode(memory) {
            UserDefaults.standard.set(data, forKey: Self.waitingMemoryKey)
            lastSavedWaitingMemory = memory
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
    private var codexThreadGeneration = 0
    /// When the Codex thread cache was read — see `ModelSource.codex`.
    private var codexThreadsLoadedAt: Date?
    private var claudeModelGeneration = 0
    /// Claude session id → the transcript mtime+size the model came from, so
    /// an unchanged (often multi-megabyte) transcript is never re-read.
    private var claudeModelFingerprints: [String: String] = [:]
    /// Claude session ids a transcript read has been attempted for, whether
    /// or not one was found.
    private var claudeModelsAttempted: Set<String> = []
    private var reloadDebounce: Timer?
    /// pid → owning .app bundle (nil inner value = walked, none found).
    private var owningAppCache: [Int32: String?] = [:]
    /// Cache of installer.isInstalled(provider:) keyed by the config file's
    /// mtime+size — avoids a full JSON parse of settings.json/hooks.json on
    /// every reload (dozens/minute under load).
    private var hookInstallCache: [URL: (mtime: Date, size: Int, installed: Bool)] = [:]
    /// The openGeneration in which a transient footer message became visible,
    /// so it clears one open later rather than before it's ever shown.
    private var messageShownAtGen: Int?

    private func noteMessageChanged() {
        messageShownAtGen = popoverVisible ? openGeneration : nil
    }

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
        claudeHooksInstalled = cachedIsInstalled(
            installer, provider: .claude, in: HookInstaller.defaultClaudeSettingsURL
        )
        codexHooksInstalled = cachedIsInstalled(
            installer, provider: .codex, in: HookInstaller.defaultCodexHooksURL
        )
        iTermRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
        // Policy is a handful of small files; re-read on each health check
        // so an admin change shows without a relaunch.
        let policy = ClaudePolicy.load()
        if policy != claudePolicy { claudePolicy = policy }
        claudeStatus = HookStatus.claude(installed: claudeHooksInstalled, policy: policy)
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        codexStatus = HookStatus.codex(
            installed: codexHooksInstalled,
            codexPresent: FileManager.default.fileExists(atPath: codexHome.path))
        iTermInstalled = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    /// isInstalled parses the whole config file; cache the result until the
    /// file's mtime+size changes.
    private func cachedIsInstalled(
        _ installer: HookInstaller, provider: Provider, in url: URL
    ) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        if let c = hookInstallCache[url], c.mtime == mtime, c.size == size {
            return c.installed
        }
        let installed = installer.isInstalled(provider: provider, in: url)
        hookInstallCache[url] = (mtime, size, installed)
        return installed
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
            let list: ITermFocus.SessionList
            switch outcome {
            case .success(let raw):
                list = ITermFocus.parseSessionList(raw)
                Self.appLog("titles: fetched \(list.names.count) session titles, "
                            + "\(list.guidByTTY.count) ttys")
            case .failure(let err):
                Self.appLog("titles: fetch FAILED: \(err)")
                return  // keep prior titles on failure
            }
            // A SUCCESSFUL empty fetch is authoritative — those sessions are
            // gone — so apply it rather than leaving stale titles/lock icons.
            Task { @MainActor [weak self] in
                guard let self, generation == self.titleFetchGeneration else { return }
                self.terminalTitles = list.names
                self.paneByTTY = list.guidByTTY
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
            self.scheduleReload()  // debounced: hook-write storms coalesce
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatcher = source
    }

    /// Called from the sweep tick: if the watcher ever died (open() failure,
    /// dir vanished), keep trying to re-arm instead of degrading to
    /// 15s-polling forever.
    private func ensureWatching() {
        guard dirWatcher == nil, !readOnly else { return }
        try? FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true
        )
        watchDirectory()
    }

    private func loadAcks() {
        // Run unbundled — the --render-popover harness from .build — the
        // standard defaults are a different, stale domain named after the
        // executable, and renders showed every finished session as
        // unacknowledged. Read the app's own.
        let defaults = Bundle.main.bundleIdentifier == nil
            ? (UserDefaults(suiteName: "com.tonyhoang.agentdeck") ?? .standard)
            : .standard
        guard let stored = defaults.dictionary(forKey: Self.acksDefaultsKey)
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

// MARK: - Workspaces

struct MissingFolder: Identifiable, Equatable {
    var entry: WorkspaceEntry
    /// The named workspace it came from, if any.
    var workspaceID: String?
    /// The same session can be missing from two workspaces; each is its own
    /// repair, saved back to its own workspace.
    var id: String { "\(workspaceID ?? "-")|\(entry.key)" }
}

struct RestoreOffer: Identifiable, Equatable {
    var bootID: String
    var isBeforeRestart: Bool
    var closedAt: Date
    var entries: [WorkspaceEntry]
    var id: String { "\(bootID)-\(closedAt.timeIntervalSince1970)" }

    var title: String {
        let when = closedAt.formatted(
            date: Calendar.current.isDateInToday(closedAt) ? .omitted : .abbreviated,
            time: .shortened)
        return isBeforeRestart ? "Before restart, \(when)" : "Closed \(when)"
    }
}

extension SessionsModel {
    func workspaceEntry(for s: SessionSnapshot, now: Date = Date()) -> WorkspaceEntry? {
        WorkspaceCapture.entry(
            for: s,
            registry: s.provider == .claude ? claudeLiveSessions[s.sessionId] : nil,
            transcriptSessionKind: claudeSessionKinds[s.sessionId],
            codexName: codexNames[s.sessionId],
            terminal: terminalLocation(of: s),
            now: now)
    }

    /// iTerm if a hook recorded a pane or the agent's tty is one of
    /// iTerm's; elsewhere only when iTerm's panes are known and the tty
    /// isn't among them.
    private func terminalLocation(of s: SessionSnapshot) -> WorkspaceCapture.Terminal {
        if s.terminalSessionId != nil { return .iTerm }
        guard !paneByTTY.isEmpty,
              let pid = claudeLiveSessions[s.sessionId]?.pid ?? s.agentPid,
              let tty = ProcessTree.controllingTTY(of: pid) else { return .unknown }
        return paneByTTY[tty] != nil ? .iTerm : .elsewhere
    }

    /// Sessions running by the agents' own evidence: for Claude, its
    /// registry naming a live process for the session; for Codex, which has
    /// no registry, a row whose pid is alive. The one definition used for
    /// capture, offers, open counts and restore preflight. Rows alone
    /// aren't evidence — a pid-less snapshot is kept for a day after its
    /// process is gone — and using them in some places and the registry in
    /// others let a dead session be reported "already open" and skipped.
    func runningKeys(_ rows: [SessionSnapshot]) -> Set<String> {
        var keys = Set(claudeLiveSessions.keys.map { "claude-\($0)" })
        for row in rows where row.provider == .codex {
            if let pid = row.agentPid,
               Liveness.pidIsTrustworthy(pid, forUpdatedAt: row.updatedAt, provider: .codex) {
                keys.insert(row.key)
            }
        }
        return keys
    }

    var liveWorkspaceEntries: [WorkspaceEntry] {
        let now = Date()
        let running = runningKeys(sessions)
        return sessions.filter { running.contains($0.key) }
            .compactMap { workspaceEntry(for: $0, now: now) }
    }

    /// Called on every reload; the store writes only when something changed
    /// or a running session's sighting is a minute stale.
    func recordWorkspaceGeneration(_ rows: [SessionSnapshot]) {
        guard !readOnly, let bootID else { return }
        let now = Date()
        let running = runningKeys(rows)
        let live = rows.filter { running.contains($0.key) }
            .compactMap { workspaceEntry(for: $0, now: now) }
        do {
            if try workspaceStore.record(live: live, bootID: bootID, now: now) {
                refreshWorkspaces()
            }
        } catch {
            Self.appLog("workspace: record FAILED: \(error)")
        }
    }

    /// The current boot's recent closed sets, then each earlier boot's.
    /// Every retained boot stays reachable: offering only the latest meant
    /// that restoring part of a set and rebooting again hid the rest.
    func refreshWorkspaces() {
        let live = runningKeys(sessions)
        var offers: [RestoreOffer] = []
        var banner: RestoreOffer?
        let generations = workspaceStore.generations()
        let ordered = generations.filter { $0.bootID == bootID }
            + generations.filter { $0.bootID != bootID }
        for generation in ordered {
            let finished = generation.bootID != bootID
            func offer(_ set: RestoreSet) -> RestoreOffer {
                .init(bootID: generation.bootID, isBeforeRestart: finished,
                      closedAt: set.closedAt, entries: set.entries)
            }
            offers += generation.restoreSets(live: live, finished: finished).map(offer)
            // The banner picks from every set of the latest earlier boot,
            // not just the few the menu shows.
            if finished, banner == nil {
                banner = generation.restoreSets(live: live, finished: true, limit: .max)
                    .max { $0.entries.count < $1.entries.count }
                    .map(offer)
            }
        }
        if offers != restoreOffers { restoreOffers = offers }
        if banner != bannerOffer { bannerOffer = banner }
        let named = workspaceStore.named()
        if named != namedWorkspaces { namedWorkspaces = named }
    }

    /// The largest set from the most recent earlier boot, offered at the
    /// top of the list until restored or dismissed — once per boot. The
    /// largest, not the newest: a quick session after quitting iTerm and
    /// before rebooting is newer than the thirty that matter.
    var launchRestoreOffer: RestoreOffer? {
        guard UserDefaults.standard.string(forKey: Self.dismissedRestoreOfferKey) != bootID
        else { return nil }
        return bannerOffer
    }

    func dismissLaunchRestoreOffer() {
        UserDefaults.standard.set(bootID, forKey: Self.dismissedRestoreOfferKey)
        objectWillChange.send()
    }

    func openCount(of entries: [WorkspaceEntry]) -> Int {
        let live = runningKeys(sessions)
        return entries.filter { live.contains($0.key) }.count
    }

    /// Running by the agent's own evidence, not by whether a row exists —
    /// a row can outlive its process (a pid-less snapshot is kept a day).
    /// Claude: its registry names a live process for the session. Codex,
    /// which has no registry: a snapshot whose pid is alive.
    nonisolated static func isRunning(_ entry: WorkspaceEntry) -> Bool {
        switch entry.provider {
        case .claude:
            return ClaudeSessionRegistry.liveSessions()[entry.sessionId] != nil
        case .codex:
            if let snapshot = SnapshotStore().load(key: entry.key), let pid = snapshot.agentPid,
               Liveness.pidIsTrustworthy(pid, forUpdatedAt: snapshot.updatedAt, provider: .codex) {
                return true
            }
            // resumed but silent: no hook has fired yet
            return !ProcessTree.codexThreadsRunning([entry.sessionId]).isEmpty
        }
    }

    /// A reservation ends when its session is seen running. Nothing expires
    /// it on a timer: a tab stuck at a trust prompt for an hour is still a
    /// tab that will start this conversation once answered, so launching
    /// it again would make two.
    func releaseConfirmedRestores(_ rows: [SessionSnapshot]) {
        guard !readOnly else { return }
        let reserved = workspaceStore.reservations()
        guard !reserved.isEmpty || !pendingRestores.isEmpty else { return }
        var running = runningKeys(rows)
        // a Codex session resumed by a restore runs no hook until its first
        // message; its process is the evidence. Scanned only while one is
        // reserved, not on every reload.
        let codexReserved = reserved.keys.filter { $0.hasPrefix("codex-") && !running.contains($0) }
        if !codexReserved.isEmpty {
            let ids = Set(codexReserved.map { String($0.dropFirst("codex-".count)) })
            for id in ProcessTree.codexThreadsRunning(ids) { running.insert("codex-\(id)") }
        }
        let confirmed = Set(reserved.keys).intersection(running)
        do {
            try workspaceStore.releaseReservations(confirmed)
        } catch {
            Self.appLog("restore: releasing reservations FAILED: \(error)")
        }
        let pending = reserved.keys.filter { !running.contains($0) }.sorted()
        if pending != pendingRestores { pendingRestores = pending }
    }

    /// The user's say-so that the pending sessions aren't coming: they
    /// checked iTerm. Clears the reservations so they can be restored.
    func clearPendingRestores() {
        do {
            try workspaceStore.releaseReservations(Set(pendingRestores))
        } catch {
            installMessage = "Couldn't clear: \(error.localizedDescription)"
        }
        pendingRestores = []
        refreshWorkspaces()
    }

    /// Labels for the pending keys, from whatever offer or workspace knows them.
    var pendingRestoreLabels: [String] {
        let known = restoreOffers.flatMap(\.entries) + namedWorkspaces.flatMap(\.entries)
        return pendingRestores.map { key in
            known.first { WorkspaceRestore.canonical($0).key == key }?.label ?? key
        }
    }

    func restore(_ entries: [WorkspaceEntry], fromWorkspace workspaceID: String? = nil,
                 dismissesLaunchOffer: Bool = false) {
        guard !readOnly else { return }
        guard !isRestoring else {
            installMessage = "A restore is already running."
            return
        }
        guard iTermInstalled else {
            installMessage = "Restore opens sessions in iTerm2, which isn't installed."
            return
        }
        let threads = codexThreads
        let facts = WorkspaceRestore.Facts(
            live: runningKeys(sessions),
            inFlight: Set(workspaceStore.reservations().keys),
            conversationExists: { entry in
                switch entry.provider {
                case .claude:
                    return ClaudeTranscript.url(
                        sessionId: entry.sessionId, projectPath: entry.cwd) != nil
                case .codex:
                    // the display cache can be stale, so a miss in it is
                    // checked against the database itself
                    if threads[entry.sessionId] != nil { return true }
                    return CodexThreads.exists(id: entry.sessionId)
                }
            },
            refusedPermissionModes: claudePolicy.refusedPermissionModes
        )
        let plan = WorkspaceRestore.plan(entries, facts: facts)
        // each missing folder remembers which named workspace it came from,
        // so locating it later saves into that workspace and no other
        let requested = Set(entries.map { WorkspaceRestore.canonical($0).key })
        missingFolders = missingFolders.filter {
            !(requested.contains($0.entry.key) && $0.workspaceID == workspaceID)
        } + plan.skipped.filter { $0.reason == .missingDirectory }.map {
            MissingFolder(entry: $0.entry, workspaceID: workspaceID)
        }
        for (entry, reason) in plan.skipped {
            Self.appLog("restore: skip \(entry.key) \(reason.phrase)")
        }
        guard !plan.launches.isEmpty else {
            installMessage = plan.skipped.isEmpty
                ? "Nothing to restore."
                : "Nothing to restore. " + WorkspaceRestore.describeSkips(plan.skipped)
            return
        }
        // Reserve before launching, atomically against any other copy of
        // the app: only what this call is granted gets launched.
        let granted: Set<String>
        do {
            granted = try workspaceStore.reserve(plan.launches.map(\.entry.key))
        } catch {
            installMessage = "Couldn't start the restore: \(error.localizedDescription)"
            return
        }
        var skippedAll = plan.skipped
        for launch in plan.launches where !granted.contains(launch.entry.key) {
            skippedAll.append((launch.entry, .alreadyRestoring))
        }
        let launches = plan.launches.filter { granted.contains($0.entry.key) }
        guard !launches.isEmpty else {
            installMessage = "Nothing to restore. " + WorkspaceRestore.describeSkips(skippedAll)
            return
        }
        // bumped only for a restore that launches something, so a no-op
        // click can't silence an earlier restore's confirmation
        restoreGeneration += 1
        isRestoring = true
        let generation = restoreGeneration
        let total = launches.count
        installMessage = "Restoring \(total) session\(total == 1 ? "" : "s")…"
        if popoverVisible { onRequestClose?() }
        let skipped = skippedAll
        // A thread of its own rather than a detached task: the executor
        // sleeps between launches and batches for up to a minute or two,
        // which would park one of the few threads Swift's concurrency pool
        // shares with title fetches and transcript reads.
        let worker = Thread {
            var done = 0
            let outcomes = WorkspaceRestore.execute(
                launches,
                // read fresh, right before each launch: the click may have
                // raced a session coming back some other way
                stillWanted: { !SessionsModel.isRunning($0) },
                // let each batch come up before starting the next, but
                // never wait on it for long: a tab stuck at a prompt
                // mustn't hold up the rest
                awaitBatch: { batch in
                    let deadline = Date().addingTimeInterval(10)
                    while Date() < deadline, !batch.allSatisfy(SessionsModel.isRunning) {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                },
                progress: { entry, outcome in
                    SessionsModel.appLog("restore: \(entry.key) \(outcome)")
                    done += 1
                    let count = done
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.restoreGeneration,
                              self.isRestoring else { return }
                        self.installMessage = "Restoring… \(count) of \(total)"
                    }
                }
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishRestore(launches: launches, outcomes: outcomes, skipped: skipped,
                                    dismissesLaunchOffer: dismissesLaunchOffer,
                                    generation: generation)
            }
        }
        worker.name = "AgentDeck restore"
        worker.start()
    }

    private func finishRestore(
        launches: [WorkspaceRestore.Launch], outcomes: [String: WorkspaceRestore.Outcome],
        skipped: [(entry: WorkspaceEntry, reason: WorkspaceRestore.SkipReason)],
        dismissesLaunchOffer: Bool, generation: Int
    ) {
        isRestoring = false
        let report = RestoreReport(launches: launches, outcomes: outcomes, skipped: skipped)
        do {
            try workspaceStore.releaseReservations(report.release)
        } catch {
            Self.appLog("restore: releasing reservations FAILED: \(error)")
        }
        if dismissesLaunchOffer, !report.typed.isEmpty { dismissLaunchRestoreOffer() }
        installMessage = report.startedMessage
        reload()
        refreshWorkspaces()
        guard !report.typed.isEmpty else { return }
        // "Started" means the text was typed; whether each conversation is
        // actually running is only known once its registry entry appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            Task.detached {
                let notRunning = report.typed.filter { !SessionsModel.isRunning($0) }
                // running, but stopped at a question in its tab
                let live = ClaudeSessionRegistry.liveSessions()
                let awaiting = report.typed.filter { entry in
                    entry.provider == .claude
                        && (live[entry.sessionId]?.waitingFor?.lowercased().contains("dialog") ?? false)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    Self.appLog("restore: \(report.typed.count - notRunning.count)/"
                                + "\(report.typed.count) confirmed running")
                    self.reload()
                    // a newer restore's messages win over this one's
                    guard generation == self.restoreGeneration else { return }
                    self.installMessage = report.confirmationMessage(
                        notRunning: notRunning, awaitingConfirmation: awaiting,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
                }
            }
        }
    }

    /// Picks where a moved project now lives and restores the session
    /// there. Resuming works from any directory — the conversation is
    /// found by id — and the session adopts the folder it's started in.
    func locateFolder(_ missing: MissingFolder) {
        if popoverVisible { onRequestClose?() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let entry = missing.entry
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Restore Here"
            panel.message = "Where is the folder for “\(entry.label)” now? "
                + "It used to be \(entry.cwd)."
            panel.directoryURL = Self.nearestExistingAncestor(of: entry.cwd)
            let response = panel.runModal()
            NSApp.deactivate()
            guard response == .OK, let url = panel.url else { return }
            var moved = entry
            moved.cwd = url.path
            // changed in place under the lock, so another copy's change to
            // the same workspace isn't overwritten
            if let id = missing.workspaceID {
                do {
                    try self.workspaceStore.updateNamed(id: id) { workspace in
                        for i in workspace.entries.indices
                        where WorkspaceRestore.canonical(workspace.entries[i]).key == entry.key {
                            workspace.entries[i].cwd = url.path
                        }
                    }
                } catch {
                    Self.appLog("workspace: relocation save FAILED: \(error)")
                }
            }
            self.restore([moved], fromWorkspace: missing.workspaceID)
        }
    }

    func dismissMissingFolder(_ missing: MissingFolder) {
        missingFolders.removeAll { $0.id == missing.id }
    }

    func dismissMissingFolders() {
        missingFolders = []
    }

    nonisolated static func nearestExistingAncestor(of path: String) -> URL {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) {
            url.deleteLastPathComponent()
        }
        return url
    }

    func promptSaveWorkspace() {
        let entries = liveWorkspaceEntries
        guard !entries.isEmpty else {
            installMessage = "No open sessions to save."
            return
        }
        if popoverVisible { onRequestClose?() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Save \(entries.count) open session\(entries.count == 1 ? "" : "s") as a workspace"
            alert.informativeText = "Restoring it later resumes each conversation in its folder."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "Workspace name"
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            let response = alert.runModal()
            NSApp.deactivate()
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do {
                let saved = try self.workspaceStore.save(
                    NamedWorkspace(name: name, savedAt: Date(), entries: entries))
                self.installMessage = "Saved “\(saved)” (\(entries.count) sessions)."
            } catch {
                self.installMessage = "Couldn't save workspace: \(error.localizedDescription)"
            }
            self.refreshWorkspaces()
        }
    }

    func confirmDeleteWorkspace(_ workspace: NamedWorkspace) {
        if popoverVisible { onRequestClose?() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Delete workspace “\(workspace.name)”?"
            alert.informativeText = "This removes the saved list only. No session is closed."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            NSApp.deactivate()
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self.workspaceStore.deleteNamed(id: workspace.id)
            } catch {
                self.installMessage = "Couldn't delete: \(error.localizedDescription)"
            }
            self.refreshWorkspaces()
        }
    }
}
