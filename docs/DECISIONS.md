# Decisions

Why AgentDeck is the way it is, so a choice isn't re-argued or quietly
undone. One entry per decision: what was chosen, over what, and why.
Newest last within each section. When a change reverses one, edit the
entry (say what replaced it and when) in the same commit; don't delete it.

Shipped behaviour is described in README.md; this file is only the
reasoning.

## Architecture

**Logic lives in AgentDeckCore; the app target stays thin.** (0.1–0.4)
Decisions are pure functions with inputs, tested in core; `SessionsModel`
reads files, calls core, assigns outputs and performs side effects. The
app target has no tests, and the bugs that reached users there were
decisions made inline in the app. Testing pure decisions is not enough on
its own: a field missing from `SessionSnapshot.CodingKeys`, installer
races and snapshot locking were core bugs that decision-level tests
missed, so persistence (round-trips through the real encoder) and
concurrency get their own tests.

**One provider table, deliberately not more.** (0.6.0)
`ProviderSpec` holds what genuinely varies by data: badge, hook file and
format, events, policy gating, applicability, executable matching, resume
rule, running evidence. Model selection (`ModelSource`), event mapping
(`EventMapping`) and each provider's own stores (registry, transcripts,
Codex threads, agy presence) stay per-provider code: they differ in
logic, not data, and folding them into the table would hide that.

**No `Provider.unknown`.** (0.5.1)
A file naming a provider this build doesn't know is kept as written
(opaque JSON) and skipped, never decoded into a real case or deleted.
Two builds of AgentDeck share one data folder, so an older build must
not destroy a newer build's data. 0.5.0 lacks this; 0.5.1 is the
minimum for running mixed versions.

**The helper is never downgraded.** (0.5.1)
`HelperSync` replaces the shared helper only with one whose version is
the same or newer. Before this, whichever copy of the app launched last
won, so an old copy silently ran new hooks through an old helper.

## Sessions and state

**Hooks plus discovery, not hooks alone.** (0.5.0)
Hooks report only sessions running when an event fired, so sessions
started before installation, or idle past the snapshot cap, were missing
(15 rows for 36 live sessions on the development Mac). Claude's own
registry (`~/.claude/sessions/<pid>.json`) and agy's presence locks fill
the gap. Codex has no equivalent, so it stays hook-only.

**`done` and `error` come only from hooks.** (0.5.0)
A registry or lock can say a session exists or is waiting; it can't say a
turn finished or failed. Inferring those would show false completions.

**Never invent sessions from database recency.** (0.6.0)
`state_5.sqlite` and agy's conversation files say a conversation exists
and when it last changed, not that it is running. Rows come only from a
hook, a live registry entry, or a held lock.

**Liveness by identity, with one exception.** (0.5.0, 0.6.0)
A snapshot whose pid is alive, started before the snapshot's last update,
and looks like the agent is kept however long it is quiet (a Codex
session waiting over a weekend used to vanish at seven days). The
exception: every ChatGPT-hosted Codex thread reports the same pid,
ChatGPT's shared Codex server, so that pid proves the app is open, not
that a thread is. Those rows follow the 24-hour idle rule for pid-less
snapshots and don't count as running for restore.

**Host: the outermost app bundle wins; unknown is not app.** (0.6.0)
Claude Desktop runs Claude Code from an inner `claude.app` bundle, so
the nearest bundle is the wrong host; the outermost `.app` on the process
chain is the right one. A verified app host beats an inherited
`ITERM_SESSION_ID` (a GUI launched from a shell inherits it). When the
process walk fails and nothing else says, the host is unknown and the
behaviour stays terminal-first, because treating unknown as app would
stop restoring ordinary terminal sessions.

**A click on an app-hosted row never marks it handled.** (0.6.0)
Activating an app or opening a `codex://` link can't prove the user
reached that session, so a session that needs you keeps its badge until
dismissed or until a hook clears it.

**agy print mode is not filtered by "no tty".** (0.6.0)
Lacking a tty isn't evidence of print mode (discovered and background
sessions have none either). Print mode is filtered only once a payload or
environment discriminator is observed; none has been yet.

**Codex threads run by the shared daemon: ignore its pane, find the real one.** (Unreleased)
From Codex 0.166 hooks run under one app-server daemon, with its pid and
the pane id it inherited. The helper records neither for such a thread
(unless the ancestry is ChatGPT.app's own app-server, which stays
app-hosted). The app treats a thread whose `originator` is `Codex
Desktop` as ChatGPT-hosted, and otherwise looks for the pane among iTerm
panes whose terminal runs a `codex` CLI: a unique title match on the
thread name, or the only Codex pane for an unnamed thread. Ambiguity
gives no pane rather than a wrong one. Rejected: trusting the inherited
pane (the original bug) and treating every daemon thread as app-hosted
(loses the click for CLI threads).

**A daemon-run Codex thread is running while the daemon holds its rollout open.** (Unreleased)
Its hooks carry the daemon's pid, which every thread shares, and its CLI
client's arguments name no thread, so neither the pid rule nor the argv
scan works. The daemon keeps open exactly the rollouts of the threads it
runs (seen: two live CLI threads, two open rollouts; finished `codex exec`
threads not held). That set feeds running evidence (capture, restore
preflight) and the never-delete set, and the daemon's pid is no longer
trusted for any Codex row. ChatGPT's own bundled app-server is told apart
by path and keeps its pid.

**Usage only grows within a window, and Claude echoes are recognised by
reset time.** (Unreleased)
Every open session's tee reports its own cached figures, so the store
keeps the larger percent within one reset time and never lets an older
window replace a newer one; writes are serialized per provider. A
5-hour reset time belongs to one account, so a figure carrying another
account's current or recent reset time is that account's, echoed by an
idle session, and is dropped.

**Infer "may need you" for Codex prompts no hook reports.** (Unreleased)
MCP elicitations fire no hook, so a Codex thread waiting on one looked
busy for hours. A rollout ending in a non-shell tool call with no output,
and nothing written for 2 minutes, is shown as waiting ("may need you").
Shell commands, `wait` and `sleep` are excluded because they legitimately
run long, and Codex's own approvals for shell commands fire
PermissionRequest. A stall older than the latest hook is ignored (a new
prompt proves the thread moved on), and a thread must count as running. Accepted risk: a
non-shell tool that genuinely runs over 2 minutes is shown as waiting
until it writes again. Rejected: leaving it `working` (Tony missed a
prompt for 2.5 hours).

## Restore

**Restore types a command into a login shell.** (0.5.0)
iTerm's `command` parameter runs the program without a shell, so PATH,
version managers and shell setup are missing. Restore opens a tab with
the default profile and types `cd -- '<cwd>' && command <bin> …` with
`write text`.

**`command` before the binary.** (0.6.0)
A shell alias or function of the same name would otherwise rewrite the
restored line (an `agy` alias adding `--dangerously-skip-permissions`,
for instance). `command` runs the real executable.

**Commands are built, never stored.** (0.5.0)
The original command line can contain a prompt or a credential, so it is
never recorded. Restore builds the line from a UUID session id, a
validated absolute cwd and an allow-listed permission mode. agy hooks
record no mode, so an agy restore carries none.

**Per-boot records are append-only.** (0.5.0)
Shutdown closes sessions one at a time, so a record mirroring the live
list would be empty when needed. Sessions that stop keep their last-seen
time; closures within five minutes form one group; a session must miss
two refreshes in a row to count as closed.

**Launch reservations never expire on a timer.** (0.5.0)
A tab stopped at a prompt still starts the conversation once answered,
so a timed expiry would allow a duplicate launch. A reservation clears
when the session is seen running or the user clears it.

**App-hosted sessions are shown, never restored.** (decided 2026-10-26, 0.6.0)
Restore reopens sessions in iTerm; a Claude Desktop or ChatGPT session
reopened there would be a different thing in a different place. Filtered
at capture and again at plan time, because older records already contain
Desktop sessions and a session can be captured before its host is known.

## Privacy and user files

**Metadata only.** (0.1.0; Codex titles from 0.5.0)
No prompt, response or tool argument is stored, logged or displayed.
Codex's `threads.title` is not selected because Codex fills it with the
first message of any thread that wasn't renamed (through 0.4.1 such a
title could appear as a row name). agy's `lastUserInput`, `toolCall.args`
and free-text `error` are dropped while parsing. Tests plant marker
strings and check written files and logs for them.

**Only the installer touches agent configs, and only its own entries.**
Backup first, a basis check against concurrent edits, symlinks followed.
For agy, AgentDeck owns the hook set named `agentdeck` and refuses to
replace a set of that name it didn't write.

**Hook commands are single-quoted.** (0.5.0)
The helper lives under "Application Support"; single quotes stop the
shell interpreting any character in the path. The older double-quoted
form is still read as healthy so an upgrade doesn't show a false error.

**Managed policy is read, never written.** (0.5.1)
A restriction found in any policy source counts, which can only make
AgentDeck more careful. Only Claude's hooks are gated by Claude's policy;
Codex and agy are unaffected and the installer continues past a blocked
Claude.

**A session moved to the background is one row: the job's.** (Unreleased)
Claude keeps two live entries for it, and AgentDeck showed both: a stale
row that reached the window and a live row that reached nothing. The job is
the identity (Claude's own lists skip the parked window, and `/resume`
follows `continued-in`), so its row, key and state stand and the window's
goes. The window is the destination, kept as an association
(`parkedWindows`) rather than a pane written onto the job. Pairing uses live
registry entries only, so either side ending separates them by itself.

A focus doesn't prove the job was reached: the window is an agents view the
user can move around in. So a waiting row stays unacknowledged after the
click, and the hover says where it leads.

Rejected: finding the window by process ancestry. Every worker descends
from one daemon whose parent is whichever window started it, so ancestry
names the wrong window. For the same reason a windowless background session
resolves to no target, ahead of its recorded host and owning app: raising
iTerm looked like a click that did nothing.

**Restore follows `continued-in` rather than remembering successors.**
(Unreleased)
A parked session's old id sits in every saved generation and named
workspace. Reading Claude's link at offer and restore time covers them all
with no stored state; rewriting saved sets would not reach the older ones,
and resuming the old id would bring back the conversation as it was before
it moved. So a saved entry whose window is still open but whose job has
ended launches the job's conversation, the newer one. A skip still names the
entry as saved, since that's what Locate… rewrites. The read at restore time
is on the main thread, like the entrypoint read beside it: one 64 KB tail
per entry.

**agy rows show the annotation title, generated or not.** (Unreleased)
agy saves `/rename` to `annotations/<id>.pbtxt`, the same field it writes
its own generated title to, with nothing to tell them apart; the only
record of renames is `history.jsonl`, which holds prompts. Tony chose to
show the field so renames work and every row has a name, accepting that a
generated title summarises prompts. It stays on screen: in memory only,
never in a snapshot, workspace, log or notification (Notification Center
keeps what it's given). Restore therefore has no agy names.

## Usage lines

**Local only.** (Unreleased)
No network call and no credential is read: Codex figures come from its
rollout logs, Claude's and agy's from their status line payloads. Rejected:
calling the usage endpoints with the agents' stored sign-in tokens (what
CodexBar does). It gives more (per-model rows, credits) but would make
AgentDeck the first part of this setup to touch credentials. CodexBar is
named in the README as the fuller tool.

**A status line tee, not a replacement.** (Unreleased)
Claude and agy each allow one status line command and only that command
receives the figures (Claude's hook payloads carry none). The tee saves the
whole original entry, changes only `command`, and runs the original behind
it with the same stdin, cwd and environment, stdout and exit code passed
through, stderr kept out. Opt-in from the menu, never from **Install
hooks**. Uninstall restores only while the entry is still the tee's; a
missing record is never read as "there was nothing".

**agy through the tee rather than polling `agy -p /usage`.** (Unreleased)
Polling works without a session open, but runs agy (and its network call)
on a timer. The tee costs nothing extra and agy's payload carries the same
buckets.

**Codex: the newest valid record, account not claimed.** (Unreleased)
Rollouts name no account, and a `premium` record with null windows can
follow the subscription one, so the reader selects `limit_id == "codex"`
(or none, for older records) and looks past files without a record. The
tooltip says the account isn't verified. A newer record that reports no
subscription figures ends the search (see below).

**Claude figures are filed per account.** (Unreleased)
Tony switches between two Claude accounts with `/login`, which moves
every open session; an idle session keeps re-sending the old account's
cached figures until its next reply. The tee tags each record with the
signed-in account (the id prefix from `~/.claude.json`, the same field
his own status line script uses; an identifier, not a credential) and
drops a record that exactly matches another account's (same percent and
reset time). The line shows the signed-in account only, others go in
the tooltip. Codex accounts still aren't told apart: its records carry no
account.

**A line goes when its source stops, rather than showing what it last
saw.** (Unreleased)
Codex Astra and Fable reviewed the corporate-laptop case and found that
saved figures outlived their source indefinitely (a tee removed or
overridden, an account with no limits), and that with the account
unknown the newest record of any account was shown, so a personal login's
figures could appear on a work laptop. Now:
- Claude's and agy's lines need the tee installed, not overridden by
  policy, and a heartbeat the tee writes itself showing it ran and saw
  figures since setup. The heartbeat is the only evidence that covers
  what the app can't see: a `CLAUDE_CONFIG_DIR` exported only in a shell,
  a managed status line, a helper the Mac won't run.
- Any line expires once every window on it has reset, or after a week
  without a change.
- An unknown Claude account shows only account-less figures.
- Codex: a newer record with `rate_limits` null or without windows, or a
  `limit_id` other than `codex`/`premium`, means "not reporting" and hides
  older figures. Showing nothing is preferred to showing a figure that may
  be another account's. A plain miss (the 20 newest rollouts have no
  record, as after a run of short `codex exec` threads) still keeps the
  last figure until it expires.
- A tee whose runs have carried no figures for 30 minutes counts as "no
  figures": an account with limits passes its cached figures on every
  refresh, idle sessions included.
- A policy reading AgentDeck treats as blocking gives way to evidence: a
  tee that ran in the last 10 minutes counts as installed, since a
  managed `statusLine` overriding the user's is assumed, not observed.
- The tee records nothing once its chain record is retired, checked under
  the usage store's lock, and uninstall deletes figures and heartbeat
  under that lock, so a refresh in flight can't put them back.
- Turning a tee off deletes the saved figures (they're AgentDeck's copies
  and come back with the next report), and runs in-process so it works
  when the helper is blocked.
Rejected: inferring "not running" from session activity, since `claude -p`
and Desktop sessions fire hooks without running a status line. The menu
reports "hasn't run in the 10 minutes since setup" instead.

**No pace prediction yet.** (Unreleased)
"Runs out in…" from one sample is a guess until attribution and
observation time are trustworthy; percent and reset time only.

## Distribution

**Developer ID + notarization, then a Homebrew cask.** (planned, see
[plans/distribution.md](plans/distribution.md))
Not the Mac App Store: its sandbox would stop AgentDeck reading
`~/.claude`, editing agent configs and scripting iTerm. No Sparkle:
Homebrew handles upgrades. Signing will use the maintainer's personal
Apple Developer account, which keeps the MIT project independent of any
employer.

**Stable bundle identifier `com.tonyhoang.agentdeck`.**
macOS keys Automation and notification grants to the app's identity, so
a changing identifier would re-prompt on every build.

## Documentation

**Docs live in this repo.** (2026-11-01)
AGENTS.md is the map; this folder holds reasoning, platform evidence and
plans. A separate knowledge base was considered and rejected: for one
repo with one maintainer it would restate the code and drift. A change
that alters a decision, a platform fact or a plan's status updates the
matching file in the same commit.
