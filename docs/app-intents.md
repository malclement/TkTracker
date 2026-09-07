# Building and verifying Shortcuts metadata

`make app APP_BUILDER=xcode` generates a macOS app target from the same Swift
sources used by SwiftPM. Xcode extracts App Intents into
`TkTracker.app/Contents/Resources/Metadata.appintents`.
The generated project is disposable; `Scripts/generate_xcode.py` includes all
Swift source files automatically and requires no external package manager.

CI uses this path and checks that valid metadata contains all four intents:
today's value, a range's value, the estimated five-hour block, and opening the
dashboard. `make verify-appintents` fails if any intent is absent. Production
release signing also depends on this gate.

A Command Line Tools installation can still use `make app` to build with
SwiftPM. That local build has no Shortcuts metadata, and `--selfcheck` reports
this limitation. Metadata presence alone is not proof of runtime discovery:
a release candidate must also be launched on macOS and its actions checked in
the Shortcuts app before claiming end-to-end Shortcuts validation.

The app refreshes its shortcut parameters at startup, following Apple's
[App Intents sample](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents/).
In September 2026 validation, the universal candidate's metadata passed and the
spending actions appeared in Shortcuts. Execution of an ad-hoc preview was
rejected by macOS because it lacked a signing team ID. Final runtime acceptance
requires the Developer ID-signed candidate; metadata checks cannot replace it.

```sh
make zip smoke APP_BUILDER=xcode
make verify-appintents
```

The ordinary packaged smoke check uses synthetic session files in a temporary
directory. It verifies parsing, request-record persistence, pruned history,
and JSON/CSV accounting parity without reading personal session logs.
