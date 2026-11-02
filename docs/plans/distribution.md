# Plan: signed, notarized distribution

Status: **not started** (as of 0.6.0, 2026-11-01). Waiting on an Apple
Developer Program membership under the maintainer's personal account.

## Goal

A build anyone can download and open without a Gatekeeper warning, and
install with `brew install --cask`, including on a company-managed Mac
whose IT allows notarized apps.

## Where it stands

- The app and helper are **ad-hoc signed** (`make-app-bundle.sh`, stable
  identifier `com.tonyhoang.agentdeck`). A downloaded release zip is
  quarantined and Gatekeeper rejects it; a local build runs only because
  it was never quarantined.
- `release.yml` builds, tests, zips and publishes. It has no signing or
  notarization step.
- `packaging/agentdeck.rb` is a `--HEAD` formula: it builds from source and
  needs a Swift toolchain on the target.
- Notifications fall back to `osascript` because an ad-hoc identity can't
  use `UNUserNotificationCenter`. A real identity removes the fallback's
  need, not the fallback.

**Already shipped (0.5.1), originally part of this plan:** reading a
managed Claude Code policy (read-only), discovery-only mode when policy
blocks user hooks, honouring `CLAUDE_CONFIG_DIR`, dropping permission
modes a policy refuses from restore commands, treating a missing Codex or
iTerm2 as a state rather than an error, and the README's "Managed Macs"
section. Registry files from older Claude builds (2.1.206+) are covered by
fixture tests.

## Steps

1. **Apple Developer Program.** Create a Developer ID Application
   certificate and export it as `.p12` for CI. Create an App Store Connect
   API key with notarization access.
2. **Hardened runtime.** Add `AgentDeck.entitlements` with
   `com.apple.security.automation.apple-events`. Sign both binaries
   (`AgentDeck`, `agentdeck-hook`) with `--options runtime --timestamp`.
   Keep ad-hoc signing when no identity is present, so `./install-app.sh`
   still works for development.
3. **Release workflow.** Import the `.p12` into a temporary keychain, sign,
   `ditto` zip, `xcrun notarytool submit --wait`, `xcrun stapler staple`
   the app, re-zip, attach. Secrets: certificate, its password, API key
   id, issuer and key.
4. **Helper identity.** `HelperSync` copies `agentdeck-hook` to
   `~/Library/Application Support/AgentDeck/bin/`. Check the copy keeps
   its signature and that hooks still run from it when the app arrived
   quarantined.
5. **Homebrew cask** in `AutoXPilot/homebrew-tap`: `Casks/agentdeck.rb`
   pointing at the notarized zip with `sha256`, `app "AgentDeck.app"`, and
   `zap` stanzas for the paths README's Uninstall lists. `release.yml`
   updates version and sha256 in the tap on each tag. Keep the source
   formula for developers or drop it.
6. **For IT approval:** the notarized app plus README's "What it writes on
   your machine" is what a request needs. Optionally offer a PPPC profile
   snippet for the Automation grant (identifier `com.tonyhoang.agentdeck`,
   receiver `com.googlecode.iterm2`).
7. **Optional, later:** a login-item toggle via
   `SMAppService.mainApp.register()`, opt-in since MDM may manage login
   items.

Not doing: the Mac App Store (its sandbox blocks reading `~/.claude`,
editing agent configs and scripting iTerm); Sparkle (Homebrew handles
upgrades). See [DECISIONS.md](../DECISIONS.md#distribution).

## Done when

- A fresh download from the release page, opened from `~/Downloads`, starts
  with no "unidentified developer" dialog, and `spctl --assess --type
  execute` says `accepted source=Notarized Developer ID`.
- First row click shows the Automation prompt once; granting it focuses the
  pane; upgrading to the next build doesn't prompt again.
- Hooks fire from the copied helper on a quarantined install.
- `brew install --cask AutoXPilot/tap/agentdeck` works on a Mac with no
  Swift toolchain.

## Check before starting

Apple's notarization flow, the PPPC payload keys and Homebrew's cask rules
were taken from general knowledge, not re-read against current docs. Read
Apple's notarization page and Homebrew's cask documentation first.
