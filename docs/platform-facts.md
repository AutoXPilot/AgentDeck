# Platform facts

Behaviour of the agents, apps and macOS that AgentDeck depends on and that
the code alone doesn't explain. Most of it is undocumented and was found by
probing, so each fact says which version it was seen on, when, and how.
Re-check a fact before building on it if the version has moved a lot.

How it was established:
- **observed**: seen on a live system (a probe, a log, a running session).
- **docs**: read in the vendor's documentation, not observed.
- **fixture**: a recorded payload or file shape, now a test fixture.

When a probe touches hook payloads or environments, record names, types
and allow-listed values only. Payloads carry prompt text (agy's
`lastUserInput` on every event), so never dump them raw.

## Claude Code

| Fact | Seen on | How |
|---|---|---|
| Versioned binaries (`…/versions/2.1.220`) are deleted on update, so `proc_pidpath` fails for older sessions; argv[0] from `KERN_PROCARGS2` still names it. The process name (`p_comm`) is the version string, not "claude". | 2.1.2xx; found in AgentDeck 0.5.0 | observed |
| `~/.claude/sessions/<pid>.json` lists live sessions with `sessionId`, `cwd`, `pid`, `status`, `name`, `nameSource`, `startedAt`, `kind`, `entrypoint`, `version`. Files outlive their process. Not a documented interface; the docs call it crash and concurrency bookkeeping. | fields present from 2.1.206; checked 2.1.206, 2.1.219, 2.1.221 | observed, fixture |
| Background sessions (`claude --bg-pty-host`, reparented to launchd) write no registry entry; the transcript's `sessionKind` identifies them. | found in 0.4.1 | observed |
| The hook payload's `model` can name a model the session isn't running; the transcript's last assistant record is right but never carries the `[1m]` qualifier. | found in 0.4.0 | observed |
| Policy: `allowManagedHooksOnly`, or `disableAllHooks` at the managed level, stops user hooks. `CLAUDE_CONFIG_DIR` moves sessions, transcripts and settings and can be set by policy. `disableBypassPermissionsMode` / `disableAutoMode` refuse those modes. | 2026-10 | docs (code.claude.com managed-settings, settings, env-vars) |
| Claude asks whether to trust the folder on every launch in `~`, so restored sessions there stop at that question. | 0.5.1 work, 2026-10 | observed |

## Claude Desktop

| Fact | Seen on | How |
|---|---|---|
| Runs Claude Code from an inner bundle, `~/Library/Application Support/Claude/claude-code/<ver>/<hash>/claude.app` (bundle id `com.anthropic.claude-code`). The real host is `/Applications/Claude.app`. | 2026-10-26 | observed |
| Its sessions use the same `~/.claude/sessions` registry. Transcript records carry `entrypoint: "claude-desktop"` (CLI: `"cli"`). Scratch sessions use a cwd under `…/Claude/scratch-workspaces/…`. | 2026-10-26 | observed |
| `claude-code-sessions/…/local_<id>.json` holds content (`title`, summaries, prompt snapshots). AgentDeck never reads it. | 2026-10-26 | observed (keys only) |
| Sessions in Desktop's sidebar can be iTerm CLI sessions shown through Remote Control, not Desktop-hosted ones. | 2026-10-27 | observed |
| Cowork runs inside a VM; its sessions aren't visible to the host. | 2026-10-26 | observed (process list) |
| URL routes `claude://code/continue?session=last`, `code/needs-input`, `code/new` exist; a per-session form is unknown. | 2026-10-26 | read from the app bundle, not run |

## Codex

| Fact | Seen on | How |
|---|---|---|
| Hooks in `~/.codex/hooks.json` (same schema as Claude's): SessionStart, UserPromptSubmit, PermissionRequest, Stop, SessionEnd fire. No StopFailure, so no error state. | cli 0.145.0–0.147.0 | observed, fixture |
| Hooks are trusted per file, event and index in `~/.codex/config.toml` (`[hooks.state]`); the CLI asks once after a change. | 2026-10 | observed |
| After `codex resume`, no hook runs until the first message, so a restored session is confirmed by its process instead. | 2026-10 | observed |
| `threads.title` in `state_5.sqlite` is the first user message unless renamed; a `/rename` lands in `session_index.jsonl`. | 0.145.0 | observed |
| The single-quoted hook command fires. | 2026-10-28 | observed |

## Codex in ChatGPT.app

| Fact | Seen on | How |
|---|---|---|
| ChatGPT.app bundles its own `codex` (0.155.0-alpha seen) and fires `~/.codex/hooks.json`. It accepts changed hooks without asking. | 2026-10-28 | observed |
| Every thread reports the same pid: ChatGPT's shared Codex server. | 2026-10-28 | observed |
| `codex://threads/<thread id>` opens that exact thread. | 2026-11-01 | observed |
| Threads have `originator = "Codex Desktop"` in `state_5.sqlite`, cwd under `~/Documents/Codex/<date>/<slug>`. | 2026-10-26 | observed |

## Antigravity CLI (`agy`)

| Fact | Seen on | How |
|---|---|---|
| Hooks load only from named hook sets in `~/.gemini/config/hooks.json`, and only at startup: a running agy doesn't see new hooks. | 1.4.7, 2026-10-28 | docs + observed |
| The payload is camelCase and names no event, so the event goes on the command line. Every payload carries `lastUserInput` (prompt text); tool events carry `toolCall.args`. | 1.4.7, 2026-10-28 | observed (metadata-only probe) |
| No SessionStart, even on `--continue`: the first event is PreInvocation. One turn runs several PreInvocation/PostInvocation pairs and one `Stop{fullyIdle:true, terminationReason:"NO_TOOL_CALL", error:""}`. | 1.4.7, 2026-10-28 | observed |
| A question to the user is the tool `ask_question` (PreToolUse/PostToolUse). Permission prompts: tool name never observed. | 1.4.7, 2026-10-28 | observed |
| Hook commands inherit `ITERM_SESSION_ID`; `ANTIGRAVITY_CONVERSATION_ID` is set. | 1.4.7, 2026-10-28 | observed (names only) |
| `presence/<conversation>.lock` is `flock`-held while the session runs; the file stays afterwards with an unchanged mtime. | 1.4.7, 2026-10-28 | observed |
| `agy --bg-updater` is a child process also named `agy`. | 1.4.7 | observed |
| Resume: `agy --conversation <uuid>`; modes `--mode accept-edits|auto|plan`. | 1.4.9 | `agy --help` |
| Loads `AGENTS.md` / `GEMINI.md` from the working folder up to the repository root. | 1.4.9, 2026-11-01 | docs embedded in the binary, not observed |

## iTerm2

| Fact | Seen on | How |
|---|---|---|
| AppleScript `tty of session` and `id of session` (a GUID) identify panes; `ITERM_SESSION_ID` carries the same GUID. | 3.7.0 | observed |
| `create window` can hang while the screen is locked. | 3.7.0, 0.5.0 work | observed |
| The `command` parameter of `create window`/`create tab` runs the program without a shell; restore uses `write text` into a login shell instead. | 3.7.0, 0.5.0 work | observed |
| The `iterm2:///reveal` URL can stop working without an error, so it is only a fallback. | before 0.4 | observed |
| Inside `tell application` blocks, constants like `tab` can be shadowed by the app's dictionary. | before 0.4 | observed |

## macOS

| Fact | How |
|---|---|
| An ad-hoc-signed app can't use `UNUserNotificationCenter` (it needs a real signing identity), so AgentDeck falls back to `osascript display notification`. | observed |
| Automation and notification grants are keyed to the app's identity: keep a stable `--identifier` so grants survive rebuilds. | observed |
| Gatekeeper rejects the ad-hoc build when downloaded (quarantined); a local build runs because it was never quarantined. | observed (`spctl --assess` → rejected) |

## Live checks still owed

What tests can't show and nobody has yet run on a real system. Update the
row (date, version, result) when one is done.

| Check | Status |
|---|---|
| The banner after a reboot offers the previous boot's sessions | pending since 0.5.0 (unit-tested; restore after an iTerm quit and from the menu has been used) |
| **Locate…** for a moved folder | pending since 0.5.0 |
| Single-quoted hook command under Codex | done 2026-10-28 |
| `codex://threads/<id>` opens the exact thread | done 2026-11-01 |
| Claude Desktop row: label, "Desktop" tag, click brings Claude.app forward | pending (no Desktop-hosted session run since 0.6.0) |
| agy permission prompt: which tool name it uses | pending; prompts aren't detected until then |
| agy print mode (`agy -p`): is there a discriminator to filter on? | not run |
| A per-session `claude://` link | not run |
| agy reads this repo's `AGENTS.md` | not observed (documented) |
| A notarized build opens from a quarantined download | blocked on [plans/distribution.md](plans/distribution.md) |
