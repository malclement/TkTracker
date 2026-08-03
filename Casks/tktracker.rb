# Homebrew cask for TkTracker.
#
# To publish: create a tap repository named `homebrew-tap` under the same GitHub
# account and copy this file to `Casks/tktracker.rb` there. Users then run:
#
#   brew tap malclement/tap
#   brew install --cask tktracker
#
# `version` and `sha256` must both be updated on every release. The release
# workflow prints the digest; or compute it with:
#   shasum -a 256 dist/TkTracker-<version>.zip
#
# Do NOT publish this with `sha256 :no_check`. A pinned version with no checksum
# means Homebrew installs whatever bytes are served at that URL without
# verifying them, and since releases may be ad-hoc signed, Gatekeeper would not
# catch a substitution either. `:no_check` is only defensible for a
# `version :latest` cask where no stable digest exists.
cask "tktracker" do
  version "1.5.1"
  # Placeholder: replace with the real digest before this file goes into a tap.
  # Left as an obviously-invalid value rather than `:no_check` so an unfinished
  # cask fails loudly instead of installing unverified bytes.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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
