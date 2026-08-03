# Changelog

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

- Notification when a session has been blocked longer than a threshold
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
