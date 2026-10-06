# Changelog

## Unreleased

## 0.4.1

Patch release for 0.4.0, whose row-model feature shipped with a
provenance bug: once the two sources for a Codex model disagreed, the
stale one kept winning. Found by an adversarial review of the 0.4.0 code,
along with four more in the same area.

### Fixed

- **A blocked background session no longer reports a dead end.** A Claude
  session started from a slash command runs as `claude --bg-pty-host`
  reparented to launchd: no terminal pane, no window, nothing to focus.
  Clicking it said so — accurately, and uselessly, while the session sat
  on a permission prompt. Those rows now say where the prompt is actually
  answered: the agents panel of the session that spawned it. Detected via
  the `sessionKind` Claude records in the transcript, read off the same
  entry the model already comes from.
- **A stale model could outrank a fresher one indefinitely.** Ranking the
  hook payload against Codex's sqlite used the snapshot's write time, but
  an event that omits the model still advances that while carrying the old
  model forward — so once the two disagreed, the stale value kept winning
  for as long as the session stayed active. Snapshots now record when the
  model was actually *reported*, and the sqlite read is timestamped before
  it runs rather than after, so a hook landing mid-read can't be ranked
  older than the cache that missed it.
- **Transcript facts refresh while the popover is open**, not only when it
  opens — a `/model` switch, or a background session appearing, used to
  stay wrong until the popover was reopened.
- **Only an assistant turn can report the model.** A transcript record of
  another type carrying a `model` key was accepted, which would have
  mislabelled both the model and (via `sessionKind` on the same record)
  the focus explanation. Verified against 48,694 real records.
- **The oldest entry in the read window could be dropped.** The tail read
  assumed it always began mid-record and discarded the first one; when the
  window opened on a record boundary that threw away a real turn, and a
  window holding only that turn came back empty.
- The README described stale `waiting` as a Codex-only limitation. It
  applies to Claude background sessions too — they write no
  `~/.claude/sessions/<pid>.json`, so there's no registry entry to
  reconcile against.

## 0.4.0

### Added

- **Each row shows the model it's running** — "Opus 5.5", "Opus 5.5 1M",
  "Fable 5.1", "Astra 6", "Sol 6.1" — instead of hiding it in the tooltip,
  which still carries the raw identifier. Names are derived by rule rather
  than from a lookup table, so a model that ships tomorrow still renders
  sensibly, and an id in a shape the rules don't cover is passed through
  untouched rather than mangled.

  Picking the model turned out to be the hard part, because each available
  source is wrong in a different way. Measured across 23 live sessions:
  Claude's hook payload and its transcript agreed 19 times; of the rest,
  one payload reported `claude-fable-5-1` for a session whose transcript
  was 160 of 160 `claude-opus-5-5` (confirmed wrong by the person running
  it), and three payloads carried a `[1m]` long-context qualifier the
  transcript never records. So the transcript names the model and the
  payload contributes the qualifier when both agree on which model it is.
  For Codex, `state_5.sqlite` is read when the popover opens, so a hook
  event that lands after that read wins over the cache.
- **GUI-hosted sessions are now first-class.** Agents launched by an app
  rather than a terminal — e.g. a Codex session running inside ChatGPT.app —
  have no iTerm pane, so clicking their row used to just say so. It now
  brings the owning application to the front, and the tooltip says which
  ("Click to bring ChatGPT to the front"). Terminal panes still win when
  present; the apology message is reserved for sessions with neither.

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
