# Floating Workshops

Open **Workshops** in the dashboard sidebar. The page follows one session at a
time, with a larger island, robot and workbench. The persistent **Open sessions**
list switches workshops and exposes the selected session's whole team. Selecting
a teammate shows its activity, model and recent events. **All islands** opens an
overview, paged four sessions at a time. Project and provider filters narrow both
the scene and the list.

Drag the scene to orbit; use the zoom controls or **Fit** to reset the camera.
Framing accounts for the workshop, attached subagent platforms and available
window size. Each island draws up to three subagent platforms; every team member
is accessible in the list, including nested subagents. Switching views is
immediate; actual arrivals and departures animate in the overview.

**Needs you** appears when an observed tool or lifecycle event explicitly asks
for input or approval. It jumps to the relevant agent. Turn completion, idle,
working, tool use, waiting for delegated work and interruption are separate
states. The scene respects Reduce Motion and stops its observation task when
the page is left.

## Opening and closing sessions

The page checks local session presence every two seconds while open. An island
leaves after two successful checks no longer find its session. Silence does not
close an island. An unreadable presence check preserves previously observed
islands with **Status unavailable**. A completed turn keeps its island until the
session actually closes. Resuming a session restores the same avatar identity.

- **Codex:** the observer reads this user's Codex processes' open transcript writer
  descriptors under enabled account roots. This tracks a *loaded session*, not
  which tab has focus. Codex can keep a session loaded after a tab closes; its
  island disappears when Codex releases the transcript or its process exits.
  The current app-server documentation describes a 30-minute inactivity grace
  period after the last subscriber leaves. TkTracker does not unload sessions.
- **Claude Code:** local `sessions/*.json` metadata is matched to a live process
  and its start time to avoid stale files and reused PIDs. Subagent transcripts
  belonging to the current parent run supply the attached platforms. Completed
  subagents stay with that run until the parent closes. Older Claude versions
  that do not expose session metadata cannot supply reliable open/closed state.

These are local format adapters. Remote processes, unavailable metadata and
provider events absent from the transcript cannot provide every status. In
particular, generic tool calls may show **Using a tool** when their internals or
approval state are not observable. Empty sessions appear once the provider
exposes session metadata or an open transcript.

Reference: [Codex app-server lifecycle documentation](https://learn.chatgpt.com/docs/app-server#unsubscribe-from-a-loaded-thread).

## Privacy and implementation

Activity is ephemeral and separate from accounting. TkTracker reads bounded
transcript chunks and retains only activity categories, timestamps and session
metadata in memory. It does not archive prompts, tool arguments or outputs for
this feature. Existing session-title privacy controls apply. No hooks are
installed, provider configuration is unchanged, and no network connection or
new Codex server is started. Existing token and cost accounting is unchanged.

The scene uses RealityKit in a native macOS view, with SwiftUI navigation and
details. Geometry is generated locally; there are no downloaded models or
third-party rendering dependencies. Islands retain their scene slots as peers
arrive and leave. Camera framing adjusts to the available viewport.

## Demo and validation

Turn on **Demo** to explore explicitly labeled sample sessions. **Next event**
cycles through a subagent needing input, a completed turn, a closed session and
a newly opened session. Demo data never enters usage reports.

For development, `swift run TkTracker --workshops-preview` opens an isolated
debug preview in demo mode without bootstrapping the usage engine or writing
its archive. The normal app always opens the page with live observation.

Run `swift test --filter WorkshopTests` for activity parsing, incomplete writes,
account isolation, delegation cycles, privacy and session presence tests.
