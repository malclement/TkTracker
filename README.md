# TkTracker

[![CI](https://github.com/malclement/TkTracker/actions/workflows/ci.yml/badge.svg)](https://github.com/malclement/TkTracker/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138)

A native macOS menu bar app that tracks Claude Code **and OpenAI Codex** token
usage and cost, live.

TkTracker watches `~/.claude/projects` and `~/.codex/sessions`, parses every
session's JSONL transcript, and turns it into spend you can see: a menu bar
figure that ticks up as your sessions run, a popover with today's burn, and a
full dashboard with charts and per-project / per-session / per-model
breakdowns. Everything stays on your Mac.

## Features

- **Two sources, one tracker** — Claude Code and OpenAI Codex sessions flow
  through the same pipeline: an All / Claude / Codex filter in the popover and
  dashboard drives every figure on screen, spend on the same directory merges
  into one project row across tools, and the CSV/CLI split by source. Each
  source can be turned off in Settings; everything works with either or both.
- **Menu bar** — today's cost, tokens, or the current 5h block (cost + time left)
  always visible, updating live via FSEvents while sessions stream.
- **Popover** — today's spend with an animated odometer and a trailing-hour burn
  rate while sessions are active, a 24-hour activity sparkline, the current
  5-hour billing block with time remaining, and live sessions with per-session
  cost and a context-window gauge.
- **Daily budget** — set a USD threshold in Settings; crossing it flips the menu
  bar icon to a warning, flags the popover, and posts one notification per day.
- **Plan allowances** — pick your subscription in Settings → Plan and the
  dashboard gauges how much of the current 5-hour block and the rolling week
  it has consumed, with a projected exhaustion time while sessions run, and one
  notification per block and per week at 80%. Vendors state limits in messages
  and rolling windows rather than dollars, so **every limit is yours to set**:
  the presets are starting points to calibrate against your own throttling, and
  with no plan selected TkTracker shows no limits at all.
- **Plan value** — enter what the plan costs and see the trailing-30-day
  API-equivalent value against it, e.g. `×9.2`.
- **Dashboard** — Today / 7D / 30D / 90D / All ranges:
  - stacked spend-by-model chart (hover for a breakdown), cost ↔ tokens toggle;
    buckets adapt to the span — hourly today, daily up to ~4 months, weekly beyond
  - "vs yesterday by now" delta, and a **projected end-of-day total** derived
    from the share of a typical day's spend that has historically landed by
    this hour (not a burn-rate extrapolation to midnight, which is wrong every
    evening); silent until there are enough comparable days to say anything
  - model share donut, prompt-cache hit rate and estimated savings
  - **activity heatmap** — weekday × hour-of-day, so you can see when you
    actually work
  - sortable tables for projects (double-click to drill into its sessions),
    **branches** (per-feature cost), sessions (searchable by title, project,
    branch or model, with duration, $/hour, and `claude --resume` /
    `codex resume` copy in the context menu) and models
  - CSV and JSON export of the current range
- **CLI** — `TkTracker report [--json|--csv] [--range today|week|month|quarter|all]
  [--source claude|codex|all] [--watch]` prints the same numbers in the
  terminal, sharing the app's scan caches; `--watch` redraws live.
  `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are honored for non-default data
  locations.
- **Shortcuts** — App Intents for today's spend, spend over a range, the
  current 5-hour block, and opening the dashboard. They read the same caches,
  so a shortcut and the popover can never disagree.
- **Accurate accounting**
  - deduplicates multi-line assistant turns by `(messageId, requestId)`
  - a global claim table keeps usage counted **exactly once** even when session
    resumes/forks copy history lines into new files (~9% of tokens on real data)
  - 5-minute vs 1-hour cache writes billed at their real multipliers (1.25× / 2×),
    cache reads at 0.1×, web search at $10/1K requests
  - subagent transcripts in nested session directories are included
  - Codex rollouts are summed from per-call `last_token_usage` deltas — immune
    to the cumulative counter's rebase on context compaction — with cached
    input split out and billed at its 0.1× rate; Codex subagent threads are
    separate rollout files and are counted (verified on real data: Codex
    resumes/forks never replay another file's token events, so cross-file
    dedupe isn't needed there)
- **Fast** — incremental parsing resumes from a byte offset per file; unchanged
  files are never re-read. A full cold scan of 160MB+ of Claude transcripts
  takes under half a second, 455MB of Codex rollouts about a second; warm
  refreshes are near-instant.
- **Exact history, forever** — once TkTracker has seen a transcript, its
  precise numbers are archived locally and survive Claude Code's ~30-day
  session cleanup, "Rescan everything", and scan-cache format bumps. From the
  moment you start using the app, nothing is ever downgraded to an estimate.
- **Pre-cleanup history** — for the months *before* first app use, Claude Code's
  aggregate stats file (which outlives transcript cleanup) is imported to
  reconstruct the pruned period: per-day, per-model input+output tokens
  expanded to full usage by each model's lifetime cache mix. Estimated, clearly
  labeled ("Earlier history"), never overlapping exact data, and
  optional (Settings, or `--transcripts-only` on the CLI).

## Install

Requires macOS 15+.

### From source (recommended)

With the Xcode Command Line Tools installed (`xcode-select --install`):

```sh
make app        # build dist/TkTracker.app (release, icon, ad-hoc signed)
make install    # copy it to /Applications
make run        # or just launch the built bundle
```

Other targets: `make test` (unit tests), `make build` (debug), `make zip`
(distributable zip), `make clean`.

### From a release

Download `TkTracker-<version>.zip` from the
[latest release](https://github.com/malclement/TkTracker/releases/latest),
unzip, and move `TkTracker.app` to `/Applications`.

Releases built with a Developer ID are signed with the hardened runtime,
notarized and stapled — open them normally. Builds made without those
credentials are ad-hoc signed and say so in their release notes; for those,
clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/TkTracker.app
```

Enable **Launch at login** in Settings (⚙ in the popover) once installed.

### Homebrew

A cask lives in [`Casks/tktracker.rb`](Casks/tktracker.rb) for publishing to a
tap:

```sh
brew tap malclement/tap
brew install --cask tktracker
```

### Signing your own build

`make app` ad-hoc signs by default, which is fine locally but quarantined
everywhere else. To produce a distributable build:

```sh
make notarize SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
              NOTARY_PROFILE=tktracker
make verify-signature
```

(Store the notary profile once with `xcrun notarytool store-credentials`.) In
CI, set the `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_PASSWORD` secrets; the release workflow detects them and falls back
to an ad-hoc build when they are absent.

## CLI

```sh
.build/release/TkTracker report            # multi-range summary, all sources
.build/release/TkTracker report --json --range month
.build/release/TkTracker report --source codex --range week
.build/release/TkTracker --version
```

## How costs are computed

Rates live in [`pricing.json`](Sources/TkTracker/Resources/pricing.json) inside
the bundle, so a vendor price change is a data edit rather than a code change —
and you can correct one yourself in **Settings → Pricing** without waiting for a
release (useful for negotiated rates, or when a published price moves before
TkTracker catches up). Overrides win over the shipped table and survive updates.
`PricingCatalog.builtIn` mirrors the file in Swift as a fallback for builds that
cannot reach the resource bundle, and a test asserts the two agree exactly.

Costs are estimated from vendor list prices per MTok — Anthropic (Fable 5
$10/$50, Opus 4.5–4.8 $5/$25, older Opus $15/$75, Sonnet $3/$15, Haiku 4.5
$1/$5, …) with standard cache multipliers, and OpenAI (GPT-5.5 $5/$30, GPT-5.4
$2.50/$15, GPT-5.3-Codex $1.75/$14, GPT-5.2 $0.875/$7, GPT-5/5.1 $1.25/$10,
Codex Mini $0.25/$2, …) with cached input at 0.1× and no cache-write charge.
Caveats:

- If you're on a subscription plan (Claude Pro/Max, ChatGPT Plus/Pro), figures
  are **API-equivalent value**, not what you're billed.
- Sonnet 5 is priced at its sticker rate; the intro discount (through 2026-08-31)
  makes those rows a slight overestimate.
- Fast-mode premium pricing isn't modeled (tracked at standard rates), and
  neither is GPT-5.4/5.5 long-context pricing (standard tier assumed).
- Models without a known price are tracked in tokens and flagged "no pricing".
- Days older than the oldest exact record (surviving transcripts plus
  TkTracker's local archive of pruned ones) come from Claude Code's stats
  cache and are **estimates**: the file records exact in+out tokens per day and
  model, and TkTracker adds cache traffic proportional to that model's lifetime
  read/write ratios (cache writes priced at the 5-minute rate). Everything from
  the first exact record onward — in practice, everything since you started
  using TkTracker — is exact.
- Usage is bucketed by UTC hour. In time zones offset by fractional hours
  (India, Nepal, Newfoundland, …) up to 30–45 minutes around local midnight is
  attributed to the neighboring day; whole-hour zones are exact.

Both parsing pipelines are verified against an independent reference
implementation over real data (exact match on cost, tokens and message count —
for Claude transcripts and for a 455MB / 335-file Codex corpus alike). That
check ran on real transcripts and cannot be redistributed, so the same
guarantees are pinned in CI by a **golden corpus**: a small committed fixture
set whose expected figures are derived by hand from the published rates rather
than captured from a run — see
[`EXPECTED.md`](Tests/TkTrackerTests/Fixtures/EXPECTED.md). It covers dedupe
within a file, the cross-file claim table, every cache tier at its own
multiplier, web-search billing, Codex's cached-input split, and Claude/Codex
merging into one project. `swift test` runs it alongside the rest of the suite.

## Architecture

```
Sources/TkTracker
├── Core
│   ├── JSONLParser.swift    incremental Claude parser (byte-needle prefilter,
│   │                        fast ISO8601 path, dedupe, hour×model buckets)
│   ├── CodexParser.swift    incremental Codex rollout parser (per-call token
│   │                        deltas, turn-context model attribution)
│   ├── UsageSource.swift    the claude/codex axis and the UI's source lens
│   ├── ScanCore.swift       discovery, change detection, parallel scan,
│   │                        per-source cache IO + format migration
│   ├── ClaimMap.swift       cross-file exactly-once ownership, owner paths
│   │                        interned so the table stays small as it grows
│   ├── HistoryArchive.swift durable exact record of pruned sessions; survives
│   │                        cache resets so estimates never replace exact data
│   ├── UsageEngine.swift    actor owning one scan pipeline per source
│   ├── StatsBuilder.swift   pure aggregation: ranges, charts, blocks, gauges,
│   │                        projection, heatmap, rows
│   ├── UsagePlan.swift      subscription limits and allowance gauges
│   ├── Pricing.swift        cost/context-window entry points
│   ├── PricingCatalog.swift rates from Resources/pricing.json + user overrides
│   ├── Diagnostics.swift    os.Logger subsystems and the redacted self-report
│   └── ProjectsWatcher.swift  FSEvents on ~/.claude/projects & ~/.codex/sessions
├── App / UI                 SwiftUI: MenuBarExtra, dashboard, Swift Charts,
│                            App Intents, opt-in update check
└── CLI                      terminal report (+ --watch)
```

Per-file usage is aggregated into `(UTC hour, model)` buckets — compact enough
to persist for every session ever, fine enough for daily charts, range filters
and ccusage-style 5-hour billing blocks. Each source keeps its own scan cache
and history archive in `~/Library/Application Support/TkTracker/`
(`scan-cache.json` / `history-archive.json` for Claude, `…-codex.json` for
Codex) — the archives are durable copies of every pruned session's exact
digest (and, for Claude, the claim entries its messages own) that re-seed the
scan state after a cache reset, so exact history can never regress to an
estimate.

Charts color by **model version**, not just family: hue encodes the family
(Fable violet → Sonnet green → Opus blue → Haiku amber → GPT magenta, in a
CVD-validated stack order) and lightness encodes the generation — the newest
version takes the strongest step, older ones recede toward the surface (e.g.
Opus 4.8 deep blue → 4.5 light blue, GPT-5.5 deep magenta → Codex Mini 5.1
pale pink). Every ramp passed the ordinal palette checks (monotone lightness,
visible step gaps, contrast floors) in both light and dark modes — the GPT
ramp's hue was chosen by maximizing the worst CVD pair against the existing
families (ΔE ≥ 12.3 vs every step of every other family, ≥ 54 at its stack
boundary) — colors are assigned from the all-time model set so range filters
never repaint a series, and identity is never carried by color alone.

## Privacy

TkTracker reads local JSONL files only. Nothing leaves your machine — no
telemetry, no analytics, no phoning home.

The single exception is opt-in and off by default: enabling **Settings →
Advanced → Check for updates** lets the app fetch the public GitHub releases
page once a day to tell you a new version exists. It sends nothing about you or
your usage, downloads nothing, and makes no request at all while the setting is
off. **Settings → Copy diagnostics** produces a paste-ready report of counts,
sizes and timings for bug reports — it never includes project paths, session
titles or prompt text.

Its scan caches and history archives (`~/Library/Application Support/TkTracker/`)
store the aggregated numbers plus the session metadata shown in the UI —
session titles, the first line of each session's first prompt, project paths
and git branch names — so history survives Claude Code's transcript cleanup.
They never store conversation content. Settings → "Rescan everything" rebuilds
the scan caches from what's on disk but keeps the archives of already-pruned
sessions; delete the folder to purge everything.

## Contributing

Bug reports, model-pricing updates, and PRs are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Notable changes are tracked in the
[changelog](CHANGELOG.md); security reports go through
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Clément Malige.

TkTracker is an independent open-source project, not affiliated with or
endorsed by Anthropic or OpenAI. "Claude" and "Claude Code" are trademarks of
Anthropic, PBC; "OpenAI", "ChatGPT" and "Codex" are trademarks of OpenAI, Inc.
