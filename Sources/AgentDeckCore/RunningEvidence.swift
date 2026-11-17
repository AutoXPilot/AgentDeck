import Foundation

/// Which sessions are running, by each agent's own evidence — never by
/// whether a row exists: a pid-less snapshot is kept for a day after its
/// process is gone, and using rows in some places and the registry in
/// others let a dead session be reported "already open" and skipped.
///
/// The one definition used for capture, restore offers and preflight, the
/// re-check before each launch, the 30-second confirmation, and releasing
/// restore reservations. Each provider says what counts in its
/// `ProviderSpec.running`.
public struct RunningEvidence {
    /// Claude session ids Claude's registry names a live process for.
    public var claudeRegistryLive: Set<String>
    /// Session keys whose presence lock a running process holds
    /// (Antigravity's `presence/<id>.lock`).
    public var presenceLive: Set<String>
    /// Codex session keys whose rollout the shared app-server daemon holds
    /// open: a daemon-run thread records no pid, and its CLI client's
    /// arguments name no thread.
    public var daemonLive: Set<String>
    /// agy's presence locks and who holds them. A pid that now holds a
    /// different conversation's lock has moved on and proves nothing about
    /// the conversation its old snapshot names.
    public var agy: AgyPresence
    /// Whether a snapshot's pid still belongs to its agent.
    public var pidTrusted: (_ pid: Int32, _ updatedAt: Date, _ provider: Provider) -> Bool
    /// Which of these session ids a running agent process of the provider
    /// was started with. Expensive (walks every process), so it is asked
    /// only about keys a caller names.
    public var processScan: (_ provider: Provider, _ ids: Set<String>) -> Set<String>

    public init(
        claudeRegistryLive: Set<String>,
        presenceLive: Set<String> = [],
        daemonLive: Set<String> = [],
        agy: AgyPresence = .unknown,
        pidTrusted: @escaping (Int32, Date, Provider) -> Bool = { pid, updatedAt, provider in
            Liveness.pidIsTrustworthy(pid, forUpdatedAt: updatedAt, provider: provider)
        },
        processScan: @escaping (Provider, Set<String>) -> Set<String> = { provider, ids in
            ProcessTree.sessionsRunning(provider: provider, ids: ids)
        }
    ) {
        self.claudeRegistryLive = claudeRegistryLive
        self.presenceLive = presenceLive
        self.daemonLive = daemonLive
        self.agy = agy
        self.pidTrusted = pidTrusted
        self.processScan = processScan
    }

    /// Running keys among what's known now: registry sessions, plus rows
    /// whose provider trusts a pid and whose pid passes.
    public func runningKeys(rows: [SessionSnapshot]) -> Set<String> {
        var keys = Set<String>()
        for provider in Provider.allCases where provider.spec.running == .claudeRegistry {
            keys.formUnion(claudeRegistryLive.map { SessionKey.make(provider, $0) })
        }
        // only for a provider whose evidence presence is
        keys.formUnion(presenceLive.filter {
            SessionKey.split($0)?.provider.spec.running == .trustworthyPidOrPresence
        })
        keys.formUnion(daemonLive.filter { SessionKey.split($0)?.provider == .codex })
        for row in rows {
            guard row.provider.spec.running.trustsPid, row.pidProvesSession,
                  let pid = row.agentPid, pidTrusted(pid, row.updatedAt, row.provider),
                  !movedOn(row.provider, pid: pid, id: row.sessionId)
            else { continue }
            keys.insert(row.key)
        }
        return keys
    }

    /// `runningKeys`, plus any of `candidates` (session keys) a process scan
    /// finds for providers that allow one. A session resumed by a restore
    /// may run no hook until its first message; its process is the
    /// evidence. Scanned only for the keys asked about.
    public func runningKeys(rows: [SessionSnapshot], scanning candidates: Set<String>) -> Set<String> {
        var running = runningKeys(rows: rows)
        var byProvider: [Provider: Set<String>] = [:]
        for key in candidates where !running.contains(key) {
            guard let (provider, id) = SessionKey.split(key),
                  provider.spec.running == .trustworthyPid(processScan: true) else { continue }
            byProvider[provider, default: []].insert(id)
        }
        for (provider, ids) in byProvider {
            // reserved keys are canonical (lowercased) ids, as the scan's are
            for id in processScan(provider, ids) {
                running.insert(SessionKey.make(provider, id))
            }
        }
        return running
    }

    /// The evidence for one provider, read fresh: only that provider's
    /// source is read (the registry for Claude, presence and lock holders
    /// for agy, the daemon's open rollouts for Codex). Off the main thread.
    public static func reading(
        for provider: Provider,
        claudeLive: () -> Set<String>,
        agy: () -> AgyPresence,
        codexDaemonThreads: () -> Set<String>
    ) -> RunningEvidence {
        switch provider.spec.running {
        case .claudeRegistry:
            return RunningEvidence(claudeRegistryLive: claudeLive())
        case .trustworthyPidOrPresence:
            let presence = agy()
            return RunningEvidence(
                claudeRegistryLive: [],
                presenceLive: Set(presence.held.map { SessionKey.make(provider, $0) }),
                agy: presence)
        case .trustworthyPid:
            let daemon = provider == .codex
                ? Set(codexDaemonThreads().map { SessionKey.make(.codex, $0) }) : []
            return RunningEvidence(claudeRegistryLive: [], daemonLive: daemon)
        }
    }

    /// One entry, read fresh — for the re-check right before a launch and
    /// the confirmation after it. `snapshot` is the entry's current
    /// snapshot, if any.
    public func isRunning(_ entry: WorkspaceEntry, snapshot: SessionSnapshot?) -> Bool {
        switch entry.provider.spec.running {
        case .claudeRegistry:
            return claudeRegistryLive.contains(entry.sessionId)
        case .trustworthyPid(let scan):
            if entry.provider == .codex, daemonLive.contains(entry.key) { return true }
            if let snapshot, let pid = snapshot.agentPid,
               snapshot.pidProvesSession,
               pidTrusted(pid, snapshot.updatedAt, entry.provider) {
                return true
            }
            // resumed but silent: no hook has fired yet
            return scan && !processScan(entry.provider, [entry.sessionId]).isEmpty
        case .trustworthyPidOrPresence:
            if presenceLive.contains(entry.key) { return true }
            if let snapshot, let pid = snapshot.agentPid,
               snapshot.pidProvesSession,
               pidTrusted(pid, snapshot.updatedAt, entry.provider),
               !movedOn(entry.provider, pid: pid, id: entry.sessionId) {
                return true
            }
            return false
        }
    }

    private func movedOn(_ provider: Provider, pid: Int32, id: String) -> Bool {
        provider == .antigravity && agy.movedOn(pid: pid, from: id)
    }
}
