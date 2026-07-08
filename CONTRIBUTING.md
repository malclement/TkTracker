# Contributing to TkTracker

Thanks for your interest in improving TkTracker! Bug reports, pricing updates,
and feature PRs are all welcome.

## Prerequisites

- macOS 15 or later
- Xcode Command Line Tools (`xcode-select --install`) — the full Xcode app is
  **not** required; everything builds with Swift Package Manager.

## Building and testing

```sh
make build      # debug build
make test       # run the unit tests (swift-testing)
make app        # release build + dist/TkTracker.app (icon, ad-hoc signed)
make run        # build and launch the app
```

`swift build` / `swift test` work directly too. The CLI lives in the same
binary: `.build/debug/TkTracker report`.

## Project layout

See the [Architecture section of the README](README.md#architecture) for a map
of the source tree. In short: `Core/` is pure, UI-free engine code (parsing,
dedupe, pricing, aggregation) and is where test coverage matters most; `App/`
and `UI/` are the SwiftUI menu bar app; `CLI/` is the terminal report.

## Ground rules

- **Privacy is the product.** TkTracker must never make network requests,
  embed analytics, or write user data anywhere except its own cache in
  `~/Library/Application Support/TkTracker/`. PRs that break this guarantee
  will not be merged.
- **Accounting must stay exact.** Changes to `Core/` (parser, dedupe, claim
  table, pricing) need unit tests in `Tests/TkTrackerTests`. If you change
  what a token or dollar figure means, update the README's accuracy notes.
- **Keep it dependency-free.** The package intentionally has zero third-party
  dependencies; please don't add any without opening an issue first.

## Updating model pricing

The most common contribution: when Anthropic or OpenAI ships or reprices a
model, edit the table in `Sources/TkTracker/Core/Pricing.swift`, add a test
case in `Tests/TkTrackerTests` (`CoreTests.swift` for Claude models,
`CodexTests.swift` for OpenAI ones), and link the public pricing page in your
PR description.

## Commit and PR conventions

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  as used throughout the history: `feat:`, `fix:`, `docs:`, `test:`, `build:`,
  optionally scoped like `feat(ui):`.
- Before opening a PR, make sure `swift test` passes and `make app` builds.
  CI runs both on every PR.
- Keep PRs focused; unrelated refactors make review slower.

## Reporting bugs

Use the bug report issue template. Including your macOS version, how you
installed TkTracker, and a snippet of the offending JSONL line (with any
sensitive content redacted) makes most parser issues fixable quickly.

## Security issues

Please do not open public issues for security problems — see
[SECURITY.md](SECURITY.md).
