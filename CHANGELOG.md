# Changelog


## 2.0.0 — release candidate

- Add account profiles, independent plans, local Codex quota snapshots and optional CLI-backed account refresh.
- Add GPT-6 Astra, GPT-5.6 variants and current Claude models with explicit cache, tier and context pricing; preserve variant identities and surface partial estimates.
- Preserve request timestamps and branch changes; fix fractional-timezone boundaries, future-record filtering, overflow and CSV escaping.
- Add custom dates, calendar-month and saved filters, previous-period comparisons, session details, agent trees and model-price simulation.
- Add monthly/project budgets, spending forecasts, opt-in quota and anomaly alerts, usage backups and metadata retention.
- Add Xcode universal packaging, extracted App Intents verification and isolated packaged smoke checks. Production publication now requires signing and notarization credentials.


All notable changes to TkTracker are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.1] - 2026-08-03

### Fixed

- **Withdrawn: the Shortcuts claim from 1.5.0.** The App Intents were
  implemented and compile, but they never register, so no shortcut, Spotlight
  result or Siri phrase was ever available. Discovery requires a
  `Metadata.appintents` bundle generated at build time by Xcode's
  `appintentsmetadataprocessor`; SwiftPM does not run it, and the tool is not
  present in a Command-Line-Tools-only install. Confirmed on both a local
  `make install` build and the published 1.5.0 artifact — neither contains the
  bundle — and the app logs
  `Error registering app with intents framework … Code=4097` at launch.

  Nothing else in 1.5.0 is affected; this is an isolated feature that silently
  did nothing. The code is kept, unregistered and clearly marked, so it works
  the day the build can produce the metadata (see `docs/app-intents.md`).

  `--selfcheck` now reports App Intents availability explicitly, and `make app`
  prints it, so the gap is visible on every build instead of only in a log
  nobody reads. It is a warning rather than a build failure, because on this
  toolchain it can never be satisfied.

## [1.5.0] - 2026-07-29

A production-readiness pass: signed and notarizable builds, an updater, a
diagnosable failure path, rates as data — plus the features that were sitting
one step away from data the app already parsed.

### Added

- **Plan allowances**: pick a subscription in Settings → Plan and the dashboard
  shows how much of the current 5-hour block and the rolling week it has used,
  with a projected exhaustion time while sessions are burning. Notifications
  fire once per block and once per week at 80%.
  - Limits are **user-editable and off by default**. Vendors express limits in
    messages and rolling windows, not dollars, so the presets are starting
    points to calibrate against your own throttling — the app never shows a
    threshold you did not set.
- **Plan value multiple**: enter what your plan costs and the overview shows
  trailing-30-day API-equivalent value against it (`×9.2`).
- **Spend projection**: a "Projected today" tile derived from the share of a
  typical day's spend that has historically landed by this hour — not a
  burn-rate extrapolation to midnight. Silent until there are ≥5 comparable days.
- **Branches** section: per-git-branch cost attribution, plus a branch column
  in the sessions table and branch-aware search. Both transcript formats
  already recorded the branch; nothing displayed it.
- **Session duration** and **$/hour** columns, from timestamps already stored.
- **Activity heatmap**: weekday × hour-of-day, on a sequential accent ramp
  (deliberately not the categorical model palette).
- **Opt-in update check** (Settings → Advanced). Off by default; makes no
  network request of any kind until enabled, then contacts `api.github.com`
  at most once a day and only ever shows a version and a link.
- ~~**Shortcuts / Spotlight** via App Intents: today's spend, spend for a range,
  current block, open dashboard.~~ **This did not work in 1.5.0** and the claim
  was withdrawn in 1.5.1 — the intents are implemented but never register. See
  below.
- **JSON export** from the dashboard, alongside CSV.
- **`report --watch`**: live-redrawing terminal report, restores the terminal
  on interrupt.
- **Diagnostics**: an `os.Logger` subsystem, a scan-health summary surfaced in
  the UI when files can't be read or the cache can't be saved, and Settings →
  Copy diagnostics producing a redacted report (counts, sizes, timings — never
  paths, titles or prompts).
- **Notarization support**: hardened runtime, an entitlements file, and
  `make notarize` / `make verify-signature`. The release workflow signs,
  notarizes and staples when Developer ID secrets are present and falls back to
  ad-hoc otherwise. Homebrew cask in `Casks/tktracker.rb`.
- **Golden corpus tests**: a committed fixture set whose expected values are
  derived by hand from published rates (`Tests/.../Fixtures/EXPECTED.md`),
  making the README's accuracy claim reproducible in CI. Plus tests for the
  engine's reset/generation and dirty-flag paths, which had none.

### Changed

- **Cache format v3** — claim-table owner paths are interned instead of being
  repeated in full for every message. On a real 22.6k-claim table this cut
  `scan-cache.json` from 6.8 MB to 3.5 MB (49%). **v2 caches are migrated in
  place, never discarded**: the history archive shares this format, and
  dropping it would permanently downgrade pruned sessions to estimates.
- **Rates now live in `pricing.json`** inside the bundle rather than a
  hardcoded Swift chain, with per-model overrides in Settings → Pricing for
  stale or negotiated rates. `PricingCatalog.builtIn` mirrors it as a fallback,
  and a test asserts the two agree.
- Currency and percentage formatting is locale-aware (`4,83` where that is
  correct). Costs stay USD-denominated, since that is what the rates are.
- Settings is now tabbed (General / Plan / Pricing / Advanced).

### Fixed

- **Bundled resources were unreachable in a distributed build**, which would
  have crashed the app on launch on every machine except the one that built it.
  SwiftPM's `Bundle.module` accessor calls `fatalError` when it cannot find the
  bundle — so it can never return nil, and the documented compiled-in fallback
  was unreachable — and it looks for the bundle at the `.app` root while
  `make app` copies it to `Contents/Resources`. Both were masked locally by the
  hardcoded absolute `.build` path the accessor also carries. Resource lookup is
  now an explicit non-trapping probe, and `make app` fails the build unless the
  resource resolves *inside* the app bundle (`make verify-resources`, backed by a
  new `--selfcheck`).
- **An archive this build declines to read is no longer overwritten.** `load()`
  returned an empty cache on refusal and the caller then folded fresh state into
  it and saved over the file — losing exact spend for sessions whose transcripts
  are gone. A newer-format archive is now left byte-identical; a corrupt one is
  quarantined to a `.unreadable-<stamp>` sibling so the bytes survive.
- **`report --watch` ignored ctrl-C.** Its signal source was scheduled on the
  main queue while the loop blocked that same thread with no run loop, so the
  handler never ran — after `SIG_IGN` had already disabled the default. The
  process could only be killed, and then left the terminal in the alternate
  screen buffer with the cursor hidden. It also rewrote a multi-megabyte cache
  every 3 seconds, emitted ANSI escapes into piped output, and silently ignored
  `--json`/`--csv`. All four fixed.
- **FSEvents on a missing directory**: watching a session directory that did
  not exist yet produced a stream that never fired, leaving live updates dead
  for that source until relaunch (only the 5-minute polling net caught it). The
  watcher now falls back to the nearest existing ancestor and promotes itself
  when the directory appears.
- **Budget notifications**: the day was marked as notified *before* the
  authorization callback resolved, so declining the first permission prompt
  silently consumed that day's alert. The window is now marked only once the
  notification is accepted by the system.
- **Symlinked scan roots**: when the root path did not literally prefix the
  enumerated file path (`/var` → `/private/var`, a symlinked
  `CLAUDE_CONFIG_DIR`), every project name silently became the first component
  of the absolute path. Both sides are canonicalized now.
- **Unreadable session files** were swallowed by `try?` and showed up only as
  lower numbers; they are now counted, logged and surfaced in the UI.
- The history archive walked the entire claim table on every refresh — every
  few hundred milliseconds while a session streams. It now only does so when a
  session is actually pruned.
- The 5-hour block scanned and sorted every hour ever recorded on each rebuild;
  it now walks back only as far as the last gap that resets the block chain.
- An exclusivity violation in `UsageEngine.bootstrap` (overlapping access to
  the per-source state) that trapped at runtime under the new claim map.
- Plan alerts were driven by the source-filtered view, so a transient lens could
  silence them — the same mistake the daily budget explicitly avoids. They now
  watch every tracked source.
- The notifier's at-most-once-per-window guarantee held only durably, not
  synchronously, so a burst of rebuilds could queue duplicate notifications.
- Claims were archived only when a session first entered the archive, so one
  that later gained buckets contributed none — reopening double counting after a
  rescan.
- The watcher's fallback walked up without a bound and could have armed
  file-level FSEvents on the entire home directory. Bounded to two levels, and
  the store retries arming so a source installed later still goes live.
- Symlinked scan roots were only repaired for files that happened to be
  re-parsed, so existing installs kept their wrong project names. Attribution is
  now repaired in place during discovery.
- The update check accepted any URL the response named and handed it to
  `NSWorkspace.open`; only `https` on github.com is accepted now.
- Shortcuts silently applied the dashboard's source filter when asked for "all
  sources", and scanned on the main actor (writing caches). Intents now honour
  the requested scope and scan detached and read-only.
- `Format` rebuilt an ICU formatter on every call, the heatmap did quadratic work
  per render, and the projection rescanned all history once per lookback day.
- The Shortcuts parameter types were a parallel copy of `StatsRange` and
  `SourceScope` bridged by raw string, so renaming a case in either would have
  silently retargeted saved shortcuts. They now conform to `AppEnum` directly.
- The GUI JSON export and `report --json` are now genuinely the same document:
  one encoder, and the CLI applies the configured plan.
- `AllowanceGauge` reimplemented `ShareBar` and defined a second status ramp that
  escalated at 0.95 where the context gauge used 0.92. One ramp
  (`Theme.fillColor`), one bar.

## [1.4.0] - 2026-07-08

### Added

- **OpenAI Codex support**: TkTracker now tracks Codex CLI sessions
  (`~/.codex/sessions` rollout files) alongside Claude Code, through the same
  pipeline — live menu bar / popover updates, charts, 5h blocks, project /
  session / model tables, history archive, CSV and CLI.
  - Accounting sums each rollout's per-call `last_token_usage` deltas (immune
    to the cumulative counter's rebase on context compaction), splits cached
    input out at OpenAI's 0.1× rate, attributes usage to the model active in
    the most recent `turn_context`, and counts subagent thread files.
    Verified against an independent reference implementation over real data
    (335 files, 455MB: exact match on tokens, calls and cost).
  - OpenAI pricing: GPT-5.5 $5/$30, GPT-5.4 $2.50/$15 (+mini/nano),
    GPT-5.3-Codex $1.75/$14, GPT-5.2 $0.875/$7, GPT-5/5.1 $1.25/$10,
    Codex Mini $0.25/$2; unknown generations are flagged "no pricing", never
    guessed. Context gauges use the window each session actually reports.
  - **Source filter**: when both tools are tracked, an All / Claude / Codex
    lens in the popover header and dashboard toolbar drives every figure on
    screen — menu bar, budget, charts, tables, CSV export. Sessions of both
    tools working in the same directory merge into one project row; the
    popover splits today's figure per tool when both are burning.
  - **Settings → Sources**: toggle each source independently (at least one
    stays on); turning one off hides it and stops scanning, and its history
    returns when re-enabled.
  - CLI: `--source claude|codex|all`, a "By source" block in the report,
    `CODEX_HOME` honored; CSV gains a `source` column.
  - Charts: a new GPT (magenta) family ramp — chosen by maximizing the worst
    CVD-simulated pair against the existing families (ΔE ≥ 12.3 vs every step
    of every family, ≥ 54 at the stack boundary; ordinal ramp checks pass in
    both modes). Existing family colors are untouched.
  - Codex data lives in its own scan cache and history archive
    (`scan-cache-codex.json`, `history-archive-codex.json`), so the existing
    Claude cache format is unchanged in both directions.

### Changed

- **CSV format**: exports gain a `source` column in position 2
  (`date,source,model,…`); consumers that indexed columns positionally need a
  one-column shift. The `--json` report adds `costBySource`, `totalsBySource`
  and `todayCostBySource`.
- The daily budget explicitly watches all tracked sources, regardless of the
  view filter (the filter drives what's displayed, never what alerts).

## [1.3.0] - 2026-07-07

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

[1.3.0]: https://github.com/malclement/TkTracker/releases/tag/v1.3.0
[1.2.0]: https://github.com/malclement/TkTracker/releases/tag/v1.2.0
[1.1.0]: https://github.com/malclement/TkTracker/releases/tag/v1.1.0
[1.0.0]: https://github.com/malclement/TkTracker/releases/tag/v1.0.0
