import AgentDeckCore
import Foundation

// agentdeck-hook — invoked by Claude Code / Codex lifecycle hooks.
//
//   agentdeck-hook claude|codex     read hook JSON on stdin, update snapshot
//   agentdeck-hook install          copy self to stable path, register hooks
//   agentdeck-hook status           print install/health report
//
// Hook mode must NEVER fail loudly or block the agent: exit 0 always,
// no stdout (Claude interprets hook stdout).

let binDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AgentDeck/bin", isDirectory: true)
let stableHelperURL = binDirectory.appendingPathComponent("agentdeck-hook")

func currentExecutableURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .standardizedFileURL
}

func runHookMode(provider: Provider) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let event = payload["hook_event_name"] as? String,
          let sessionId = payload["session_id"] as? String,
          !sessionId.isEmpty
    else { exit(0) }

    let notificationType =
        payload["notification_type"] as? String ?? payload["type"] as? String
    let action = EventMapping.action(
        provider: provider, event: event, notificationType: notificationType
    )

    let store = SnapshotStore()
    let key = "\(provider.rawValue)-\(sessionId)"
    switch action {
    case .ignore:
        break
    case .remove:
        store.remove(key: key)
    case .set(let state):
        let existing = store.load(key: key)
        let env = ProcessInfo.processInfo.environment
        let terminal = env["ITERM_SESSION_ID"] ?? existing?.terminalSessionId
        let cwd = (payload["cwd"] as? String) ?? existing?.projectPath ?? ""
        let pid = ProcessTree.findAgentAncestor(provider: provider, startingAt: getppid())
            ?? existing?.agentPid
        let snapshot = SessionSnapshot(
            provider: provider,
            sessionId: sessionId,
            projectPath: cwd,
            state: state,
            event: event,
            updatedAt: Date(),
            terminalSessionId: terminal,
            agentPid: pid
        )
        try? store.write(snapshot)
    }
    exit(0)
}

func runInstall() {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let me = currentExecutableURL()
        if me != stableHelperURL {
            if fm.fileExists(atPath: stableHelperURL.path) {
                try fm.removeItem(at: stableHelperURL)
            }
            try fm.copyItem(at: me, to: stableHelperURL)
            print("helper: installed at \(stableHelperURL.path)")
        } else {
            print("helper: already running from \(stableHelperURL.path)")
        }

        let installer = HookInstaller(helperPath: stableHelperURL.path)
        let claudeChanged = try installer.installClaude()
        print("claude hooks: \(claudeChanged ? "installed" : "already present") "
            + "(\(HookInstaller.defaultClaudeSettingsURL.path))")
        let codexChanged = try installer.installCodex()
        print("codex hooks: \(codexChanged ? "installed" : "already present") "
            + "(\(HookInstaller.defaultCodexHooksURL.path))")
        if codexChanged {
            print("note: codex requires trusting the new hook — it will prompt on next launch")
        }
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        exit(1)
    }
}

func runStatus() {
    let installer = HookInstaller(helperPath: stableHelperURL.path)
    let helperOK = FileManager.default.isExecutableFile(atPath: stableHelperURL.path)
    let report: [String: Any] = [
        "helperInstalled": helperOK,
        "helperPath": stableHelperURL.path,
        "claudeHooks": installer.isInstalled(in: HookInstaller.defaultClaudeSettingsURL),
        "codexHooks": installer.isInstalled(in: HookInstaller.defaultCodexHooksURL),
        "sessionsDirectory": SnapshotStore.defaultDirectory.path,
        "activeSessions": SnapshotStore().loadAll().count,
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
    )
    print(String(decoding: data, as: UTF8.self))
}

func runDebugAncestry() {
    var pid = getppid()
    for depth in 0..<12 {
        guard let (name, ppid) = ProcessTree.nameAndParent(of: pid) else {
            print("depth \(depth): pid \(pid) — sysctl failed")
            break
        }
        print("depth \(depth): pid \(pid) comm '\(name)' ppid \(ppid)")
        if ppid <= 1 { break }
        pid = ppid
    }
    for provider in Provider.allCases {
        let found = ProcessTree.findAgentAncestor(provider: provider, startingAt: getppid())
        print("\(provider.rawValue) ancestor: \(found.map(String.init) ?? "nil")")
    }
}

switch CommandLine.arguments.dropFirst().first {
case "claude": runHookMode(provider: .claude)
case "codex": runHookMode(provider: .codex)
case "install": runInstall()
case "status": runStatus()
case "debug-ancestry": runDebugAncestry()
default:
    print("usage: agentdeck-hook claude|codex|install|status")
    exit(64)
}
