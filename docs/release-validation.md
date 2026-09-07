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
5. Run the Release workflow manually on the candidate commit (`gh workflow run
   release.yml --ref <candidate-ref>`). It signs, notarizes and uploads a
   `TkTracker-signed-candidate` artifact without creating a public release.
   Download it and execute all four actions in Shortcuts. Record the tested commit.
6. Tag that validated commit `v2.0.0`. The release workflow signs, notarizes,
   staples and runs strict Gatekeeper/signature checks before publication.
7. Update the Homebrew cask to the published ZIP's SHA-256, and verify the
   downloaded app's version, resources, signature and staple.

As of September 7, 2026 the repository has no release signing secrets configured.
The local machine has Command Line Tools; universal Xcode packaging and metadata
validation passed in [CI run 34133011977](https://github.com/malclement/TkTracker/actions/runs/34133011977).
The downloaded artifact passed local resource, architecture, signature integrity
and synthetic accounting checks. All 148 regression tests pass.

Shortcuts discovers the spending actions in a separate preview identity, but
execution fails. System diagnostics report `Unable to get teamId` and
`Rejecting invalid client due to requiresValidatedBundle` for the ad-hoc app.
Repeat execution of all four actions on the final Developer ID-signed candidate.
An ad-hoc candidate is not a completed production release.

## Accounting compatibility

Archives remain on version 2 for downgrade readability; scan caches remain on
version 3. New request records are additive. Live transcripts are reparsed once
to populate request timing and billing metadata. Unavailable transcripts keep
their archived hourly totals. Restores merge missing sessions and deduplication
claims; they require the original profiles and folder paths to be configured.

New context premiums and corrected rates can change API-equivalent historical
values. Token counts should remain stable. No migration deletes source files or
purges archived usage. Back up before comparing builds on important history.
