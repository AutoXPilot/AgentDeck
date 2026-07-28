import AgentDeckCore
import Foundation

// agentdeck-hook — invoked by Claude Code / Codex lifecycle hooks.
//
//   agentdeck-hook claude|codex     read hook JSON on stdin, update snapshot
//   agentdeck-hook install          copy self to stable path, register hooks
//   agentdeck-hook status           print install/health report
//   agentdeck-hook debug-ancestry   print the process walk (diagnostics)
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
    // Watchdog: if the CLI never closes stdin we must not hang into the
    // hook timeout (10s) and add latency to the user's turn.
    DispatchQueue.global().asyncAfter(deadline: .now() + 8) { exit(0) }

    var data = Data()
    let maxBytes = 1 << 20  // payloads are ~1KB; anything huge is not for us
    let stdin = FileHandle.standardInput
    while data.count < maxBytes,
          let chunk = try? stdin.read(upToCount: min(65536, maxBytes - data.count)),
          !chunk.isEmpty {
        data.append(chunk)
    }

    HookProcessor.process(
        provider: provider,
        payloadData: data,
        environment: ProcessInfo.processInfo.environment,
        parentPid: getppid(),
        store: SnapshotStore()
    )
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
        print("claude hooks: \(claudeChanged ? "installed/updated" : "already current") "
            + "(\(HookInstaller.defaultClaudeSettingsURL.path))")
        let codexChanged = try installer.installCodex()
        print("codex hooks: \(codexChanged ? "installed/updated" : "already current") "
            + "(\(HookInstaller.defaultCodexHooksURL.path))")
        if codexChanged {
            print("note: codex will ask to trust the changed hooks on next launch")
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
        "claudeHooks": installer.isInstalled(
            provider: .claude, in: HookInstaller.defaultClaudeSettingsURL
        ),
        "codexHooks": installer.isInstalled(
            provider: .codex, in: HookInstaller.defaultCodexHooksURL
        ),
        "sessionsDirectory": SnapshotStore.defaultDirectory.path,
        "activeSessions": SnapshotStore().loadAll().count,
        "bootedAt": Liveness.bootTime().map {
            SnapshotStore.isoFractional.string(from: $0)
        } ?? "unknown",
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
        let path = ProcessTree.executablePath(of: pid) ?? "?"
        print("depth \(depth): pid \(pid) comm '\(name)' path \(path) ppid \(ppid)")
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
    print("usage: agentdeck-hook claude|codex|install|status|debug-ancestry")
    exit(64)
}
