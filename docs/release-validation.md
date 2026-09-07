# Release validation

Release candidate: 2.0.0. Production publication requires every gate below.

1. `python3 Scripts/generate_pricing.py --check` and `make test` pass.
2. CI pins Xcode 26.3 on macOS 15. `make zip smoke APP_BUILDER=xcode` builds both Apple Silicon and Intel,
   validates bundled resources and extracts all four App Intents.
3. Inspect dashboard filters, accounts, budgets, pricing controls and a session
   detail sheet in the native app. Check the actions in macOS Shortcuts after
   launching the Xcode-built candidate; metadata extraction alone is not a
   runtime discovery test.
4. Configure GitHub release secrets: `MACOS_CERTIFICATE_P12`,
   `MACOS_CERTIFICATE_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `APPLE_ID`,
   `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`. The certificate must be a Developer
   ID Application identity. Secrets are never committed.
5. Tag the validated commit `v2.0.0`. The release workflow signs, notarizes,
   staples and runs strict Gatekeeper/signature checks before publication.
6. Update the Homebrew cask to the published ZIP's SHA-256, and verify the
   downloaded app's version, resources, signature and staple.

As of September 7, 2026 the repository has no release signing secrets configured.
The local machine has Command Line Tools, so Xcode metadata validation must run
in GitHub CI. An ad-hoc candidate is suitable for development validation; it is
not a completed production release.

## Accounting compatibility

Archives remain on version 2 for downgrade readability; scan caches remain on
version 3. New request records are additive. Live transcripts are reparsed once
to populate request timing and billing metadata. Unavailable transcripts keep
their archived hourly totals. Restores merge missing sessions and deduplication
claims; they require the original profiles and folder paths to be configured.

New context premiums and corrected rates can change API-equivalent historical
values. Token counts should remain stable. No migration deletes source files or
purges archived usage. Back up before comparing builds on important history.
