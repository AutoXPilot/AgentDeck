import Foundation
import Testing
@testable import AgentDeckCore

struct ProviderSpecTests {
    @Test func everyProviderHasOneDistinctRow() {
        for provider in Provider.allCases {
            #expect(ProviderSpec.all[provider]?.provider == provider)
        }
        let badges = Provider.allCases.map { $0.spec.badge }
        #expect(Set(badges).count == badges.count)
        let prefixes = Provider.allCases.map { $0.spec.keyPrefix }
        #expect(Set(prefixes).count == prefixes.count)
        // no prefix may be a prefix of another, or keys would split wrong
        for a in prefixes { for b in prefixes where a != b { #expect(!b.hasPrefix(a)) } }
    }

    @Test func todaysValuesAreUnchanged() {
        #expect(Provider.claude.displayName == "Claude")
        #expect(Provider.codex.displayName == "Codex")
        #expect(Provider.claude.spec.badge == "CL" && Provider.codex.spec.badge == "CX")
        #expect(HookInstaller.events(for: .claude) == [
            "SessionStart", "UserPromptSubmit", "PermissionRequest",
            "Notification", "Stop", "StopFailure", "SessionEnd",
        ])
        #expect(HookInstaller.events(for: .codex) == [
            "SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd",
        ])
        #expect(HookInstaller.defaultCodexHooksURL.path.hasSuffix("/.codex/hooks.json"))
        #expect(HookInstaller.defaultClaudeSettingsURL.lastPathComponent == "settings.json")
        #expect(Provider.claude.spec.applicability == .always)
    }

    @Test func sessionKeysRoundTrip() {
        let id = "d047f956-a5ed-4248-8938-92685f0da7f7"
        for provider in Provider.allCases {
            let key = SessionKey.make(provider, id)
            #expect(SessionKey.split(key)?.provider == provider)
            #expect(SessionKey.split(key)?.sessionId == id)
        }
        #expect(SessionKey.make(.claude, "s") == "claude-s")
        #expect(SessionKey.split("zzz-abc") == nil, "a provider this build doesn't know")
        #expect(SessionKey.split("claude-") == nil)
        let snap = SessionSnapshot(provider: .codex, sessionId: "x", projectPath: "/",
                                   state: .ready, event: "e")
        #expect(snap.key == "codex-x")
    }

    @Test func claudeMatchingIsExactlyAsBefore() {
        let m = ExecutableMatch.claude
        // versioned binary: p_comm is the version, the path says claude
        #expect(m.matchesAncestor(name: "2.1.220",
                                  path: "/Users/x/.local/share/claude/versions/2.1.220", depth: 1))
        #expect(m.looksLikeAgent(name: "2.1.220",
                                 path: "/Users/x/.local/share/claude/versions/2.1.220",
                                 argvMentions: { _ in false }))
        // deleted binary: ProcessTree falls back to argv[0], still a claude path
        #expect(m.looksLikeAgent(name: "2.1.200",
                                 path: "/Users/x/.local/share/claude/versions/2.1.200",
                                 argvMentions: { _ in false }))
        // node/bun wrapper: above the hook's own shell only
        #expect(!m.matchesAncestor(name: "node", path: "/usr/local/bin/node", depth: 0))
        #expect(m.matchesAncestor(name: "node", path: "/usr/local/bin/node", depth: 1))
        #expect(m.matchesAncestor(name: "bun", path: nil, depth: 2))
        // for liveness, a node runtime counts only if it runs Claude
        #expect(!m.looksLikeAgent(name: "node", path: "/usr/local/bin/node",
                                  argvMentions: { _ in false }))
        #expect(m.looksLikeAgent(name: "node", path: "/usr/local/bin/node",
                                 argvMentions: { $0 == "claude" }))
        #expect(!m.looksLikeAgent(name: "zsh", path: "/bin/zsh", argvMentions: { _ in true }))
    }

    @Test func codexMatchesByNameOrPath() {
        let m = ExecutableMatch.codex
        #expect(m.matchesAncestor(name: "codex", path: nil, depth: 0))
        #expect(m.looksLikeAgent(name: "x", path: "/opt/homebrew/bin/codex",
                                 argvMentions: { _ in false }))
        #expect(!m.looksLikeAgent(name: "node", path: "/usr/local/bin/node",
                                  argvMentions: { _ in true }))
    }

    @Test func antigravityIsMatchedByExactNameAndNeverAsItsUpdater() {
        let m = Provider.antigravity.spec.executableMatch
        let path = "/Users/x/.local/bin/agy"
        #expect(m.matchesAncestor(name: "agy", path: path, depth: 0,
                                  argvMentions: { _ in false }))
        #expect(m.looksLikeAgent(name: "agy", path: path, argvMentions: { _ in false }))
        // `agy --bg-updater …` is a child with the same name and path
        let updater: (String) -> Bool = { $0 == "--bg-updater" }
        #expect(!m.matchesAncestor(name: "agy", path: path, depth: 0, argvMentions: updater))
        #expect(!m.looksLikeAgent(name: "agy", path: path, argvMentions: updater))
        for path in ["/usr/bin/strategy", "/Users/x/bin/agyx", "/opt/agy-tools/foo"] {
            let name = (path as NSString).lastPathComponent
            #expect(!m.looksLikeAgent(name: name, path: path, argvMentions: { _ in false }))
            #expect(!m.matchesAncestor(name: name, path: path, depth: 1))
        }
    }

    @Test func antigravitysRow() {
        let spec = Provider.antigravity.spec
        #expect(spec.badge == "AG" && spec.displayName == "Antigravity")
        #expect(spec.eventNameOnArgv && spec.sessionIdIsUUID && !spec.stopUpdatesOnly)
        #expect(spec.running == .trustworthyPidOrPresence)
        #expect(spec.applicability == .requiresHomeDirectory(".gemini/antigravity-cli"))
        #expect(spec.hooks?.format == .antigravityHookSets)
        #expect(spec.hooks?.fileURL().path.hasSuffix("/.gemini/config/hooks.json") == true)
        #expect(HookInstaller.events(for: .antigravity) == [
            "SessionStart", "PreInvocation", "PostInvocation", "Stop", "PreToolUse", "PostToolUse",
        ])
        #expect(spec.hooks?.matchers == ["PreToolUse": "ask_question", "PostToolUse": "ask_question"])
    }

    @Test func anExactBasenameRuleRejectsLookalikes() {
        let m = ExecutableMatch.exactBasename("agy")
        #expect(m.looksLikeAgent(name: "agy", path: "/Users/x/.local/bin/agy",
                                 argvMentions: { _ in false }))
        #expect(m.matchesAncestor(name: "agy", path: "/Users/x/.local/bin/agy", depth: 0))
        for path in ["/usr/bin/strategy", "/Users/x/bin/agyx", "/opt/agy-tools/foo"] {
            let name = (path as NSString).lastPathComponent
            #expect(!m.looksLikeAgent(name: name, path: path, argvMentions: { _ in true }))
            #expect(!m.matchesAncestor(name: name, path: path, depth: 3))
        }
    }

    @Test func resumeCommandsAreUnchanged() {
        let id = "D047F956-A5ED-4248-8938-92685F0DA7F7"
        let claude = WorkspaceEntry(provider: .claude, sessionId: id, cwd: "/tmp/a b",
                                    permissionMode: "plan", lastSeen: .distantPast)
        #expect(WorkspaceRestore.commandLine(for: claude)
                == "cd -- '/tmp/a b' && command claude --resume d047f956-a5ed-4248-8938-92685f0da7f7 --permission-mode plan")
        let codex = WorkspaceEntry(provider: .codex, sessionId: id, cwd: "/tmp",
                                   permissionMode: "plan", lastSeen: .distantPast)
        #expect(WorkspaceRestore.commandLine(for: codex)
                == "cd -- '/tmp' && command codex resume d047f956-a5ed-4248-8938-92685f0da7f7")
    }

    /// `command` makes the shell run the real executable: an alias or
    /// function named `claude`/`codex`/`agy` can't rewrite a restore (agy is
    /// commonly aliased to add --dangerously-skip-permissions).
    @Test func everyRestoreLineRunsTheRealExecutable() throws {
        let id = "D047F956-A5ED-4248-8938-92685F0DA7F7"
        let expected: [Provider: String] = [
            .claude: "command claude --resume ", .codex: "command codex resume ",
            .antigravity: "command agy --conversation ",
        ]
        for provider in Provider.allCases {
            let entry = WorkspaceEntry(provider: provider, sessionId: id, cwd: "/tmp",
                                       permissionMode: "bypassPermissions", lastSeen: .distantPast)
            let line = WorkspaceRestore.commandLine(for: entry)
            let want = try #require(expected[provider], "every provider has a pinned line")
            #expect(line?.hasPrefix("cd -- '/tmp' && " + want) == true, "\(line ?? "nil")")
        }
        // agy: no mode flags at all — hooks record none
        let agy = WorkspaceEntry(provider: .antigravity, sessionId: id, cwd: "/tmp",
                                 permissionMode: "bypassPermissions", lastSeen: .distantPast)
        #expect(WorkspaceRestore.commandLine(for: agy)
                == "cd -- '/tmp' && command agy --conversation d047f956-a5ed-4248-8938-92685f0da7f7")
        let named = WorkspaceEntry(provider: .antigravity, sessionId: "my-chat", cwd: "/tmp",
                                   lastSeen: .distantPast)
        #expect(WorkspaceRestore.commandLine(for: named) == nil, "a non-UUID id is refused")
    }

    @Test func theInstallPlanSkipsWhatDoesNotApplyAndContinuesPastPolicy() {
        var blocked = ClaudePolicy()
        blocked.hooksBlocked = true
        let plan = HookInstaller.installPlan(applicable: { $0 == .claude }, policy: blocked)
        #expect(plan.map(\.provider) == [.claude, .codex, .antigravity])
        #expect(plan.map(\.step) == [.skipBlockedByPolicy, .skipNotApplicable, .skipNotApplicable])
        let open = HookInstaller.installPlan(applicable: { _ in true }, policy: .none)
        #expect(open.map(\.step) == [.install, .install, .install])
        // a managed Mac with agy set up still gets agy's hooks
        let agyOnly = HookInstaller.installPlan(applicable: { _ in true }, policy: blocked)
        #expect(agyOnly.map(\.step) == [.skipBlockedByPolicy, .install, .install])
    }

    @Test func statusTableMatchesTheOldPerProviderRules() {
        var blocked = ClaudePolicy()
        blocked.hooksBlocked = true
        // policy governs Claude only
        #expect(HookStatus.status(for: .codex, installed: true, policy: blocked, applicable: true)
                == .installed)
        #expect(HookStatus.status(for: .codex, installed: false, policy: blocked, applicable: true)
                == .missing)
        #expect(HookStatus.status(for: .claude, installed: false, policy: blocked, applicable: true)
                == .blockedByPolicy)
    }
}

struct RunningEvidenceTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func row(_ provider: Provider, _ id: String, pid: Int32?) -> SessionSnapshot {
        SessionSnapshot(provider: provider, sessionId: id, projectPath: "/", state: .ready,
                        event: "e", updatedAt: now, agentPid: pid)
    }

    @Test func eachProviderUsesItsOwnEvidence() {
        let evidence = RunningEvidence(
            claudeRegistryLive: ["c1"],
            pidTrusted: { pid, _, _ in pid == 100 },
            processScan: { _, _ in Issue.record("no scan without candidates"); return [] })
        let keys = evidence.runningKeys(rows: [
            row(.claude, "c2", pid: 100),   // live pid, but the registry doesn't name it
            row(.codex, "x1", pid: 100),    // trusted pid
            row(.codex, "x2", pid: 200),    // dead pid
            row(.codex, "x3", pid: nil),
        ])
        #expect(keys == ["claude-c1", "codex-x1"])
    }

    @Test func onlyScanningProvidersAreScannedAndOnlyForTheKeysAsked() {
        var asked: [Provider: Set<String>] = [:]
        let evidence = RunningEvidence(
            claudeRegistryLive: [],
            pidTrusted: { _, _, _ in false },
            processScan: { provider, ids in
                asked[provider, default: []].formUnion(ids)
                return ids.filter { $0 == "r1" }
            })
        let keys = evidence.runningKeys(
            rows: [], scanning: ["codex-r1", "codex-r2", "claude-c9", "zzz-q"])
        #expect(keys == ["codex-r1"])
        #expect(asked == [.codex: ["r1", "r2"]], "Claude is never scanned; unknown keys ignored")
    }

    @Test func oneEntryIsCheckedByItsProvidersEvidence() {
        let evidence = RunningEvidence(
            claudeRegistryLive: ["c1"],
            pidTrusted: { pid, _, _ in pid == 100 },
            processScan: { _, ids in ids.contains("silent") ? ["silent"] : [] })
        func entry(_ p: Provider, _ id: String) -> WorkspaceEntry {
            WorkspaceEntry(provider: p, sessionId: id, cwd: "/", lastSeen: now)
        }
        #expect(evidence.isRunning(entry(.claude, "c1"), snapshot: nil))
        #expect(!evidence.isRunning(entry(.claude, "c2"), snapshot: row(.claude, "c2", pid: 100)))
        #expect(evidence.isRunning(entry(.codex, "x"), snapshot: row(.codex, "x", pid: 100)))
        #expect(evidence.isRunning(entry(.codex, "silent"), snapshot: nil))
        #expect(!evidence.isRunning(entry(.codex, "gone"), snapshot: row(.codex, "gone", pid: 5)))
    }
}

struct RowMetaTests {
    @Test func aClaudeRowNeverShowsACodexThreadsFigures() {
        let thread = CodexThread(id: "same", model: "gpt", effort: "xhigh", tokensUsed: 52_000)
        #expect(RowMeta.summary(provider: .claude, model: "claude-opus", effort: nil,
                                codexThread: thread) == "claude-opus")
        #expect(RowMeta.summary(provider: .codex, model: "gpt", effort: nil,
                                codexThread: thread) == "gpt · effort xhigh · 52k tokens")
        #expect(RowMeta.summary(provider: .codex, model: nil, effort: "low",
                                codexThread: thread) == "effort low · 52k tokens")
        #expect(RowMeta.summary(provider: .claude, model: nil, effort: nil, codexThread: nil) == nil)
    }
}
