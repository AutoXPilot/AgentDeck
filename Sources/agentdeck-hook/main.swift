import AgentDeckCore
import Darwin
import Foundation

// Writing a snapshot after osascript/pipe peers vanish must not kill the
// helper with SIGPIPE — treat a broken pipe as a normal error.
signal(SIGPIPE, SIG_IGN)

// agentdeck-hook — invoked by Claude Code / Codex / Antigravity hooks.
//
//   agentdeck-hook <provider>      read hook JSON on stdin, update snapshot
//                                  (claude, codex — see Provider)
//   agentdeck-hook antigravity <Event>
//                                  the same, with the event on argv (agy's
//                                  payload doesn't name it)
//   agentdeck-hook install          copy self to stable path, register hooks
//   agentdeck-hook status           print install/health report
//   agentdeck-hook debug-ancestry   print the process walk (diagnostics)
//   agentdeck-hook debug-usage      print the usage figures AgentDeck sees
//   agentdeck-hook debug-codex      daemon-run Codex threads and Codex CLI terminals
//   agentdeck-hook statusline <claude|antigravity> <record>
//                                   the status line tee (see StatusLineTee)
//   agentdeck-hook statusline-install|statusline-uninstall <claude|antigravity|all>
//   agentdeck-hook statusline-status
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
        // `<helper> <provider> <Event>`, for a provider whose payload
        // doesn't name the event
        argvEvent: CommandLine.arguments.dropFirst(2).first,
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
            let decision = HelperSync.decision(
                bundled: me, bundledVersion: AgentDeckVersion.current, stable: stableHelperURL)
            if decision == .keepNewer {
                print("helper: kept the newer helper already at \(stableHelperURL.path) "
                    + "(this is \(AgentDeckVersion.current))")
            } else {
                let changed = try HelperSync.sync(bundled: me, stable: stableHelperURL)
                print("helper: \(changed ? "installed" : "already current") "
                    + "at \(stableHelperURL.path)")
            }
        } else {
            print("helper: already running from \(stableHelperURL.path)")
        }
        // A crash between an earlier copy and its rename can strand a
        // .helper-*.tmp here; sweepOrphans only scans the sessions dir.
        HelperSync.removeStrandedTemps(in: binDirectory)

        let installer = HookInstaller(helperPath: stableHelperURL.path)
        let plan = HookInstaller.installPlan(
            applicable: { $0.spec.applicability.isApplicable() }, policy: ClaudePolicy.load())
        for (provider, step) in plan {
            let name = provider.rawValue
            let url = HookInstaller.configURL(for: provider)!
            switch step {
            case .skipNotApplicable:
                print("\(name) hooks: skipped — \(provider.displayName) isn't set up on this Mac "
                    + "(no \(url.deletingLastPathComponent().path))")
            case .skipBlockedByPolicy:
                // not a failure: sessions still come from Claude's session list
                print("\(name) hooks: skipped — \(InstallerError.blockedByPolicy)")
            case .install:
                let changed = try installer.install(provider)
                print("\(name) hooks: \(changed ? "installed/updated" : "already current") "
                    + "(\(url.path))")
                if changed, let note = provider.spec.hooks?.installNote {
                    print("note: \(note)")
                }
            }
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
    var installed: [String: Bool] = [:]
    for provider in Provider.allCases {
        guard let url = HookInstaller.configURL(for: provider) else { continue }
        installed[provider.rawValue] = installer.isInstalled(provider: provider, in: url)
    }
    let report: [String: Any] = [
        "version": AgentDeckVersion.current,
        // "present" (on disk + executable), distinct from the app's stricter
        // "matches the running build's SHA" — don't imply the latter here.
        "helperPresent": helperPresent,
        "helperPath": stableHelperURL.path,
        // kept for one release beside `hooks`, for scripts that read them
        "claudeHooks": installed[Provider.claude.rawValue] ?? false,
        "codexHooks": installed[Provider.codex.rawValue] ?? false,
        "hooks": installed,
        "sessionsDirectory": store.directory.path,
        "claudeConfigDirectory": ClaudeConfig.current.path,
        "claudeHooksBlockedByPolicy": ClaudePolicy.load().hooksBlocked,
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

/// Usage figures only (allow-listed fields), as the app would show them.
func runDebugUsage() {
    var found: [ProviderUsage] = []
    if let codex = CodexUsage.Reader().load() { found.append(codex) }
    let store = UsageStore()
    found += store.loadAll(.claude)
    if let agy = store.load(.antigravity) { found.append(agy) }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(found) { print(String(decoding: data, as: UTF8.self)) }
}

/// The status line tee: record the usage figures, then run the user's own
/// status line command behind it. Unlike hook mode this prints: whatever
/// the chained command prints is the status line. A capture failure never
/// stops the chained command from running.
func runStatusLineTee(arguments: [String]) -> Never {
    guard arguments.count >= 2, let provider = Provider(rawValue: arguments[0]),
          StatusLineTee.providers.contains(provider)
    else { exit(0) }
    let recordName = arguments[1]
    // read once before any handler can: a lazily initialised static isn't
    // safe to touch for the first time inside a signal handler
    _ = ChainRunner.activeGroup
    // Claude cancels a superseded run; take the chained command with us
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { received in
            let group = ChainRunner.activeGroup
            if group > 0 { kill(-group, SIGKILL) }
            _exit(128 + received)
        }
    }
    // A stdin that never closes must not leave the tee hanging: the
    // chained command has 5 s of its own, so 15 s covers the whole run.
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
        let group = ChainRunner.activeGroup
        if group > 0 { kill(-group, SIGKILL) }
        _exit(0)
    }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let tee = StatusLineTee(helperPath: stableHelperURL.path)
    // the tee runs in Claude's own environment, so CLAUDE_CONFIG_DIR here
    // is the one this session uses
    let result = tee.run(
        provider: provider, recordName: recordName, input: input,
        store: UsageStore(directory: UsageStore.productionDirectory),
        claudeAccount: { ClaudeAccount.current(configDirectory: ClaudeConfig.directory(policy: .load())) })
    guard let result else { exit(0) }
    FileHandle.standardOutput.write(result.stdout)
    exit(result.status)
}

func teeProviders(_ argument: String?) -> [Provider]? {
    switch argument {
    case "all": return StatusLineTee.providers
    case let name?:
        guard let provider = Provider(rawValue: name), StatusLineTee.providers.contains(provider)
        else { return nil }
        return [provider]
    case nil: return nil
    }
}

/// The stable helper must run, and understand `statusline`, before a
/// settings file points at it: the status line runs only the helper, and
/// the user's own command runs behind it. nil = ready, else why not.
func stableHelperStatusLineProblem() -> String? {
    let path = stableHelperURL.path
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return "the helper at \(path) is missing; run `agentdeck-hook install` first"
    }
    let process = Process()
    process.executableURL = stableHelperURL
    process.arguments = ["statusline-supported"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        return "this Mac won't run the helper at \(path) (\(error.localizedDescription)); "
            + "if it's managed, its security settings may block unsigned tools, and your status "
            + "line would stop with it — nothing was changed"
    }
    // a helper stalled at launch is the case this probe exists for
    if exited.wait(timeout: .now() + 10) == .timedOut {
        process.terminate()
        _ = exited.wait(timeout: .now() + 2)
        return "the helper at \(path) didn't answer within 10 seconds; a security tool may be "
            + "holding it, and your status line would stop with it — nothing was changed"
    }
    if process.terminationReason == .uncaughtSignal {
        return "the helper at \(path) was stopped by signal \(process.terminationStatus) "
            + "when started; a security tool may be blocking it, and your status line would "
            + "stop with it — nothing was changed"
    }
    guard process.terminationStatus == 0 else {
        return "the helper at \(path) is too old for this; run `agentdeck-hook install` first"
    }
    return nil
}

func runStatusLineInstall(_ argument: String?) -> Never {
    guard let providers = teeProviders(argument) else {
        print("usage: agentdeck-hook statusline-install <claude|antigravity|all>")
        exit(64)
    }
    if let problem = stableHelperStatusLineProblem() {
        print(problem)
        exit(1)
    }
    let tee = StatusLineTee(helperPath: stableHelperURL.path)
    var failed = false
    for provider in providers {
        let name = provider.spec.displayName
        switch tee.status(for: provider) {
        case .notApplicable:
            print("\(name): not set up on this Mac — skipped")
            continue
        case .blockedByPolicy, .overriddenByPolicy:
            print("\(name): \(StatusLineTee.TeeError.blockedByPolicy)")
            continue
        default: break
        }
        do {
            let changed = try tee.install(provider)
            print("\(name): status line tee \(changed ? "installed" : "already installed")")
        } catch {
            print("\(name): \(error)")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}

func runStatusLineUninstall(_ argument: String?) -> Never {
    guard let providers = teeProviders(argument) else {
        print("usage: agentdeck-hook statusline-uninstall <claude|antigravity|all>")
        exit(64)
    }
    let tee = StatusLineTee(helperPath: stableHelperURL.path)
    let report = tee.uninstallReport(providers, store: UsageStore(directory: UsageStore.productionDirectory))
    report.lines.forEach { print($0) }
    exit(report.failed ? 1 : 0)
}

func runStatusLineStatus() -> Never {
    let tee = StatusLineTee(helperPath: stableHelperURL.path)
    for provider in StatusLineTee.providers {
        print("\(provider.rawValue): \(tee.status(for: provider))")
    }
    exit(0)
}

let providerNames = Provider.allCases.map(\.rawValue).joined(separator: "|")
let command = CommandLine.arguments.dropFirst().first
if let command, let provider = Provider(rawValue: command) {
    runHookMode(provider: provider)
}
switch command {
case "install": runInstall()
case "status": runStatus()
case "debug-ancestry": runDebugAncestry()
case "debug-usage": runDebugUsage()
case "debug-codex":
    // which Codex threads the shared daemon runs (ids only), and how long the scan takes
    let start = Date()
    let ids = ProcessTree.codexDaemonOpenThreads()
    print("daemon threads: \(ids.sorted()) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    print("codex CLI ttys: \(ProcessTree.codexCLITTYs().sorted())")
case "statusline": runStatusLineTee(arguments: Array(CommandLine.arguments.dropFirst(2)))
case "statusline-supported": exit(0)
case "statusline-install": runStatusLineInstall(CommandLine.arguments.dropFirst(2).first)
case "statusline-uninstall": runStatusLineUninstall(CommandLine.arguments.dropFirst(2).first)
case "statusline-status": runStatusLineStatus()
case "--version", "-v", "version": print(AgentDeckVersion.current)
default:
    print("agentdeck-hook \(AgentDeckVersion.current)")
    print("usage: agentdeck-hook \(providerNames)|install|status|debug-ancestry|debug-usage|debug-codex|statusline-install|statusline-uninstall|statusline-status|--version")
    exit(64)
}
