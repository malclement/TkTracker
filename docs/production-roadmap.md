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
- [ ] Release packaging, App Intents metadata, smoke checks, documentation and regression coverage.
- [ ] Verify CI, publish the release and report signing/installation status accurately.

Accounting changes preserve existing archives. Missing request metadata remains explicitly approximate; missing prices never become zero-cost claims. Network-backed quota reads are opt-in. No third-party runtime dependencies.

Native dashboard, account/pricing/budget/privacy settings and session charts/simulation were inspected. Local tests: 147 passing. Local packaged resource and synthetic accounting smoke checks pass. Universal Xcode packaging remains under validation. Signing credentials are absent both locally and in GitHub; no production tag or release has been published.
