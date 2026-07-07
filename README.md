# TkTracker

[![CI](https://github.com/malclement/TkTracker/actions/workflows/ci.yml/badge.svg)](https://github.com/malclement/TkTracker/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138)

A native macOS menu bar app that tracks Claude Code token usage and cost, live.

TkTracker watches `~/.claude/projects`, parses every session's JSONL transcript,
and turns it into spend you can see: a menu bar figure that ticks up as your
sessions run, a popover with today's burn, and a full dashboard with charts and
per-project / per-session / per-model breakdowns. Everything stays on your Mac.

## Features

- **Menu bar** — today's cost, tokens, or the current 5h block (cost + time left)
  always visible, updating live via FSEvents while sessions stream.
- **Popover** — today's spend with an animated odometer and a trailing-hour burn
  rate while sessions are active, a 24-hour activity sparkline, the current
  5-hour billing block with time remaining, and live sessions with per-session
  cost and a context-window gauge.
- **Daily budget** — set a USD threshold in Settings; crossing it flips the menu
  bar icon to a warning, flags the popover, and posts one notification per day.
- **Dashboard** — Today / 7D / 30D / 90D / All ranges:
  - stacked spend-by-model chart (hover for a breakdown), cost ↔ tokens toggle;
    buckets adapt to the span — hourly today, daily up to ~4 months, weekly beyond
  - "vs yesterday by now" delta on today's spend tile
  - model share donut, prompt-cache hit rate and estimated savings
  - sortable tables for projects (double-click to drill into its sessions),
    sessions (searchable, with `claude --resume` copy in the context menu) and models
  - CSV export of the current range (per day and model)
- **CLI** — `TkTracker report [--json|--csv] [--range today|week|month|quarter|all]`
  prints the same numbers in the terminal, sharing the app's scan cache.
  `CLAUDE_CONFIG_DIR` is honored for non-default data locations.
- **Accurate accounting**
  - deduplicates multi-line assistant turns by `(messageId, requestId)`
  - a global claim table keeps usage counted **exactly once** even when session
    resumes/forks copy history lines into new files (~9% of tokens on real data)
  - 5-minute vs 1-hour cache writes billed at their real multipliers (1.25× / 2×),
    cache reads at 0.1×, web search at $10/1K requests
  - subagent transcripts in nested session directories are included
- **Fast** — incremental parsing resumes from a byte offset per file; unchanged
  files are never re-read. A full cold scan of 160MB+ takes under half a second;
  warm refreshes are near-instant. History survives Claude Code's session cleanup
  (deleted files keep their totals from the cache).
- **Pre-cleanup history** — Claude Code deletes transcripts after ~30 days
  (`cleanupPeriodDays`), but its aggregate stats file survives. TkTracker imports
  it to reconstruct the pruned months: per-day, per-model input+output tokens
  expanded to full usage by each model's lifetime cache mix. Estimated, clearly
  labeled ("Earlier history"), never overlapping exact transcript data, and
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
unzip, and move `TkTracker.app` to `/Applications`. The app is ad-hoc signed,
not notarized, so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/TkTracker.app
```

Enable **Launch at login** in Settings (⚙ in the popover) once installed.

## CLI

```sh
.build/release/TkTracker report            # multi-range summary
.build/release/TkTracker report --json --range month
.build/release/TkTracker --version
```

## How costs are computed

Costs are estimated from Anthropic list prices per MTok (Fable 5 $10/$50,
Opus 4.5–4.8 $5/$25, older Opus $15/$75, Sonnet $3/$15, Haiku 4.5 $1/$5, …)
with standard cache multipliers. Caveats:

- If you're on a subscription plan (Pro/Max), figures are **API-equivalent
  value**, not what you're billed.
- Sonnet 5 is priced at its sticker rate; the intro discount (through 2026-08-31)
  makes those rows a slight overestimate.
- Fast-mode premium pricing isn't modeled (tracked at standard rates).
- Models without a known price are tracked in tokens and flagged "no pricing".
- Days older than the oldest surviving transcript come from Claude Code's stats
  cache and are **estimates**: the file records exact in+out tokens per day and
  model, and TkTracker adds cache traffic proportional to that model's lifetime
  read/write ratios (cache writes priced at the 5-minute rate). Everything from
  surviving transcripts onward is exact.

The parsing pipeline is verified byte-for-byte against an independent reference
implementation over real data (exact match on cost, tokens and message count),
plus a unit-test suite (`swift test`, swift-testing).

## Architecture

```
Sources/TkTracker
├── Core
│   ├── JSONLParser.swift    incremental per-file parser (byte-needle prefilter,
│   │                        fast ISO8601 path, dedupe, hour×model buckets)
│   ├── ScanCore.swift       discovery, change detection, parallel scan, claim
│   │                        table (cross-file exactly-once), cache IO
│   ├── UsageEngine.swift    actor owning digests for the app
│   ├── StatsBuilder.swift   pure aggregation: ranges, charts, blocks, rows
│   ├── Pricing.swift        model pricing + context windows
│   └── ProjectsWatcher.swift  FSEvents on ~/.claude/projects
├── App / UI                 SwiftUI: MenuBarExtra, dashboard, Swift Charts
└── CLI                      terminal report
```

Per-file usage is aggregated into `(UTC hour, model)` buckets — compact enough
to persist for every session ever, fine enough for daily charts, range filters
and ccusage-style 5-hour billing blocks. The scan cache lives in
`~/Library/Application Support/TkTracker/`.

Charts color by **model version**, not just family: hue encodes the family
(Fable violet → Sonnet green → Opus blue → Haiku amber, in a CVD-validated
stack order) and lightness encodes the generation — the newest version takes
the strongest step, older ones recede toward the surface (e.g. Opus 4.8 deep
blue → 4.5 light blue). Every ramp passed the ordinal palette checks (monotone
lightness, visible step gaps, contrast floors) in both light and dark modes,
colors are assigned from the all-time model set so range filters never repaint
a series, and identity is never carried by color alone.

## Privacy

TkTracker reads local JSONL files only. Nothing leaves your machine — no
network access, no telemetry.

## Contributing

Bug reports, model-pricing updates, and PRs are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Notable changes are tracked in the
[changelog](CHANGELOG.md); security reports go through
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Clément Malige.

TkTracker is an independent open-source project, not affiliated with or
endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of
Anthropic, PBC.
