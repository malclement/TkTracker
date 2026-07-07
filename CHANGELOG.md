# Changelog

All notable changes to TkTracker are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
