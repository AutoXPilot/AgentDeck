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
./test.sh                           # unit tests (33) — see note below
```

To start at login: System Settings → General → Login Items → add
`.build/release/AgentDeck`.

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
PermissionRequest/Notification(permission·idle·elicitation)→waiting,
Stop→done, StopFailure→error, SessionEnd→remove. Codex ships only
SessionStart/UserPromptSubmit/Stop (schema is Claude-style `hooks.json`,
verified against codex-cli 0.145.0); no waiting/error states, and removal
relies on the PID sweep since Codex has no SessionEnd.

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
