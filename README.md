# AgentDeck

macOS menu-bar monitor for every active **Claude Code** and **Codex** terminal
session. Shows provider, project, state (ready / working / waiting / done /
error), and elapsed time; sessions needing attention are counted in the
menu-bar badge and sorted first. Clicking a row acknowledges it and focuses
the exact iTerm2 pane via `iterm2:///reveal?sessionid=…`.

No server, no polling, no transcript scraping — lifecycle hooks write tiny
metadata snapshots; the app watches the directory.

## Build & run

```sh
swift build -c release
.build/release/AgentDeck &          # menu-bar app
./test.sh                           # unit tests — see note below
```

To start at login: run `./install-app.sh` (packages a stable
`~/Applications/AgentDeck.app` so Login Items doesn't point into the
disposable `.build/` directory), then add that app in System Settings →
General → Login Items.

## Hardening notes

- On launch the app compares the bundled helper's SHA-256 against the stable
  copy hooks invoke (`~/Library/Application Support/AgentDeck/bin/`) and
  atomically updates it on drift — upgrading the app can never leave hooks
  running an old helper. A stale helper also shows as unhealthy in the footer.
- Snapshots predating the last boot are dropped (pids are meaningless across
  reboots), pid liveness treats another user's process as dead (claude/codex
  always run as you — EPERM means a recycled pid), and a 24h idle cap
  backstops same-user pid reuse.
- `session_id` is sanitized before becoming a filename (hook payloads must
  never write outside the sessions dir); stale `.tmp`/corrupt files are swept.
- The sessions-dir watcher re-arms itself if the directory is deleted or
  renamed; the liveness sweep re-checks on disk before deleting so it can't
  race a concurrent hook write.
- Config rewrite trade-off: hooks are installed via a JSONSerialization
  round-trip, which loses key order/formatting and can change float
  representation (1.1 → 1.1000000000000001). Timestamped backups (pruned to
  the last 5) retain the original bytes; file permissions are preserved.

## Install the hooks

```sh
.build/release/agentdeck-hook install
.build/release/agentdeck-hook status
```

`install` copies the helper to `~/Library/Application Support/AgentDeck/bin/`
and idempotently registers hook entries in `~/.claude/settings.json` and
`~/.codex/hooks.json` (timestamped `.bak` backups are created; all existing
settings and hooks are preserved; re-running repairs stale entries). The app's
footer also shows hook health with an Install button.

**Codex trust**: Codex requires hooks to be trusted; it will prompt once on
the next interactive `codex` launch. Non-interactive runs before that only
fire hooks with `--dangerously-bypass-hook-trust`.

**Claude sessions pick up hooks live** (file watcher) — no restart needed.
Codex sessions need a restart to load hooks.json.

## How it works

```
claude / codex lifecycle hooks
      └─ "…/agentdeck-hook" claude|codex     (JSON on stdin, exit 0 always)
            └─ ~/Library/Application Support/AgentDeck/sessions/<provider>-<id>.json
                  └─ AgentDeck.app: directory watcher + 15s liveness sweep
```

State mapping — Claude: SessionStart→ready, UserPromptSubmit→working,
PermissionRequest/Notification(permission·idle·elicitation_dialog·
agent_needs_input)→waiting, Stop→done, StopFailure→error, SessionEnd→remove.
`agent_completed` is deliberately ignored: a background task finishing must
not flip the main session's state — Stop owns "done".

Codex registers SessionStart/UserPromptSubmit/PermissionRequest/Stop/
SessionEnd (Claude-style `hooks.json` schema). SessionStart, UserPromptSubmit,
Stop, and SessionEnd verified firing live against codex-cli 0.145.0 (codex
clamps SessionEnd's hook timeout to 3s). PermissionRequest is accepted by the
config but has not been observed firing — exec mode never prompts; it's
registered so interactive approvals surface as "waiting" if codex emits it.
No StopFailure → no error state for Codex. The PID sweep remains the removal
backstop for crashes.

Snapshots are metadata-only (no prompts, responses, or credentials) and are
written atomically (temp file + rename). The helper records the agent's PID by
walking ancestors and matching the **executable path** — the claude binary's
kernel name (p_comm) is its version number (e.g. `2.1.220`), so name matching
alone fails. Hook commands must be quoted: the helper lives under
"Application Support" and an unquoted command dies at the space.

## Uninstall

Remove the hook entries mentioning `agentdeck-hook` from
`~/.claude/settings.json` and `~/.codex/hooks.json` (or restore the newest
`.agentdeck-*.bak` backup next to each), then delete
`~/Library/Application Support/AgentDeck/`.

## Testing note

Tests use Swift Testing via `./test.sh`, which points the build at the
Command Line Tools' `Testing.framework` and disables cross-import overlays
(CLT ships no `_Testing_Foundation` Swift module). With full Xcode installed,
plain `swift test` also works.
