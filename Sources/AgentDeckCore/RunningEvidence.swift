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
    /// Whether a snapshot's pid still belongs to its agent.
    public var pidTrusted: (_ pid: Int32, _ updatedAt: Date, _ provider: Provider) -> Bool
    /// Which of these session ids a running agent process of the provider
    /// was started with. Expensive (walks every process), so it is asked
    /// only about keys a caller names.
    public var processScan: (_ provider: Provider, _ ids: Set<String>) -> Set<String>

    public init(
        claudeRegistryLive: Set<String>,
        pidTrusted: @escaping (Int32, Date, Provider) -> Bool = { pid, updatedAt, provider in
            Liveness.pidIsTrustworthy(pid, forUpdatedAt: updatedAt, provider: provider)
        },
        processScan: @escaping (Provider, Set<String>) -> Set<String> = { provider, ids in
            ProcessTree.sessionsRunning(provider: provider, ids: ids)
        }
    ) {
        self.claudeRegistryLive = claudeRegistryLive
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
        for row in rows {
            guard case .trustworthyPid = row.provider.spec.running,
                  let pid = row.agentPid, pidTrusted(pid, row.updatedAt, row.provider)
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

    /// One entry, read fresh — for the re-check right before a launch and
    /// the confirmation after it. `snapshot` is the entry's current
    /// snapshot, if any.
    public func isRunning(_ entry: WorkspaceEntry, snapshot: SessionSnapshot?) -> Bool {
        switch entry.provider.spec.running {
        case .claudeRegistry:
            return claudeRegistryLive.contains(entry.sessionId)
        case .trustworthyPid(let scan):
            if let snapshot, let pid = snapshot.agentPid,
               pidTrusted(pid, snapshot.updatedAt, entry.provider) {
                return true
            }
            // resumed but silent: no hook has fired yet
            return scan && !processScan(entry.provider, [entry.sessionId]).isEmpty
        }
    }
}
