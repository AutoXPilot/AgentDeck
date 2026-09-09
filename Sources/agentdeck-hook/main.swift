import AgentDeckCore
import Darwin
import Foundation

// Writing a snapshot after osascript/pipe peers vanish must not kill the
// helper with SIGPIPE — treat a broken pipe as a normal error.
signal(SIGPIPE, SIG_IGN)

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
    let arg0 = CommandLine.arguments[0]
    // Invoked by bare name from PATH, argv[0] has no slash and would resolve
    // against CWD — find the real binary instead.
    if !arg0.contains("/") {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in paths {
            let candidate = "\(dir)/\(arg0)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL
            }
        }
    }
    return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().standardizedFileURL
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
        // productionDirectory, NOT the env-honoring default: the helper
        // inherits the agent's environment and must never let a stray
        // AGENTDECK_STATE_DIR redirect writes away from where the app reads.
        store: SnapshotStore(directory: SnapshotStore.productionDirectory)
    )
    exit(0)
}

func runInstall() {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let me = currentExecutableURL()
        if me != stableHelperURL {
            // Atomic replace (tmp + rename), the same mechanism HelperSync
            // uses — remove-then-copy left a window where hooks execed an
            // absent/half-copied file, and two installs could interleave.
            let changed = try HelperSync.sync(bundled: me, stable: stableHelperURL)
            print("helper: \(changed ? "installed" : "already current") "
                + "at \(stableHelperURL.path)")
        } else {
            print("helper: already running from \(stableHelperURL.path)")
        }
        // A crash between an earlier copy and its rename can strand a
        // .helper-*.tmp here; sweepOrphans only scans the sessions dir.
        if let debris = try? fm.contentsOfDirectory(atPath: binDirectory.path) {
            for name in debris where name.hasPrefix(".helper-") && name.hasSuffix(".tmp") {
                try? fm.removeItem(at: binDirectory.appendingPathComponent(name))
            }
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
    let helperPresent = FileManager.default.isExecutableFile(atPath: stableHelperURL.path)
    let store = SnapshotStore(directory: SnapshotStore.productionDirectory)
    let report: [String: Any] = [
        "version": AgentDeckVersion.current,
        // "present" (on disk + executable), distinct from the app's stricter
        // "matches the running build's SHA" — don't imply the latter here.
        "helperPresent": helperPresent,
        "helperPath": stableHelperURL.path,
        "claudeHooks": installer.isInstalled(
            provider: .claude, in: HookInstaller.defaultClaudeSettingsURL
        ),
        "codexHooks": installer.isInstalled(
            provider: .codex, in: HookInstaller.defaultCodexHooksURL
        ),
        "sessionsDirectory": store.directory.path,
        "activeSessions": store.loadAll().count,
        "bootedAt": Liveness.bootTime().map {
            SnapshotStore.isoFractional.string(from: $0)
        } ?? "unknown",
    ]
    guard let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
    ) else {
        print("{\"version\":\"\(AgentDeckVersion.current)\",\"error\":\"status encode failed\"}")
        return
    }
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
case "--version", "-v", "version": print(AgentDeckVersion.current)
default:
    print("agentdeck-hook \(AgentDeckVersion.current)")
    print("usage: agentdeck-hook claude|codex|install|status|debug-ancestry|--version")
    exit(64)
}
