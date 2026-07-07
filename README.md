# TkTracker

A native macOS menu bar app that tracks Claude Code token usage and cost, live.

TkTracker watches `~/.claude/projects`, parses every session's JSONL transcript,
and turns it into spend you can see: a menu bar figure that ticks up as your
sessions run, a popover with today's burn, and a full dashboard with charts and
per-project / per-session / per-model breakdowns. Everything stays on your Mac.

## Features

- **Menu bar** — today's cost (or tokens) always visible, updating live via FSEvents
  while sessions stream.
- **Popover** — today's spend with an animated odometer, a 24-hour activity
  sparkline, the current 5-hour billing block with time remaining, and live
  sessions with per-session cost and a context-window gauge.
- **Dashboard** — Today / 7D / 30D / 90D / All ranges:
  - stacked spend-by-model chart (hover for a per-day breakdown), cost ↔ tokens toggle
  - model share donut, prompt-cache hit rate and estimated savings
  - sortable tables for projects, sessions (searchable, with `claude --resume`
    copy in the context menu) and models
- **CLI** — `TkTracker report [--json] [--range today|week|month|quarter|all]`
  prints the same numbers in the terminal, sharing the app's scan cache.
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

Requires macOS 15+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make app        # build dist/TkTracker.app (release, icon, ad-hoc signed)
make install    # copy it to /Applications
make run        # or just launch the built bundle
```

Enable **Launch at login** in Settings (⚙ in the popover) once installed.

Other targets: `make test` (unit tests), `make build` (debug), `make clean`.

## CLI

```sh
.build/release/TkTracker report            # multi-range summary
.build/release/TkTracker report --json --range month
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

The chart palette (Fable violet → Sonnet aqua → Opus blue → Haiku yellow) is
validated for color-vision-deficiency-safe adjacency in both light and dark
modes; identity is never carried by color alone.

## Privacy

TkTracker reads local JSONL files only. Nothing leaves your machine — no
network access, no telemetry.
