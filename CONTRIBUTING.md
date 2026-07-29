# Contributing

Scope (v1): macOS, iTerm2, Claude Code + Codex. Issues and PRs inside that
scope are most likely to land; terminal/provider ports are welcome as
discussions first.

## Development

```sh
swift build            # debug build
./test.sh              # test suite (works with CLT-only or full Xcode)
./install-app.sh       # build + install ~/Applications/AgentDeck.app
.build/debug/agentdeck-hook status          # hook install health
.build/debug/agentdeck-hook debug-ancestry  # process-walk diagnostics
```

The README's "How it works" section is the architecture doc. Ground rules
learned the hard way (each has a regression test — keep them passing):

- Hook commands must be quoted (paths contain "Application Support").
- Never match agent processes by p_comm — the claude binary is named after
  its version; use the executable path.
- Never string-search JSON for paths (JSONSerialization escapes `/`).
- The helper must always exit 0 and never write to stdout in hook mode.
- Inside `tell application` blocks, AppleScript constants like `tab` can be
  shadowed by the app's dictionary — compute delimiters outside.
- Snapshots are metadata-only. No prompts, responses, or transcript content,
  ever. There's a test asserting this; it is load-bearing for user trust.
