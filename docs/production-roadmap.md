# Production release work

Scope approved September 7, 2026. Implementation branch: `feat/production-ready-2`.

- [x] Canonical model identities, verified rates, explicit cache/tier/context pricing, safe overrides and coverage.
- [x] Request accounting records, parser migration, exact timestamps, branch identity and overflow fixes.
- [x] Source/profile configuration, provider plans, observed Codex quotas and freshness.
- [x] Custom/calendar ranges, previous-period comparison and saved filters.
- [x] Session detail, agent relationships, timelines and model cost simulation.
- [x] Project/monthly budgets, forecasts and unusual-spending alerts.
- [x] Archive backup/restore, retention and metadata privacy controls.
- [x] Source adapters; investigate Gemini CLI and OpenCode records before enabling support.
- [x] Release packaging, App Intents metadata, smoke checks, documentation and regression coverage.
- [ ] Verify CI, publish the release and report signing/installation status accurately.

Accounting changes preserve existing archives. Missing request metadata remains explicitly approximate; missing prices never become zero-cost claims. Network-backed quota reads are opt-in. No third-party runtime dependencies.

Native dashboard, account/pricing/budget/privacy settings and session charts/simulation were inspected. Local tests: 148 passing. Local optimized compilation completes in 24 seconds. Universal Xcode packaging, both architectures, bundled resources, all four App Intents metadata entries and synthetic accounting smoke checks pass. The spending actions appear in Shortcuts; execution is blocked by macOS rejecting the ad-hoc app's missing signing team ID. Signing credentials are absent both locally and in GitHub; no production tag or release has been published.
