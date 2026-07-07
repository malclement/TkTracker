# Changelog

All notable changes to TkTracker are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **History archive**: the exact usage of every transcript TkTracker has seen
  is now written to a durable local archive
  (`~/Library/Application Support/TkTracker/history-archive.json`) the moment
  Claude Code prunes the file. The archive re-seeds the scan state on launch
  and after "Rescan everything", and also carries the claim-table entries its
  sessions own so a post-reset rescan can't double-count messages that resumed
  sessions copied from pruned originals. Net effect: the estimated
  stats-cache "Earlier history" is permanently clipped to the days before you
  started using TkTracker — everything after that stays exact, even across
  cache resets and scan-cache format bumps. Per-`CLAUDE_CONFIG_DIR` profiles
  get separate archives, matching the scan cache.

### Changed

- Settings → "Rescan everything" re-parses everything on disk but keeps the
  archived exact history of already-pruned sessions (the UI says so). Deleting
  the Application Support folder remains the full purge.
- Full visual redesign toward a modern, native macOS look:
  - the menu bar popover gains a soft accent glow while sessions are live, a
    date header with a live-session pill, burn-rate / over-budget chips, and a
    time-labeled 24-hour activity meter
  - the 5-hour block gauge is drawn as five segments — one per hour
  - dashboard controls (range picker, CSV export, session search) moved into
    the native window toolbar; the sidebar footer shows the all-time total and
    a privacy note
  - cards now sit elevated on a recessed canvas with hairline strokes and soft
    shadows; stat tiles gain icons and a tinted "vs yesterday" delta chip
  - the model-share donut is hover-explorable: slices highlight and the center
    readout switches to the hovered model
  - tables go full-bleed with alternating row backgrounds and proper empty
    states; the models pricing note becomes a bottom bar
  - chart series colors are untouched (the CVD-validated palette is
    load-bearing)

## [1.2.0] - 2026-07-07

### Added

- `--version` flag (also `-v` / `version`) on the CLI, matching the app bundle
  version.
- Open-source project infrastructure: MIT license, contribution guide, code of
  conduct, security policy, CI (build + tests on macOS), tagged-release
  workflow that publishes a zipped app bundle, and issue/PR templates.
- `make zip` target producing a distributable `dist/TkTracker-<version>.zip`.

### Changed

- `Info.plist` now carries a real copyright string.

### Fixed

- Dates in CSV exports and the stats-cache history import are now forced to
  the Gregorian calendar; on systems using a Buddhist/Japanese/… calendar the
  CSV emitted era years and imported history was anchored centuries off.
- `CLAUDE_CONFIG_DIR` now also applies to the stats-cache import (it only
  affected transcript discovery), and each data root gets its own scan cache,
  so alternating profiles no longer blend or merge each other's usage.
- Token arithmetic clamps at the Int64 bounds instead of trapping — a corrupt
  or crafted transcript line with huge token counts could previously crash the
  app on every scan until the file was removed by hand.
- Context gauge now assumes the standard 200K window unless the model id
  carries Claude Code's `[1m]` marker; big sessions previously read ~5× low
  and never triggered the gauge's warning colors.
- A read error mid-scan no longer double counts the already-parsed lines of
  that file on the next scan.
- "Rescan everything" can no longer be silently undone by a refresh that was
  already in flight when the reset started.
- CSV export reports write failures instead of failing silently, and the
  empty state shows the actual data directory when `CLAUDE_CONFIG_DIR` is set.

## [1.1.0] - 2026-07-07

### Added

- Usage insights: "vs yesterday by now" delta on today's spend tile, model
  share donut, prompt-cache hit rate and estimated savings.
- Daily budget alerts: a USD threshold set in Settings flips the menu bar icon
  to a warning, flags the popover, and posts one notification per day.
- Per-model-version chart colors: hue encodes the model family, lightness the
  generation, validated for color-vision deficiency in light and dark modes.
- CSV export of the current dashboard range (per day and model), from the
  dashboard and via `report --csv` on the CLI.

## [1.0.0] - 2026-07-07

### Added

- Incremental JSONL usage engine with exactly-once accounting: per-file byte
  offsets, `(messageId, requestId)` dedupe, and a global claim table so
  session resumes/forks never double-count.
- Menu bar app with live popover: today's cost/tokens or the current 5-hour
  block, burn rate, 24-hour sparkline, live sessions with context gauges.
- Dashboard: Today / 7D / 30D / 90D / All ranges, stacked spend-by-model
  chart, sortable project / session / model tables.
- Model pricing table with cache-write multipliers (5-minute and 1-hour),
  cache-read discount, and web-search billing.
- Pre-cleanup history import from Claude Code's aggregate stats cache,
  clearly labeled as estimated.
- CLI report (`TkTracker report [--json|--csv] [--range …]`) sharing the
  app's scan cache; `CLAUDE_CONFIG_DIR` honored.
- App bundle tooling: `Makefile`, icon generator, ad-hoc code signing.
- Unit-test suite (swift-testing) covering parsing, dedupe, pricing, blocks,
  and history import.

[1.2.0]: https://github.com/malclement/TkTracker/releases/tag/v1.2.0
[1.1.0]: https://github.com/malclement/TkTracker/releases/tag/v1.1.0
[1.0.0]: https://github.com/malclement/TkTracker/releases/tag/v1.0.0
