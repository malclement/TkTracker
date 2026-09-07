# Production release work

Scope approved September 7, 2026. Implementation branch: `feat/production-ready-2`.

- [ ] Canonical model identities, verified rates, explicit cache/tier/context pricing, safe overrides and coverage.
- [ ] Request accounting records, parser migration, exact timestamps, branch identity and overflow fixes.
- [ ] Source/profile configuration, provider plans, observed Codex quotas and freshness.
- [ ] Custom/calendar ranges, previous-period comparison and saved filters.
- [ ] Session detail, agent relationships, timelines and model cost simulation.
- [ ] Project/monthly budgets, forecasts and unusual-spending alerts.
- [ ] Archive backup/restore, retention and metadata privacy controls.
- [ ] Source adapters; investigate Gemini CLI and OpenCode records before enabling support.
- [ ] Release packaging, App Intents metadata, smoke checks, documentation and regression coverage.
- [ ] Verify CI, publish the release and report signing/installation status accurately.

Accounting changes preserve existing archives. Missing request metadata remains explicitly approximate; missing prices never become zero-cost claims. Network-backed quota reads are opt-in. No third-party runtime dependencies.
