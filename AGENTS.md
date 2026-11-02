# AgentDeck — guide for coding agents

Read this before changing anything. It is the map; README.md is for users,
CONTRIBUTING.md holds the rules each past bug taught, CHANGELOG.md is the
history. Keep this file current when you change how something works.

## What it is

A macOS menu-bar app (Swift 6, SwiftPM, macOS 14+) that lists every running
AI coding-agent session on the Mac, shows which are blocked on the user, jumps
to the session on click, and can bring sessions back after a reboot or an
iTerm quit. Single user, local only: nothing leaves the machine.

Sources it understands:

| Source | How it's seen | Badge |
|---|---|---|
| Claude Code CLI | lifecycle hooks in `~/.claude/settings.json` **and** Claude's own registry `~/.claude/sessions/<pid>.json` (hookless discovery) | CL |
| Codex CLI | hooks in `~/.codex/hooks.json`; `~/.codex/state_5.sqlite` (read-only) for model/effort/tokens | CX |
| Antigravity CLI (`agy`) | hook set `agentdeck` in `~/.gemini/config/hooks.json`; held `flock` on `~/.gemini/antigravity-cli/presence/<id>.lock` (hookless discovery) | AG |
| Claude Code in Claude Desktop | same as Claude CLI; host = `/Applications/Claude.app` | CL + "Desktop" |
| Codex in ChatGPT.app | same Codex hooks fire; host = `/Applications/ChatGPT.app` | CX |

Not covered: Cowork (runs in Desktop's VM, invisible to the host), any
cloud/remote session.

## Layout

```
Sources/AgentDeckCore/   all logic, pure where possible, fully tested
Sources/agentdeck-hook/  the helper the hooks run (tiny; delegates to core)
Sources/AgentDeck/       AppKit/SwiftUI app — thin glue, NO tests
Tests/AgentDeckCoreTests/  Swift Testing (`@Test`, `#expect`)
scripts/make-app-bundle.sh  builds AgentDeck.app, ad-hoc signs with a stable id
packaging/agentdeck.rb   Homebrew formula (HEAD build) — source of truth for the tap
.github/workflows/       ci.yml (build+test on push), release.yml (on tag v*)
```

**The rule that shaped the codebase:** every escaped bug lived in the
untested app target. Put decisions in AgentDeckCore as pure functions with
inputs, test them there, and keep `SessionsModel` to reading files, calling
core, assigning outputs and side effects.

## Data flow

```
agent hook ──> '<helper>' <provider> [Event] (JSON on stdin)
   agentdeck-hook: HookPayload.parse → HookProcessor.apply (per-key flock)
      └─> ~/Library/Application Support/AgentDeck/sessions/<provider>-<id>.json
AgentDeck.app: dir watcher (250 ms debounce) + 15 s sweep
   reload(): load snapshots + Claude registry + agy presence
             → Liveness.keysToRemove (delete under the same lock)
             → SessionPipeline.run  (normalize → reconcile → discover → dedupe → sort → counts)
             → UI, notifications (WaitingTracker), workspace capture (WorkspaceStore.record)
```

The helper must never block an agent turn: bounded stdin read, 8 s watchdog,
silent exit 0 on any error, no stdout.

## Core files (Sources/AgentDeckCore)

Providers and payloads
- `Models.swift` — `Provider` (claude/codex/antigravity), `SessionSnapshot`
  (schema 3; explicit `CodingKeys` — **a field missing there is silently
  dropped on write**), `SessionKey.make/split` (`<provider>-<id>`, the only
  place keys are spelled), `pidProvesSession`.
- `ProviderSpec.swift` — one row per provider: badge, tint, hook file+format
  +events, policy gating, applicability dir, event-on-argv, executable
  matching (`ExecutableMatch`), resume rule, conversation-exists check,
  running evidence, `stopUpdatesOnly`. **Adding a provider starts here.**
- `HookPayload.swift` — raw stdin → `NormalizedHookEvent` (metadata only;
  snake_case for Claude/Codex, camelCase + argv event for agy).
- `HookProcessor.swift` — applies a normalized event to the store; records
  host; drops a carried-forward pane when the host changed.
- `EventMapping.swift` — event → state action, per provider.
- `HookInstaller.swift` — writes hook entries (three formats), backup first,
  basis check, fail-closed lock, symlink-aware; `HookStatus`; `installPlan`.
- `HelperSync.swift` — copies the bundled helper to the stable path only if
  not older (never downgrades).

Discovery, liveness, state
- `ClaudeSessionRegistry.swift` — reads `~/.claude/sessions/*.json`,
  live-filters (start time + looks-like-claude), `StateReconciler` (registry
  vs hook, newer wins; a newer registry wait is a new wait).
- `AntigravityState.swift` — non-blocking `flock` probe of presence locks,
  `last_conversations.json` for an unambiguous cwd.
- `Liveness.swift` — what to delete: dead/reused pids, superseded after
  `/clear`, 24 h idle for pid-less or app-hosted-Codex rows; confirmed-live
  keys are never deleted.
- `RunningEvidence.swift` — the single "is it running" definition (capture,
  offers, preflight, pre-launch re-check, confirmation, reservations).
- `SessionPipeline.swift` — the whole snapshots→rows derivation.
- `Attention.swift`, `AutoAck.swift`, `RowOrdering.swift`, `WaitingTracker.swift`,
  `EmptyState.swift` — badge counts, ordering (needs-you first, then newest),
  notification episodes (persisted across relaunch), empty-state text.
- `ProcessTree.swift` — sysctl/proc helpers: ancestry, executable path with
  argv[0] fallback (Claude prunes old version binaries), controlling tty,
  argument search, Codex process scan.
- `HostClassifier.swift`, `ClaudeDesktop.swift`, `FocusTarget.swift` — terminal
  vs app host (outermost bundle wins; unknown ≠ app), Desktop specifics, where
  a click goes.
- `ITermFocus.swift` — AppleScript (focus by GUID, list sessions with tty),
  title cleanup.
- `ClaudeEnvironment.swift` — managed policy (`managed-settings.json`, MDM
  plist) and `CLAUDE_CONFIG_DIR` resolution.
- `ClaudeTranscript.swift`, `ModelSource.swift`, `ModelName.swift`,
  `CodexThreads.swift`, `CodexSessionIndex.swift`, `RowMeta.swift` — model,
  names and tooltip metadata.

Restore
- `Workspace.swift` — per-boot generations (append-only; closed sets recorded
  as they happen; two-miss rule), named workspaces, reservations on disk;
  unknown entries kept as opaque JSON (`OpaqueJSON.swift`).
- `WorkspaceCapture.swift` — which rows are remembered (never app-hosted,
  names only if user-set).
- `WorkspaceRestore.swift` — pure plan (skip reasons) + executor (AppleScript
  launch script that reports typed/untyped, batches of 5, readiness check).
- `RestoreReport.swift` — what the footer says after a restore.

Misc: `SnapshotStore.swift` (atomic writes, per-key flock with inode check,
orphan sweep that keeps files a newer build wrote), `BoundedSubprocess.swift`
(hard deadline, SIGKILL, non-blocking drain), `LaunchArguments.swift`,
`PathFormat.swift`, `TimeFormat.swift`, `Version.swift`.

## Invariants — do not break

- **Privacy:** metadata only. Never read into a stored field, log or display:
  prompts, responses, tool arguments (`lastUserInput`, `toolCall.args`,
  Codex `threads.title`, agy `history.jsonl`, Desktop `local_*.json` titles).
  Tests plant marker strings and assert they never reach a snapshot or log.
- **User configs:** only `HookInstaller` writes `~/.claude/settings.json`,
  `~/.codex/hooks.json`, `~/.gemini/config/hooks.json`, always with a backup
  and only AgentDeck's own entries/set. Never write a managed policy.
  Respect `allowManagedHooksOnly` (Claude hooks blocked → discovery-only).
- **Restore safety:** commands are built from a UUID, a validated absolute
  cwd and allow-listed modes, typed as `cd -- '<cwd>' && command <bin> …`
  (`command` defeats aliases). Never restore an app-hosted session. A launch
  that may have happened stays reserved until seen running or cleared.
- **Compatibility:** 0.5.1+ keeps files it can't decode (newer providers,
  states, workspace entries) instead of deleting/overwriting them.
- `.done`/`.error` are hook-only facts; never inferred from a registry.
- No ticket numbers in code comments.

## Working on it

```
swift build                 # all targets
./test.sh                   # tests; use this, not bare `swift test` (CLT-only toolchain flags)
./test.sh --filter <name>   # one test
./install-app.sh            # release build → ~/Applications/AgentDeck.app
pkill -x AgentDeck; open ~/Applications/AgentDeck.app
.build/debug/AgentDeck --render-popover /tmp/x.png   # offscreen render of the real popover, read-only
~/Applications/AgentDeck.app/Contents/MacOS/agentdeck-hook status   # versions, hook health, active count
tail ~/Library/Application\ Support/AgentDeck/app.log
```

Expectations that have held every change so far:
- Gate on `./test.sh`'s exit code (a pipe once masked a failing suite).
- **Mutation-check every new guard test:** break the fix, show the test
  failing with its line, restore. A test that passes without the fix guards
  nothing.
- Verify live after deploying: status output, a render you actually look at,
  app.log clean. A green suite proves nothing about the app target.
- Test against copies of real configs; never run `agentdeck-hook install` or
  edit real configs during development without the owner's say-so.
- The render harness shows a red "helper" dot and yellow placeholder boxes;
  both are harness artefacts.

## Releasing

1. Move CHANGELOG `## Unreleased` → `## X.Y.Z` (the workflow publishes the
   first `## ` section verbatim as the release notes).
2. Bump `VERSION` and `Sources/AgentDeckCore/Version.swift` (a test checks
   they match).
3. Commit, push, wait for CI, then `git tag -a vX.Y.Z <that commit>` and push
   the tag. `release.yml` verifies tag == VERSION, builds, tests, zips
   `AgentDeck-vX.Y.Z.zip` and creates the GitHub release.
4. Download the zip and run `AgentDeck.app/Contents/MacOS/AgentDeck --version`.

Repo: github.com/AutoXPilot/AgentDeck (public, personal account). Push uses
the SSH host alias `github-tunghoangt`.

## Platform facts worth knowing

- Claude's version-named binaries are pruned on update: use argv[0]
  (`KERN_PROCARGS2`) when `proc_pidpath` fails.
- iTerm2: AppleScript `tty of session` and `id of session` (GUID) are how
  panes are found; `create window` can hang while the screen is locked.
  iTerm's `command` parameter does not run a shell — restore types into a
  login shell with `write text`.
- Hook commands are single-quoted (`'<path>' <provider>`); the old
  double-quoted form is still accepted as healthy.
- Codex: hooks are trusted per file/event/index in `~/.codex/config.toml`
  (`[hooks.state]`); ChatGPT.app accepts changed hooks silently. All ChatGPT
  threads report one shared server pid.
- agy: hooks read only at startup; no SessionStart on `--continue`; one turn
  = several invocations and one `Stop{fullyIdle:true}`; `ask_question` is the
  waiting tool; `agy --bg-updater` is also named `agy` and is excluded.
- Ad-hoc signing: notifications are refused (UNUserNotificationCenter needs a
  real identity); keep a stable `--identifier` so Automation grants survive
  rebuilds.

## Open items

- Click-to-thread for ChatGPT rows: `codex://threads/<id>` opens ChatGPT;
  whether it lands on the exact thread is unconfirmed, so clicks bring the
  app forward.
- agy permission prompts aren't detected (tool name never observed); agy
  print mode isn't filtered.
- Claude Desktop label/tag/click path is tested in core only (no live
  Desktop-hosted session observed since the code landed).
- Distribution: Developer ID signing + notarization (needs an Apple Developer
  account) so a downloaded build opens on managed Macs; then a Homebrew cask.
