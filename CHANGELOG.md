# Changelog

## Unreleased

### Added

- **Bring sessions back after a reboot or an iTerm restart.** AgentDeck
  remembers the agent sessions running in each boot and can resume each
  conversation in its folder: a banner after a restart offers the
  previous boot's sessions; the footer menu offers groups of sessions
  that closed together ("Closed 11:05 — 30 sessions") and every boot it
  still remembers; and **Save open sessions as workspace…** keeps a named
  set to restore any time. Each session comes back as
  `cd <folder> && claude --resume <id>` (or `codex resume <id>`) typed
  into a new iTerm tab, with Claude's permission mode when a hook
  recorded it.

  What it stores is a folder, a session id, the permission mode and a
  name you set yourself — never the command a session was started with,
  which can carry a prompt or a credential. Restore builds its command
  from the id, which must be a UUID, and refuses folder paths that are
  relative or contain control characters. Sessions already running,
  folders that moved (with a Locate… to point at the new one) and
  missing conversations are skipped by name. Launches go five at a time
  once iTerm answers, and a session launched — or possibly launched — is
  not launched again until it is seen running, across relaunches.

  Limits: the default iTerm profile must start a POSIX shell; a session
  found only through Claude's registry has no recorded permission mode
  and comes back in your default; the window/tab layout isn't restored.
- **Rows found through Claude's registry can be clicked to their pane.**
  They had no recorded pane id, so a click said the session wasn't in a
  terminal AgentDeck could focus. The pane is now found from the agent's
  controlling terminal.

- **Every live Claude session is listed, not just the ones hooks saw.**
  Hooks only report sessions running when they fire, so a session
  started before the hooks were installed — or one whose snapshot aged
  out while it sat idle — was invisible. The development machine showed
  **15 rows for 36 live sessions**, and two of the missing ones were
  blocked waiting on the user, one of them for 72 days.

  AgentDeck already read Claude's registry
  (`~/.claude/sessions/<pid>.json`) on every reload but only consulted
  it through a snapshot's pid, so sessions without a snapshot fell
  through. It now also treats that registry as a discovery source,
  filtered to live processes whose start time is consistent with the
  session's — enough to reject an obviously recycled pid, though not a
  proof of identity, so a stale row remains possible.

  A snapshot always wins where both exist; `done` and `error` are never
  inferred from a registry status. No subprocess is involved:
  `claude agents --json` returned exactly this set when compared on a
  36-session machine, but shelling out from a GUI app would mean finding
  a binary at a version-named path that gets pruned on update. Codex has
  no equivalent registry and stays hook-only.

  Clicking a row now only marks it handled when it can actually take you
  to the session. Discovered rows have no recorded pane, so otherwise a
  click would clear a blocked session's badge and leave you elsewhere.

  Sessions already blocked when this first runs don't all fire a
  notification at once — the backlog starts its cooldown instead.

### Fixed

- **A second wait could stay hidden behind the first one's
  acknowledgement.** If a session was answered and blocked again with no
  hook in between, both sources still said "waiting", so the new wait
  kept the old one's time and an acknowledgement of the first covered
  it. A newer registry wait now counts as a new wait.
- **A reused pid could hide a session's real registry entry.** The
  registry was looked up by the snapshot's pid first; if that pid now
  belonged to another session, the right entry was never consulted.
- **Restarting AgentDeck re-announced long-blocked sessions** and
  re-applied the first-run quieting, so a session blocked at startup
  could stay silent as long as AgentDeck kept being restarted.
  Notification cooldowns and already-announced waits now survive a
  relaunch.
- **A live but quiet Codex session lost its row after seven days.**
  Verified-live agents are no longer expired for being quiet.
- **Hook commands double-quoted the helper path**, which still lets the
  shell expand `$(…)` and backticks in it. They are single-quoted now;
  existing installs stay healthy and are rewritten on the next install.
- **The installer and snapshot locks failed open**, proceeding unlocked
  when the lock couldn't be taken. Both now fail closed, the snapshot lock
  also re-checks that the file it locked is still the one at its path,
  and the installer re-checks the config immediately before replacing it.
- **A timed-out subprocess could block forever** if it ignored SIGTERM or
  something else held its output open. It is now killed with SIGKILL and
  its output is read without waiting for end-of-file.

- Session counts in the menu-bar badge were computed before duplicate
  rows were removed, so a doubled session could be counted twice.
- **The 0.4.1 Codex model-freshness fix was inert.** `modelObservedAt`
  was set on every hook event but left out of `CodingKeys`, and since an
  explicit `CodingKeys` also drives the synthesized encoder, it was
  dropped on write. The reader therefore always saw nil and fell back to
  ranking by the snapshot's write time — the exact behaviour the field
  was added to replace. The tests passed because they called the
  decision function directly and never went through the store; there is
  now a round-trip assertion over a populated snapshot covering today's
  fields. (It is not automatic: a future optional field left nil in the
  fixture could still slip through.)
- **Long-running sessions disappeared from the list.** Claude Code
  installs each release as `~/.local/share/claude/versions/<version>` and
  prunes old ones on update, so a session that has been running a while
  is executing a binary that no longer exists — and `proc_pidpath`
  returns ENOENT for it. That cost the snapshot its pid, which dropped it
  from the 7-day live cap to the 24-hour idle one, so any session quiet
  for a day was deleted. The effect was backwards from what you'd want:
  the longer a session ran, the more likely it was to vanish. Observed on
  a session running since July, on a build pruned in October. The
  executable path now falls back to argv[0] (`KERN_PROCARGS2`), which is
  copied at exec time and survives the binary being replaced or removed.
- **Prompt text could appear in a row title and a notification.** Codex
  fills `threads.title` with the user's first message unless the thread
  was renamed, and nothing in its schema distinguishes the two. AgentDeck
  displayed any such title under 60 characters, on the theory that short
  text is a label — but length is not provenance, and "Help me research
  this problem" is a prompt at 29 characters. The column is no longer
  selected at all, so prompt text never enters the process; a Codex row is
  named only by an explicit `/rename`. This contradicted the README's
  metadata-only promise, which is now accurate and notes the old
  behaviour.
- **Editing your CLI config could lose a concurrent save, and could skip
  its own backup.** The installer read the whole config, modified it in
  memory and wrote it back with no check that it hadn't changed meanwhile,
  so a save by Claude or an editor in that window was overwritten —
  atomic replacement prevents a torn file, not a lost update. The backup
  was taken with `try?`, so a failure to write it didn't stop the edit,
  and old backups were pruned before the new write succeeded. Now: edits
  abort if the file changed, a backup must succeed first, pruning happens
  only after the edit commits, a failed edit strands neither a temp file
  nor a misleading backup, concurrent AgentDeck installs are serialized by
  a lock, and the staging file is created private so a copy of a `0600`
  config is never briefly world-readable.
- **A session's lock could be deleted while held.** Neither `open()` nor
  `flock()` updates mtime, so a long-lived session's lock file aged past
  the one-hour sweep and got unlinked underneath its holder; the next
  helper then created the same path, got a different inode, and locked
  that — two writers each believing they were serialized. Acquiring a lock
  now refreshes it, and the sweep only reclaims locks it can prove are
  unheld.
- **The app could delete a snapshot a helper had just written.** Its
  re-read-then-delete ran outside the lock the helper writes under, so an
  event arriving in that gap was discarded — losing a live session's row.
  Both steps now happen under that lock.
- **`--version` did nothing.** The README documented it, but the app
  binary never handled it: the flag fell through to "run the app". So did
  every unrecognised `--flag`, which meant a typo silently started a
  second menu-bar instance racing the live one over the same state files.
  Both now exit — `--version`/`-v` print, `--help`/`-h` print usage, and
  an unknown long option exits 64. Single-dash arguments still launch
  normally, since LaunchServices and Xcode pass their own (`-psn_…`).

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
