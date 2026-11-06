# AgentDeck

macOS menu-bar monitor for every **Claude Code**, **Codex** and
**Antigravity CLI** (`agy`) terminal session you have running. See at a
glance which agents are working, which finished, and which are **blocked
waiting on you** — then click a row to jump to that exact iTerm2 tab/pane.

- Live states per session: `ready · working · waiting · done · error`
- The menu-bar badge counts only what's **blocking you** (waiting/error), and
  the glyph shows the most urgent state; finished sessions are a muted count
- Optional notification when a session has been blocked too long
- Row titles use each provider's own session name; click = jump to the
  session (its iTerm pane, or the app hosting it — a Codex session inside
  ChatGPT.app brings ChatGPT forward) and mark it handled once you've
  reached it. A blocked session in an app can't be confirmed reached, so
  dismiss it with right-click → Dismiss. ↑/↓ + Return, ⌘1–9, filter field,
  right-click actions
- A marker on sessions running **unsupervised** (approvals off)
- Event-driven via the CLIs' lifecycle hooks, plus Claude's session registry
  and agy's presence locks; no output scraping. A 15-second sweep checks that
  sessions' processes are still alive

<img src="Resources/screenshot.png" width="440" alt="AgentDeck popover showing Claude and Codex sessions with waiting, done, working and ready states">

**Scope (v1):** macOS 14+, iTerm2, Claude Code + Codex + Antigravity CLI.

| Provider | Badge | Hooks file | How a session is found | Waiting detected | Restore |
|---|---|---|---|---|---|
| Claude Code | CL | `~/.claude/settings.json` | hooks + Claude's session registry | permission and input prompts | `command claude --resume <id>` |
| Codex CLI | CX | `~/.codex/hooks.json` | hooks | permission requests (when Codex fires them) | `command codex resume <id>` |
| Antigravity CLI | AG | `~/.gemini/config/hooks.json` (set `agentdeck`) | hooks + agy's presence locks | questions (`ask_question`) only — **not** permission prompts | `command agy --conversation <id>` |

## What it writes on your machine (read this first)

AgentDeck's installer edits up to three files you own:

- `~/.claude/settings.json` — adds hook entries for 7 lifecycle events
- `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`) — adds hook entries
  for 5 lifecycle events (only if that folder exists)
- `~/.gemini/config/hooks.json` — adds one hook set named `agentdeck`
  covering 6 events (only if `~/.gemini/antigravity-cli` exists). Your
  other hook sets are carried over unchanged. If a set named `agentdeck`
  already exists and wasn't written by AgentDeck, the install stops and
  writes nothing rather than replace it.

Separately, and only if you choose it from the **⋯ → Usage** menu, AgentDeck
puts a small tee in front of Claude's or agy's status line so it can show
your subscription usage (see [Subscription usage](#subscription-usage)).
That changes the `statusLine` entry in `~/.claude/settings.json` or
`~/.gemini/antigravity-cli/settings.json`; your original entry is saved
and runs unchanged behind the tee. **Install hooks** never does this.

Every edit preserves your existing settings and hooks, is idempotent, and
creates a timestamped `.bak` backup next to the file (last 5 kept). Known
trade-off: files are rewritten via JSON serialization, which normalizes
formatting/key order and can change float representation (`1.1` →
`1.1000000000000001`); the backups retain your original bytes. If the
config is a symlink (into a dotfiles repo, say), the file it points to is
edited and the link is left in place.

The hooks invoke a small helper binary
(`~/Library/Application Support/AgentDeck/bin/agentdeck-hook`) on session
events. It writes **metadata-only** snapshots — provider, session id, working
directory, state, timestamp, terminal pane id, agent pid — to
`~/Library/Application Support/AgentDeck/sessions/`. The app keeps the
restorable list of sessions under `…/AgentDeck/workspaces/` (see
[Bringing sessions back](#bringing-sessions-back-after-a-restart)).

**Privacy:** nothing leaves your machine, and no prompt, response or
credential is ever stored. The helper writes metadata only — there is a test
in the suite asserting prompt text is never persisted.

The app itself reads two things it does not store: the tail of each Claude
session transcript (`~/.claude/projects/…/<session>.jsonl`), from which it
takes only two fields off the last assistant message — `model` and
`sessionKind` — and Codex's `state_5.sqlite`, from which it selects only
metadata columns, read-only. `threads.title` is deliberately **not**
selected: Codex fills it with the user's first message unless the thread
was renamed, so the column is treated as conversation content and never
enters the process. A Codex row is named only by an explicit `/rename`.

For Antigravity, every hook payload carries the user's last message
(`lastUserInput`), and tool events carry the tool's arguments
(`toolCall.args`); both are dropped while parsing and never stored or
logged. Only the tool's *name* is read, and only `ask_question` matters.
A failed turn's `error` is free text, so only whether it is non-empty is
kept; the row shows a category taken from `terminationReason`
(`no_tool_call`, …), never the error itself. From agy's state folder
(`~/.gemini/antigravity-cli/`) AgentDeck reads only the names of
`presence/*.lock` and whether a process holds each one, the workspace →
conversation map in `cache/last_conversations.json`, and whether
`conversations/<id>.db` exists and when it last changed (never opened). It never reads
`history.jsonl` (your prompts), the conversation databases,
`conversation_summaries.db`, `brain/` or agy's logs.

For the usage lines, AgentDeck keeps only the allow-listed usage fields
(percent used and reset time per window, Codex's plan name). To find them
it reads the end of Codex's rollout logs (`~/.codex/sessions/…` or
`$CODEX_HOME/sessions/…`, which
also hold conversation text) and decodes only `token_count` records; and
the status line tee receives Claude's or agy's full status line payload
(working folder, conversation title, agy's account email), which it
forwards unchanged to your own status line command and otherwise
discards. To file Claude's figures under the right account it keeps the
first 8 characters of the account id from `~/.claude.json`, in the usage
file's name and contents. The chain record
(`…/AgentDeck/statusline-chain/`, owner-only) keeps your original status
line entry, command included, since that's what it runs and restores.
Beside it, a `.ran` file per tee holds two times only: when the tee last
ran and when it last saw figures. Your own command does whatever it did before.

Conversation content is parsed past but never retained, logged, or
displayed. (Through 0.4.1 that was not strictly true: an unrenamed Codex
thread's title — i.e. a prompt — could appear as a row title and in a
notification if it was under 60 characters.)

Precisely where that boundary sits: "parsed past" means transcript bytes
are read into memory to find those two fields, and discarded. Finding a
session's executable reads the process's argument block
(`KERN_PROCARGS2`), which includes its command-line arguments; only the
executable path is kept. Row titles show a session's name, and Claude
generates names from the conversation when you haven't set one, so a
title can echo what a session is about — workspace files store a name
only if you set it yourself.

### Uninstall

1. Quit AgentDeck and remove it from System Settings → General → Login
   Items if you added it there.
2. Edit `~/.claude/settings.json` and `~/.codex/hooks.json` and delete the
   hook entries whose `command` mentions `agentdeck-hook`; in
   `~/.gemini/config/hooks.json` delete the `"agentdeck"` hook set.
3. If you turned on usage lines, run
   `~/Library/Application\ Support/AgentDeck/bin/agentdeck-hook statusline-uninstall all`
   **before** the next step. It puts your original status line back;
   deleting the folder first leaves the status line pointing at a missing
   helper.
4. `rm -rf ~/Library/Application\ Support/AgentDeck/` and delete the app.
5. Optional: `defaults delete com.tonyhoang.agentdeck` (acknowledgments,
   `waitAlertMinutes`); remove the `*.agentdeck-*.bak` files beside the
   configs; `brew uninstall agentdeck && brew untap AutoXPilot/tap`.

**Don't uninstall by restoring a `.bak`.** Those are whole-file snapshots
taken before each edit, so the newest one can *contain* AgentDeck hooks
from a previous install — restoring it reinstalls them, pointed at a
helper you're about to delete. It would also discard anything you changed
in that file since the backup was taken. Backups are for recovering a
config AgentDeck damaged, not for uninstalling it.

## Install (Homebrew)

```sh
brew tap AutoXPilot/tap
brew trust AutoXPilot/tap          # newer Homebrew requires trusting third-party taps
brew install --HEAD agentdeck
agentdeck-setup                      # creates ~/Applications/AgentDeck.app
open ~/Applications/AgentDeck.app
```

Then click **Install hooks** in the popover footer, and add the app to
System Settings → General → Login Items.

Or from source:

```sh
git clone https://github.com/AutoXPilot/AgentDeck && cd AgentDeck
./install-app.sh
```

### Permission prompts you'll see (once each)

- **Automation → iTerm2** on your first row click (that's how pane focusing
  works: AppleScript session select; the `iterm2:///reveal` URL scheme is
  only a fallback because it can silently stop working).
- **Codex hook trust** on its next launch after installing hooks.
- Codex sessions started **before** the hooks were installed won't report
  until restarted. Claude sessions appear either way — see discovery
  below.
- agy reads its hooks only at startup: restart running `agy` sessions
  after installing. Until then they still appear (from agy's presence
  locks), shown as ready and never changing state.

## How it works

```
claude / codex / agy lifecycle hooks
      └─ '…/agentdeck-hook' claude|codex     (JSON on stdin, exit 0 always)
      └─ '…/agentdeck-hook' antigravity <Event>   (agy's payload names no event)
            └─ ~/Library/Application Support/AgentDeck/sessions/<provider>-<id>.json
                  └─ AgentDeck.app: directory watcher + 15s liveness sweep
```

State mapping — Claude: SessionStart→ready, UserPromptSubmit→working,
PermissionRequest/Notification(permission·elicitation_dialog·
agent_needs_input)→waiting, Stop→done, StopFailure→error, SessionEnd→remove.
`idle_prompt` and `agent_completed` are deliberately ignored: an idle agent
isn't blocked on you (Claude's own registry calls it `idle`), and a
background task finishing must not flip the main session — Stop owns "done".

Codex registers SessionStart/UserPromptSubmit/PermissionRequest/Stop/
SessionEnd (same `hooks.json` schema as Claude's settings). All verified
firing live, first against codex-cli 0.145–0.147 and most recently the
version under [Tested against](#tested-against). No StopFailure → no error state for
Codex; the liveness sweep backstops removal for crashes.

Antigravity (agy 1.4.7, observed live): a session's first event is
PreInvocation (SessionStart did not fire, even with `--continue`), and one
turn runs several PreInvocation/PostInvocation pairs before exactly one
Stop. Mapping: PreInvocation→working; PreToolUse(`ask_question`)→waiting
and PostToolUse(`ask_question`)→working (the hook set's matcher is exactly
`ask_question`, so no other tool call runs the helper); Stop with a
non-empty `error`→error, else Stop with `fullyIdle: true`→done, otherwise
ignored; PostInvocation is ignored; SessionStart→ready if a newer agy ever
fires it. A Stop may create a row, since a missed start would otherwise
leave the session invisible. **Permission prompts are not detected**: no
probe exercised one, so no tool name is matched for them. agy has no
SessionEnd; a row goes when its `agy` process does (the sweep), and the
`agy --bg-updater` child process is never mistaken for a session.

Codex fires no hook for an MCP server's prompt (the browser tool's "Allow
Browser use to access …?"), so a thread waiting on one would look busy.
When a Codex thread's last tool call has had no result for 2 minutes and
nothing else has been written, the row shows as waiting ("may need you").
Shell commands don't count, since a long build looks the same and Codex's
own approval prompts for them do fire a hook. Codex threads run by
Codex's shared app-server daemon (0.166+) are clicked through to their
pane by the thread name in the pane title, because their hooks carry the
daemon's pane, not theirs.

Sessions are removed when their agent exits (SessionEnd, or the sweep for
crashed/closed terminals) — except on `/clear` and resume, where the process
keeps running. Sessions that need you (waiting, error, or done and not yet
acknowledged) sort first; everything else follows, newest first. Row order
freezes while the popover is open so live events don't reshuffle rows under
your cursor; each open re-sorts.

**Hooks alone aren't enough to know a session exists.** They only report
sessions that were running when they fired, so a session started before
the hooks were installed — or one whose snapshot aged out while it sat
idle — was simply absent. On the development machine that meant 15 rows
for 36 live sessions, two of them blocked on the user, one for 72 days.
AgentDeck now also reads Claude's own registry
(`~/.claude/sessions/<pid>.json`) and shows any live session that has no
snapshot. Those files outlive their process, so each is checked against
a live pid whose start time is consistent with the session's — enough to
reject an obviously recycled pid, not a proof of identity, so a stale row
is possible. Where a snapshot exists it supplies the row, since it
carries the pane id and the hook-derived state. `done` and `error` are
never inferred this way; they are facts only a hook can supply. Codex has
no equivalent registry, so it remains hook-only.

agy holds `~/.gemini/antigravity-cli/presence/<conversation>.lock` locked
for as long as a session runs (the file stays behind afterwards and its
modification time never changes, so only the lock counts). AgentDeck
probes each lock without creating or changing it and lists a held one as
a running session if no hook has reported it. Such a row knows only that
the conversation is running: its folder comes from agy's
`last_conversations.json` when exactly one workspace names that
conversation, and is otherwise blank; it has no pid or pane, so it can't
be focused, and without a folder it isn't remembered for restore. A held
lock also keeps a hook snapshot from aging out; once the lock is released
the snapshot follows the normal rules (its pid, or the 24-hour cap for a
pid-less one).

A discovered row has no recorded pane id, since no hook ran to capture
one. AgentDeck finds the pane by the agent process's controlling
terminal, matched against the tty of each iTerm session, never by
folder or title, since several sessions often share both. The match
refreshes when the popover opens. A click marks a session handled
only after AgentDeck has actually focused its pane. Otherwise a blocked
session would lose its badge while you ended up somewhere else, which
could happen if the pane had closed since the last refresh.

**Hooks alone aren't enough to know if a session is blocked.** Nothing fires
when a permission prompt is *answered*, so a `waiting` row could outlive the
block by hours, and a block that arrived without a hook never showed at all.
AgentDeck therefore reconciles each Claude row against Claude's own session
registry (`~/.claude/sessions/<pid>.json`, matched on pid *and* session id),
preferring whichever observation is newer. That registry also supplies the
session name and the reason a session is blocked. Codex rows read
`~/.codex/session_index.jsonl` and `~/.codex/state_5.sqlite` (read-only) for
names, model, effort, token totals, branch and approval mode.

Two kinds of session have no such second source, so their `waiting` clears
only on the next hook event and can read stale in between: Codex sessions
(no registry exists), and Claude **background** sessions — `claude
--bg-pty-host`, started from a slash command and reparented to launchd,
which write no `~/.claude/sessions/<pid>.json` entry at all. Background
sessions also have no terminal pane and no window, so they can't be
focused; their rows say where the prompt is actually answered (the agents
panel of the session that spawned them) instead of just reporting the dead
end. AgentDeck spots them by the `sessionKind` Claude records in the
session transcript.

Row titles come from the best available source, refreshed on popover open.
Claude rows prefer the session's own name from its registry (available even
outside iTerm), then the live iTerm tab title, then the folder. Codex rows
use the `/rename` name from `~/.codex/session_index.jsonl`, then the tab
title, then the folder — never the `state_5.sqlite` thread title, which is
the user's first message on any thread that wasn't renamed.

Each row shows the model it's running next to the path ("Opus 5.5",
"Astra 6"); the raw identifier, effort and token totals are in the tooltip.

No single source gets the model right. Claude's hook payload sometimes
names a model the session isn't running (seen: `claude-fable-5-1` reported
for a session whose transcript was 160/160 `claude-opus-5-5`), while the
session transcript never records the `[1m]` long-context qualifier that
the payload does. AgentDeck takes the model from the transcript's last
assistant turn and the qualifier from the payload when the two agree on
which model it is. Transcript-derived facts refresh while the popover is
open, not only when it opens, so a mid-session `/model` switch shows up.

Codex's `state_5.sqlite` is read when the popover opens, and a hook event
that supplied a model *after* that read wins over the cache. The
comparison uses when the model was last actually reported, not when the
snapshot was last written — events that omit the model still touch the
snapshot while carrying the old model forward, so the write time says
nothing about how current the model is.

## Subscription usage

One line per subscription under the header, percent used for the 5-hour
and weekly windows:

```
Claude   5h 100% · wk 17%
Codex    5h  72% · wk 91%                    Plus
agy      Gemini 5h 2% · wk 1%   Claude/GPT 5h 0% · wk 67%
```

90% and over is orange; `reset` means the window rolled over since the
figure was taken; a dimmed line's figures haven't changed in 6 hours.
Within one window a figure never goes down: every open session's tee
reports its own cached copy, and an idle session's older one is ignored.
Hover a line for
reset times and where the figures came from. A subscription with no
figures has no line, and a line goes rather than show figures that can no
longer update: once every window on it has reset since the figures were
taken, or they haven't moved for over a week.

- **Codex:** read from the newest `token_count` record in Codex's rollout
  logs (`$CODEX_HOME/sessions`, `~/.codex` by default); nothing to set up.
  The record names no account, so with several Codex accounts the line
  shows whichever one ran last. If the newest record has no subscription
  figures (`rate_limits` empty or without windows, or a limit kind other
  than the personal `codex` one, as an organization's plan may report),
  there's no line rather than an older figure that may be another
  account's.
- **Claude and agy:** only their status line is given these figures, and
  each allows one status line command. **⋯ → Usage → Show Claude usage…**
  (or agy) puts `agentdeck-hook statusline` in that slot; it saves the
  figures and runs your previous status line command behind it with the
  same input, so your status line looks as before. **Stop reading … usage**
  restores the original entry, keeping any change you made to its other
  fields (`padding`, `refreshInterval`…) meanwhile; if you replaced the
  command itself, the entry is left as it is. A refresh already running
  when you turn it off still shows your own line. Your status line command
  gets 5 seconds per refresh and runs with normal signal handling. The figures update while a session of that
  agent is open. For agy with no custom status line, the tee keeps agy's
  built-in one (`stack_with_default`). Turning it off also deletes
  AgentDeck's saved figures for that agent. The line shows only while the
  tee is in place and has run since you turned it on; when it hasn't, the
  Usage menu says why under **Stop reading … usage**: waiting for a
  session to refresh, not run in the 10 minutes since setup (the agent may
  read another settings file, run a managed status line, or the Mac may
  block the helper), or the account reports no usage figures (an API key,
  or a plan without these limits; also after 30 minutes of refreshes
  without figures, e.g. after switching to such an account). The menu item doesn't appear for an
  agent whose settings folder doesn't exist.
- **Two Claude accounts:** figures are kept per account and the line shows
  the account you're signed in to now (read from `oauthAccount.accountUuid`
  in `~/.claude.json`, first 8 characters; the file is parsed and only that
  field is kept). The tooltip lists the other account's last figures. If
  the signed-in account can't be read (an API key, or a `.claude.json`
  AgentDeck can't find), figures filed under an account aren't shown: on a
  work laptop they could be a personal login's.
  After `/login`, an idle session keeps sending the old account's cached
  figures until its next reply. They carry that account's 5-hour reset
  time, current or recent, which no other account shares, so they're not
  filed under the new account. An echo of an old window seen before
  AgentDeck tracked accounts can still slip through once, until a session
  replies on the new account. Until then, the new account's line is
  empty.
- **Managed Macs:** a Claude policy that sets `allowManagedHooksOnly`,
  `disableAllHooks` or its own `statusLine` means a user status line never
  runs, so there's no Claude line and the menu says so. A tee installed
  before such a policy arrived stays removable. Codex and agy are
  unaffected. See [Managed Macs](#managed-macs) before turning the tee on
  for a Mac that may block unsigned tools.

AgentDeck makes no network calls for this and reads no credentials.
[CodexBar](https://github.com/steipete/CodexBar) is the fuller alternative
(per-model limits, credits, cost history) if you want more than a glance.

## Bringing sessions back after a restart

Rebooting, or quitting iTerm to update it, closes every agent session.
AgentDeck remembers them and can resume each conversation in its folder.

- **After a restart**, the popover offers the sessions that were open
  before it. **Restore** reopens them as tabs in a new iTerm window,
  starting iTerm first if it isn't running. Dismissed, it stays in the
  footer menu (⋯ → Restore), along with each earlier boot AgentDeck
  still remembers.
- **Closed <time>** in the same menu covers quitting iTerm without a
  reboot: each group of sessions that closed together, most recent
  first.
- **Save open sessions as workspace…** keeps a named set you can restore
  any time. Named workspaces are never changed or pruned automatically.

Each session is restored by typing `cd -- '<folder>' && command claude
--resume <id>` (or `command codex resume <id>`, or `command agy
--conversation <id>`) into a new tab. `command` runs the real executable,
so a shell alias or function of the same name can't rewrite the line — an
`agy` alias that adds `--dangerously-skip-permissions`, for instance, is
not applied to a restored session. agy has no recorded mode to carry
over. The tab uses your default iTerm profile, so that profile has to
start a POSIX-style shell (zsh, bash);
one that runs ssh or tmux instead won't work, and neither will a shell
startup that stops to ask something, which swallows the typed line.
Sessions start five at a time, each group given up to ten seconds to come
up before the next. Claude's permission mode is carried over when a hook
recorded it; a session AgentDeck only found through Claude's own session
list has no recorded mode and comes back in your default.

Sessions already open are skipped, as are ones whose folder or
conversation is gone, and the footer names them and says why. (For Codex,
if its database can't be read the conversation can't be checked, and the
launch goes ahead.) A session whose folder moved gets a **Locate…**
button: pick the new folder and it resumes there, and a named workspace
it came from remembers the new location. The footer counts sessions as
they start, then, 30 seconds later, says how many are running by Claude's
own session list, naming any that aren't yet — a tab stopped at a prompt
(a folder trust question, say). When the agent exits, the tab drops back
to a shell instead of closing. Background sessions and Codex sessions
hosted in an app aren't captured, since there's no terminal to return
them to.

A session restore has launched — or may have, if iTerm didn't confirm —
isn't launched again until it shows up as running. That is recorded on
disk, so it holds across relaunching AgentDeck and between two running
copies. Nothing expires it on a timer, since a tab waiting at a prompt
will still start the conversation once answered; the footer lists any
that haven't appeared, with a **Clear** for when you've checked iTerm and
they aren't there.

Sessions known to be running outside iTerm (Terminal.app, an editor's
terminal) aren't captured, since restoring them would move them into
iTerm. A Claude session inside tmux counts as outside: its terminal is
tmux's, not an iTerm pane, so AgentDeck can't focus it either. Shell plugins that rewrite what's typed — auto-closing quotes, for
instance — can mangle the restore command; restore types it as if at the
keyboard.

How it decides what to offer: AgentDeck keeps one record per boot under
`~/Library/Application Support/AgentDeck/workspaces/` and only ever adds
to it. A session that stops running keeps its last-seen time rather than
being removed. Shutting down closes sessions one at a time, so a record
that tracked the live list would be empty by the time you needed it.
When sessions stop running, AgentDeck records them as a group: closures
within five minutes of each other join the same group, however long the
whole quit takes. A session has to be missing from two refreshes in a row
to count as closed, so one that drops out of a single refresh isn't
mistaken for one that stopped. Sessions that closed while AgentDeck
wasn't running — quit, or being updated — are recorded as a group when it
next starts. Groups are recorded when they happen, so a session you
close later starts its own group rather than redefining the earlier one,
and restoring part of a group leaves the rest of it on offer. For an
earlier boot it also offers whatever was still running when that boot's
record ends, which covers a shutdown AgentDeck didn't see, such as
quitting before iTerm at logout. The banner after a restart shows the
largest of the previous boot's groups, and the menu shows up to three
groups per boot, newest first, always including the largest. The current boot's record plus the
five most recent earlier ones are kept.

These files hold a folder, a session id, Claude's permission mode, and a
session name only if you set one yourself. The command a session was
started with is never stored: it can contain a prompt or a credential.
Restore builds the command from the id, which must be a UUID, and refuses
a folder path that is relative or contains a control character (typed
into a terminal, a control character acts as a keystroke).

## Managed Macs

On a work Mac whose Claude Code is managed by an organization policy,
AgentDeck adapts to what the policy allows. It reads the policy
(`/Library/Application Support/ClaudeCode/managed-settings.json`, its
`managed-settings.d/` drop-ins, and an MDM profile in the
`com.anthropic.claudecode` domain) but never writes it.

- **Hooks blocked by policy** (`allowManagedHooksOnly`, or `disableAllHooks`
  set by the organization): AgentDeck's hooks would never run, so it doesn't
  offer to install them and doesn't touch `settings.json`. The footer shows
  Claude with a lock instead of a red X. Sessions still appear, read from
  Claude's own session files: every live session, "waiting on you" badges
  and notifications, click to focus, and restore. What you lose without
  Claude's hooks: "done" and "error" states for Claude, and permission modes
  in restore. Claude's policy doesn't govern Codex or agy, so their hooks
  are installed and work as usual.
- **Permission modes the policy refuses** (`disableBypassPermissionsMode`,
  `disableAutoMode`) are left off restore commands, so a session comes back
  in the default mode instead of failing to start.
- **`CLAUDE_CONFIG_DIR`** is honoured for session files, transcripts and
  settings, whether it comes from the environment, the policy's `env`, or
  your own `settings.json`. A menu-bar app doesn't see variables exported
  only in a shell profile; Copy diagnostics shows which directory it used.
- **No Codex installed**: the Codex dot is neutral, not red, and nothing is
  written to `~/.codex`. The same goes for Antigravity and `~/.gemini`.
  `CODEX_HOME` is honoured when the app can see it (set for launchd with
  `launchctl setenv`); like `CLAUDE_CONFIG_DIR`, one exported only in a
  shell profile isn't visible to a menu-bar app.
- **Usage lines**: see [Subscription usage](#subscription-usage) for what
  shows when a policy or plan doesn't report figures. The status line tee
  runs your own status line command behind AgentDeck's helper, so if the
  Mac later stops running the helper (an app allow-list, a security tool),
  your status line goes blank with it until you choose **Stop reading …
  usage**, which the app does itself without the helper. Setup refuses
  when the helper won't start. On a Mac that restricts which programs
  run, leave the tee off.
- **No iTerm2 installed**: monitoring works; restore says it needs iTerm2.

Discovery reads Claude's session files, which aren't a documented
interface. They have carried the fields AgentDeck needs from Claude Code
2.1.206 onward, including the 2.1.219 build seen on one managed Mac. A Mac
whose policy pins an older Claude may not show sessions.

Installing third-party software on a company-managed computer is a
question for your IT team. A notarized build and the "What it writes on
your machine" section above are what such a request usually needs.

## Hardening notes

- On launch the app compares the bundled helper's SHA-256 against the stable
  copy hooks invoke and atomically updates it on drift — upgrading can never
  leave hooks running an old helper. A stale helper shows as unhealthy in
  the footer (`hooks: ● helper ● claude ● codex ● agy` = setup
  health, not session activity). It never downgrades: if the stable helper reports a
  newer version than this build (`agentdeck-hook --version`), an older
  copy of the app leaves it in place and counts it as healthy.
- **Running two versions side by side** (a source build beside the
  installed app, or an older copy after an upgrade) is supported from
  0.5.1. Snapshot and workspace entries for a provider an older build
  doesn't know are kept as written, never deleted or overwritten, and a
  workspace file it can't read at all is left untouched rather than
  replaced. 0.5.0 lacks this: it deletes such snapshots after an hour and
  can overwrite such a workspace file, so don't run 0.5.0 beside a newer
  build.
- A snapshot's pid is trusted only if a live process started at or before the
  snapshot's last update *and* looks like the agent (its executable path or
  name says claude or codex; for agy, the executable is named exactly
  `agy` and isn't the `--bg-updater` child). A recycled pid fails one or
  the other. A session that passes both is kept however long it sits
  quiet — a Codex session waiting for input over a weekend used to lose its
  row at seven days; pid-less snapshots still go after 24 hours. One
  exception: every Codex thread in the ChatGPT app reports the same pid,
  ChatGPT's shared Codex server, which proves only that the app is open.
  Those rows also go after 24 hours without an event.
- `session_id` is sanitized before becoming a filename; hook payloads can
  never write outside the sessions directory. Stale temp/corrupt files are
  swept. The sessions-dir watcher re-arms if the directory is recreated.
- The helper can't hold up an agent turn for long: bounded stdin read, an
  8s watchdog, silent exit on any error. If it can't take the per-session
  lock it drops that one event rather than writing unlocked.
- Hook commands single-quote the helper's path, so no character in it is
  interpreted by the shell.

## Can't find the menu-bar icon?

On notched MacBooks the menu bar has limited room, and macOS silently hides
whatever doesn't fit — third-party items first. AgentDeck saves its position,
so **⌘-drag it once** to a spot you like (leftward, nearer the notch) and it
stays there across launches and upgrades.

If the bar is genuinely full, free up room by hiding items you don't need
(System Settings → Control Center), or use a menu-bar manager such as
[Ice](https://github.com/jordanbaird/Ice) or Bartender. The icon is narrow
when nothing is blocked (just the glyph) and widens with a count when
sessions need you.

## Notifications

A session that stays blocked longer than `waitAlertMinutes` (default 5) posts
a local notification. To avoid pestering, a given session notifies at most
once per hour even across separate blocks. macOS will ask for permission the
first time the app runs. To change or disable:

```sh
defaults write com.tonyhoang.agentdeck waitAlertMinutes -int 10   # or 0 to disable
```

## Tested against

| Component | Version |
|---|---|
| macOS | 14+ (developed on 26.x) |
| Claude Code | 2.1.306 |
| Codex CLI | 0.159.3 |
| Antigravity CLI | 1.4.7 |
| iTerm2 | 3.7.0 |

Other terminals: rows still appear and states are correct, but there's no
pane to focus — those rows say so instead of failing silently.

## Development

```sh
swift build && ./test.sh    # works with CLT-only or full Xcode
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules (each encodes a
production bug this project already hit — quoting, p_comm, AppleScript
dictionary shadowing, and friends), and [AGENTS.md](AGENTS.md) for the map
of the code, its invariants and the docs behind them.

## License

MIT — see [LICENSE](LICENSE).
