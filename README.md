# TkTracker

[![CI](https://github.com/malclement/TkTracker/actions/workflows/ci.yml/badge.svg)](https://github.com/malclement/TkTracker/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111)

A native macOS menu bar app for Claude Code and OpenAI Codex usage. Track token
counts and API-equivalent value by account, project, branch, session and model.

## What's new in 2.0

- **Accounts:** configure multiple session folders with independent subscription
  payments and estimated allowances. Overlapping folders are rejected to avoid
  duplicate accounting. Disabled profiles retain their history.
- **Observed Codex quotas:** read local session quota snapshots with freshness
  and reset labels. Optional account refresh delegates authentication to your
  installed Codex CLI; it is disabled by default. Quota notifications are a
  separate opt-in.
- **Current models:** GPT-6 Astra, GPT-5.6 Sol/Terra/Luna, Claude Opus 5, Sonnet 5,
  Fable 5.1 and Mythos 5.1, alongside earlier generations. Canonical identities
  keep Mini/Nano/Max variants and dated model names distinct where necessary.
- **Pricing:** explicit cache rates, supported fast/batch/flex tiers, observed
  long-context premiums and regional modifiers. Unknown models remain unpriced;
  partial totals and missing service tiers are labeled. Override input, output
  and cache rates in Settings → Pricing. Rates were checked September 7, 2026
  against [OpenAI](https://developers.openai.com/api/docs/pricing) and
  [Anthropic](https://platform.claude.com/docs/en/about-claude/pricing).
- **Reporting:** custom dates, the current calendar month, project/model filters,
  saved views, previous-period comparison, and matching CSV/JSON exports.
- **Session details:** cumulative value and context charts, compaction markers,
  parent/subagent relationships, request history and fixed-token model-price
  simulation. Double-click a session or use its context menu.
- **Budgets:** daily and monthly thresholds, project budgets, month-end pace
  estimates and optional unusual-spending alerts. Budgets cover all tracked
  profiles, independently of dashboard filters.
- **Recovery and privacy:** export a usage backup and merge it back without
  replacing existing sessions. Omit titles or expire old detail metadata while
  retaining token, cost and branch accounting. Source transcripts are unchanged.

The menu bar, popover and dashboard also provide live activity, cache savings,
model charts, a weekday/hour heatmap, sortable tables and session resume commands.
Scanning is incremental. Exact token records remain archived after transcript
cleanup and survive rescans. Older archives retain hourly timing; the app labels
that limitation. Optional earlier Claude history comes from its aggregate stats
cache and is marked estimated.

**API-equivalent value is not your subscription bill or provider quota.** Dollar
allowances are estimates you configure. Prices value recorded usage with the
bundled catalog, including effective dates where supplied; they do not reconstruct
historical invoices. A model-price simulation keeps token counts fixed and does
not predict answer quality or tokenization. Gemini CLI and OpenCode are under
[adapter review](docs/source-adapters.md), not enabled sources.

## Build and install

Requires macOS 15 or later. No third-party runtime dependencies.

With Xcode Command Line Tools:

```sh
make test
make app smoke          # local ad-hoc app in dist/TkTracker.app
make install            # build and copy to /Applications
```

With full Xcode, build the universal app with extracted Shortcuts metadata:

```sh
make zip smoke APP_BUILDER=xcode
make verify-appintents
```

CI checks the packaged resources, all four App Intents in the extracted metadata,
and a synthetic session's parsing/cache/archive/export path. SwiftPM-only builds
have no Shortcuts metadata. Runtime discovery still requires macOS registration;
see [Shortcuts validation](docs/app-intents.md).

Production releases require Developer ID signing and Apple notarization. The
release workflow fails without signing credentials; CI artifacts are development
candidates and must not be described as notarized releases. Older releases may
be ad-hoc signed; follow their release notes.

Enable **Launch at login** in Settings once installed. The existing
[Homebrew cask](Casks/tktracker.rb) tracks the last published release and is updated
only after its ZIP and checksum exist.

## CLI

Use the packaged executable at
`/Applications/TkTracker.app/Contents/MacOS/TkTracker`:

```sh
TkTracker report --json --range month
TkTracker report --csv --calendar-month --source codex
TkTracker report --from 2026-09-01 --to 2026-09-07 --model gpt-5.6-sol
TkTracker report --project /absolute/project/path --view "Work" --watch
```

`--to` includes that local calendar day. `--watch` redraws the text report;
`--json` and `--csv` are one-shot formats. `--transcripts-only` excludes estimated
pre-cleanup history. The CLI uses the same configured profiles and archives as
the app. Before profiles are configured, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
select alternative Claude and Codex configuration roots. Each contains its own
`projects` or `sessions` directory.

CSV contains `pricing_status`: `estimated` for priced API-equivalent value and
`partial` when a model or observed tier has no verified rate. JSON includes
pricing coverage and per-account summaries.

## Privacy and maintenance

Usage processing stays on this Mac. TkTracker stores usage metadata, project
paths and optionally session titles; it does not copy full transcripts into its
archive. Exported backups contain this metadata. Settings → Advanced offers
privacy controls and a diagnostic report that excludes paths, titles and prompts.

Network access is opt-in: the update checker reads public GitHub releases, and
account quota refresh asks the installed Codex CLI to read account limits.
Neither feature uploads your usage history. Notification permission is requested
only when an enabled alert first needs to be posted.

See [contributing](CONTRIBUTING.md), [pricing format](Sources/TkTracker/Resources/README.md),
[release validation](docs/release-validation.md) and [changelog](CHANGELOG.md).
