# Changelog

## 0.3.0

Deep-review round (three evidence streams + an adversarial plan review).

### Fixed

- **Snapshots could be wrongly deleted or wrongly kept.** Liveness now uses
  process identity — a live pid is trusted only if that process started at or
  before the snapshot's last update — so a recycled pid is detected directly.
  This replaces a `KERN_BOOTTIME` guard that drifts forward across sleep/NTP
  and could delete a session started right after login (which, if waiting,
  never came back).
- **Registry reconciliation silently no-op'd** when Claude omitted
  `statusUpdatedAt`, resurrecting the 13h-stale-`waiting` bug. It now falls
  back to the registry file's mtime, using one value for both the comparison
  and the corrected timestamp (so an unchanged entry can't re-arm an ack).
- **`idle_prompt` no longer counts as waiting** — an idle agent isn't blocked
  on you, and counting it inflated the badge.
- Old snapshots with no `schemaVersion` decode instead of being swept as
  corrupt. Concurrent `Stop`/`SessionEnd` for one session can no longer
  resurrect a removed snapshot (per-key lock). A tab closing mid-enumeration
  no longer aborts the whole title/focus fetch.
- Focus-failure and status messages set during popover close are now actually
  shown (they were cleared before first display).

### Changed

- **Notifications: at most one per session per hour**, even across separate
  blocks (183 banners in 26 days, one session 20×, drove this). Two-phase so
  an acknowledged session's suppressed alert no longer disarms the episode.
- **Done sessions auto-acknowledge after 30 minutes** — they stay in the list
  but leave the attention count and sink in the sort.
- Empty-state messages are provider-specific and put filter-no-match first.
- Reloads are debounced (250ms) and hook-install health is cached by file
  mtime, cutting repeated full parses of settings.json/hooks.json under load.
- The helper installs itself atomically, ignores `AGENTDECK_STATE_DIR` from
  the inherited environment (only the app/tests honor it), and `status`
  reports `helperPresent` (not an implied SHA match).

### Added

- Error rows show the failure kind (rate limit, billing, server); row
  tooltips show model / effort / tokens.
- Compatibility verified against Claude Code 2.1.266 and Codex CLI 0.147.0.

## 0.2.0

### Fixed

- **Live sessions were silently forgotten.** The 24-hour idle cap ran before
  the liveness check, so any running session that went a day without a hook
  event had its row deleted — and because a session blocked on the user emits
  no events at all, it could never come back. Observed in production: five
  live Claude sessions with no rows. Live processes now get a 7-day backstop
  (kept only for same-user pid reuse); pid-less snapshots keep the 24h cap.
- **`waiting` rows went stale and real blocks were missed.** No hook fires
  when a permission prompt is answered, so rows sat at `waiting` for hours
  after the block cleared — and a block that arrived without a hook never
  showed at all. AgentDeck now reconciles against Claude's own session
  registry (`~/.claude/sessions/<pid>.json`), preferring whichever
  observation is newer, and shows *why* a session is blocked.

### Changed

- **The menu-bar badge counts only blocking states** (waiting/error).
  Finished sessions used to be counted too, so the badge was never zero and
  stopped being a signal; `done` is now a muted secondary count you can clear
  in one click.
- The menu-bar glyph reflects the most urgent state instead of being static.
- Row titles prefer each provider's own session name (Claude's registry,
  Codex's `/rename`), so they no longer depend on iTerm being readable.
- Paths are abbreviated (`~/…/parent/leaf`) instead of eating half the row.

### Added

- Notification when a session is genuinely blocked (permission prompt,
  elicitation, subagent input) longer than a threshold
  (default 5 minutes; set `waitAlertMinutes` to 0 to disable).
- Keyboard navigation: ↑/↓ to move, Return to focus, ⌘1–9 to jump.
- Filter field once more than 8 sessions are listed.
- Right-click a row: focus, dismiss without focusing, copy path, reveal in Finder.
- A warning marker on sessions running unsupervised (`bypassPermissions` /
  `dontAsk` for Claude, sandbox-disabled or approval-never for Codex).
- Codex rows read model, effort, tokens, branch and approval mode from
  `~/.codex/state_5.sqlite` (read-only).
- Failures that used to be silent are now visible: no iTerm pane recorded,
  iTerm not running, and denied Automation permission (with a settings link).
- Health-aware empty state, "Copy diagnostics" button, and the version is
  shown in the UI, in `agentdeck-hook status`, and via `--version`.
- Accessibility: VoiceOver labels on rows, health shown by symbol as well as
  colour.

### Packaging

- The app bundle is signed with a stable identifier, so macOS no longer
  revokes Automation/Notification grants on every upgrade.
- `NSAppleEventsUsageDescription` explains the iTerm2 prompt.

## 0.1.0

Initial public release: menu-bar monitor for Claude Code and Codex sessions
via lifecycle hooks, with click-to-focus for iTerm2 panes.
