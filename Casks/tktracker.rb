# Homebrew cask for TkTracker.
#
# To publish: create a tap repository named `homebrew-tap` under the same GitHub
# account and copy this file to `Casks/tktracker.rb` there. Users then run:
#
#   brew tap malclement/tap
#   brew install --cask tktracker
#
# `sha256` must be updated on every release. Get it with:
#   shasum -a 256 dist/TkTracker-<version>.zip
#
# Until releases are notarized, keep `auto_updates false` and leave the caveat
# in place: Homebrew does not clear the quarantine flag for you, so an ad-hoc
# signed app still needs the manual step.
cask "tktracker" do
  version "1.5.0"
  sha256 :no_check # replace with the release zip's checksum once published

  url "https://github.com/malclement/TkTracker/releases/download/v#{version}/TkTracker-#{version}.zip"
  name "TkTracker"
  desc "Menu bar tracker for Claude Code and OpenAI Codex token usage and cost"
  homepage "https://github.com/malclement/TkTracker"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "TkTracker.app"

  uninstall quit: "com.clementmalige.tktracker"

  # Everything TkTracker writes lives in one directory. `zap` removes the scan
  # caches, the history archive and pricing overrides — note that deleting the
  # archive discards the exact usage of sessions Claude Code has already pruned,
  # which cannot be recovered from disk.
  zap trash: [
    "~/Library/Application Support/TkTracker",
    "~/Library/Preferences/com.clementmalige.tktracker.plist",
  ]

  caveats do
    <<~EOS
      TkTracker runs as a menu bar app — after launching it, look for the chart
      icon in the status bar rather than the Dock.

      It reads ~/.claude/projects and ~/.codex/sessions locally. It makes no
      network requests unless you enable update checks in Settings.
    EOS
  end
end
