# App Intents: implemented, not registered

`Sources/TkTracker/App/Intents.swift` defines four intents and an
`AppShortcutsProvider`. They compile, they are correct, and **none of them are
reachable** in any build TkTracker currently ships.

## Why

AppIntents are not discovered by reflection at runtime. The system reads a
`Metadata.appintents` bundle inside the app:

```
TkTracker.app/Contents/Metadata.appintents/     ← absent in every build we make
```

That bundle is produced at build time by `appintentsmetadataprocessor`, a tool
that ships with Xcode and is invoked by Xcode's build system. SwiftPM does not
invoke it, and on a Command-Line-Tools-only install the tool is not present at
all:

```sh
$ xcode-select -p
/Library/Developer/CommandLineTools
$ find / -name 'appintentsmetadataprocessor*' 2>/dev/null
# nothing
```

Without the bundle the framework has nothing to register, and AppKit logs this
on every launch:

```
Error registering app with intents framework:
  NSCocoaErrorDomain Code=4097 "connection to service named com.apple.linkd.autoShortcut"
```

## How this shipped

1.5.0 documented Shortcuts support in the README and changelog. The feature was
verified by "it compiles and the app launches" — which it does, because a
missing metadata bundle is not an error the app can see. It was caught only by
reading the unified log after installing the release.

The lesson is the same one that produced the `Bundle.module` crash in the same
release: **a packaged app doing the right thing is a separate claim from source
that compiles, and needs its own check.** Hence `--selfcheck`.

## Checking any build

```sh
$ TkTracker.app/Contents/MacOS/TkTracker --selfcheck
…
appintents   INERT — no Metadata.appintents, Shortcuts will not register
```

`make app` runs this and prints the result. It is a warning, not a failure: on
this toolchain the condition can never be satisfied, and a build that always
fails its own gate trains people to ignore the gate.

## Turning it on

Two viable routes, neither free:

**Build the released app with `xcodebuild`.** GitHub's `macos-15` runner has
Xcode, so CI could produce a properly registered bundle. The cost is a split
between local builds (SwiftPM, inert) and released builds (Xcode, working),
which is a confusing thing to explain to a contributor and easy to regress. It
also means maintaining an Xcode project alongside `Package.swift`.

**Invoke the processor directly from the Makefile** when Xcode is present,
falling back to skipping it. Less machinery than a full project, but
`appintentsmetadataprocessor` has no documented stable interface and its
arguments have changed between Xcode versions.

Either way this is best done alongside notarization, since both are already
"the release build can do something a local build cannot".

Until then: the code stays, unregistered and marked, and no user-facing document
claims otherwise.
