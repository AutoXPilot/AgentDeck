# typed: strict
# frozen_string_literal: true

# Homebrew formula for AgentDeck.
# Lives in the tap repo (github.com/AutoXPilot/homebrew-tap) as
# Formula/agentdeck.rb; this copy is the source of truth.
class Agentdeck < Formula
  desc "Menu-bar monitor for Claude Code and Codex terminal sessions"
  homepage "https://github.com/AutoXPilot/AgentDeck"
  license "MIT"
  head "https://github.com/AutoXPilot/AgentDeck.git", branch: "main"

  depends_on xcode: :build
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    libexec.install ".build/release/AgentDeck",
                    ".build/release/agentdeck-hook",
                    "Resources/AppIcon.icns",
                    "VERSION"
    libexec.install "scripts/make-app-bundle.sh"
    (bin/"agentdeck-setup").write <<~SH
      #!/bin/sh
      exec "#{libexec}/make-app-bundle.sh" "#{libexec}" "$HOME/Applications/AgentDeck.app"
    SH
  end

  def caveats
    <<~EOS
      To finish setup:
        1. agentdeck-setup            # creates ~/Applications/AgentDeck.app
        2. open ~/Applications/AgentDeck.app
        3. Click "Install hooks" in the popover footer.
           This edits ~/.claude/settings.json and ~/.codex/hooks.json
           (timestamped backups are created next to each file).
        4. Add the app to System Settings > General > Login Items.

      First row click will ask for Automation permission to control iTerm2.
      Codex will ask you to trust the new hooks on its next launch.
    EOS
  end

  test do
    assert_match "usage", shell_output("#{libexec}/agentdeck-hook 2>&1", 64)
  end
end
