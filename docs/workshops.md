# Workshops

Open **Workshops** in the dashboard sidebar. The page follows one session at a
time: its room on a lot by the street. The persistent **Open sessions** list
switches rooms and exposes the selected session's whole team. Selecting a
teammate shows its activity, model, recorded tokens and recent events. **Whole
lot** opens an overview of up to four rooms, paged four sessions at a
time. Project and provider filters narrow both the scene and the list. The
portrait bar at the bottom holds everyone on screen, ringed in their state colour.

Drag the scene to pan; use the zoom controls or **Fit** to reset. Zoom moves in
steps where one art pixel is a whole number of screen pixels, so the art never
blurs. Each room seats the lead and up to three subagents; a sign shows how many
more there are, and every team member is accessible in the list, including nested
subagents. Switching views is immediate; actual arrivals and departures animate.

### Reading the scene

Every agent is a Sim with a plumbob (its state colour) and, for some states, a
thought bubble. Colour is never the only cue: each state also has a place and a pose.

| State | Where the Sim goes | Bubble |
| --- | --- | --- |
| Working | Its desk, typing | — |
| Using a tool | Its desk, typing | Search, read, edit, run, delegate or tool |
| Waiting for agents | Stands over a working teammate's desk | Team |
| Needs you | The front of the room, waving | ! |
| Turn complete | Cheers, then heads to the coffee machine | ✓ |
| Idle | The couch; alone, it lies down | — (Zzz) |
| Interrupted | Beside its desk, slumped under a rain cloud | — |
| Status unavailable | Stays put, faded, with a hollow plumbob | ? |

Each desk carries a paper stack that grows with the agent's recorded tokens, one
sheet per third of a decade from 1k tokens. A Sim's appearance comes from its
agent id, and a room's decor from its project path, so both stay the same across
days. Claude Code rooms use warm wallpaper, Codex rooms cool. Dark mode is night:
streetlamps come on, and desk lamps and monitors light up only while their agent works.

**Needs you** appears when an observed tool or lifecycle event explicitly asks
for input or approval. It jumps to the relevant agent. Turn completion, idle,
working, tool use, waiting for delegated work and interruption are separate
states. The scene respects Reduce Motion and stops its observation task when
the page is left.

## Opening and closing sessions

The page checks local session presence every two seconds while open. A room
empties after two successful checks no longer find its session. Silence does not
close a room. An unreadable presence check preserves previously observed
rooms with **Status unavailable**. A completed turn keeps its room until the
session actually closes. Resuming a session restores the same avatar identity.

- **Codex:** the observer reads this user's Codex processes' open transcript writer
  descriptors under enabled account roots. This tracks a *loaded session*, not
  which tab has focus. Codex can keep a session loaded after a tab closes; its
  room empties when Codex releases the transcript or its process exits.
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

The scene uses SpriteKit in a native macOS view, with SwiftUI navigation and
details. All pixel art is drawn in code at launch (no downloaded assets or
third-party dependencies) and scaled with nearest-neighbour filtering. Rooms keep
their lot slots as peers arrive and leave; layout, stations and paths are pure
functions in `WorkshopLot.swift`. The scene pauses while its window is hidden.

## Demo and validation

Turn on **Demo** to explore explicitly labeled sample sessions. **Next event**
cycles through a subagent needing input, a completed turn, a closed session and
a newly opened session. Demo data never enters usage reports.

For development, `swift run TkTracker --workshops-preview` opens an isolated
debug preview in demo mode without bootstrapping the usage engine or writing
its archive. The normal app always opens the page with live observation.
`swift run TkTracker --workshops-snapshot out.png` renders the demo offscreen to a
PNG (`--light`, `--follow --island N` for one room, `--step N`, `--from N` to animate from an
earlier step, `--zoom STEP`, `--time SECONDS`), for checking the art without a window.

Run `swift test --filter WorkshopTests` for activity parsing, incomplete writes,
account isolation, delegation cycles, privacy and session presence tests, and
`swift test --filter WorkshopLotTests` for room layout, stations, paths, looks and
paper stacks.
