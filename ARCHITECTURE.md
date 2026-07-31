# SpaceO — Architecture

Background and evidence for every design choice here is in [FINDINGS.md](FINDINGS.md).
The short version: **an agent gets its own display, not its own Space**, because a window on an
inactive Space is officially "not visible" and macOS tells apps to stop drawing, while a window on
a second display's active Space renders normally.

---

## 1. The isolation model

Three global singletons get stolen by a naive agent. SpaceO keeps them isolated as follows:

```
                     user keeps                     agent gets
  ─────────────────────────────────────────────────────────────────────────
  screen real estate │ physical display(s)   │ headless CGVirtualDisplay
  mouse cursor       │ the one real cursor   │ per-PID event delivery, no cursor
  keyboard focus     │ restoration required  │ per-PID delivery after a safe key-window prime
```

The load-bearing rule, stated once:

> **Never call `SLPSSetFrontProcessWithOptions`.** That is the single API that raises a window and
> makes macOS follow the app to its Space. Everything else can be done invisibly.

---

## 2. Module map

```
  spaceo (CLI)                     SpaceO Viewer (VM-style console app)
      │                                │  streams a display via ScreenCaptureKit and forwards
      │                                │  human input through SpaceOKit's MirrorInput
      ▼                                ▼
  spaceo mcp (MCP over stdio, for Claude Code / Codex / Cursor)
      │  starts the daemon on demand so every agent shares one pool
      ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ SessionManager ── owns N AgentSession, one DisplayPool       │
  │                                                              │
  │   DisplayPool  = displays, each carved into tiles            │
  │   AgentSession = one tile + owned PIDs + windows             │
  │        │                                                     │
  │        ├── Pool         DisplayPool, TileLayout              │
  │        ├── Stage        Stage (CGVirtualDisplay)             │
  │        ├── Placement    AppLauncher, WindowPlacement,        │
  │        │                WindowWatcher                        │
  │        ├── Input        InputRouter, ChromiumBridge          │
  │        ├── Vision       Capture, AXTree                      │
  │        └── Diagnostics  IsolationSnapshot, PasteboardGuard   │
  └──────────────────────────────────────────────────────────────┘
      │
      ▼
  SpaceOPrivate (C/ObjC)  ── dlsym shims: SkyLight + CGVirtualDisplay
      │
      ▼
  WindowServer
```

`SpaceOPrivate` is the only place that touches private API. It resolves symbols lazily via
`dlsym`, which handles a missing name but cannot validate calling convention or behavior.
`SPOCapabilityAvailable` reports whether the required runtime classes and symbols exist.
Display-graph state is inventoried for diagnostics, but mirror, orphan, physical-display activity,
overlap, and cursor-fence state are not product gates on virtual-display creation.

---

## 3. Layer contracts

### 3.0 Pool — `DisplayPool`, `TileLayout`

```swift
let pool = DisplayPool(sessionsPerDisplay: 4,
                       displaySize: CGSize(width: 2560, height: 1600))
let slot = try pool.allocate()      // reuses a display with a free tile
pool.release(slot)                  // retires the display once it empties
```

A virtual display is an entire framebuffer for the WindowServer to composite, so one per agent
does not scale. Sessions get a **tile** instead, and a new display appears only when the current
ones are full. Tiles never overlap — an overlap would put one agent's window inside another
agent's screenshot, which is a context leak between agents rather than a cosmetic bug.

`sessionsPerDisplay` applies to displays created afterwards; existing displays keep their layout,
because re-tiling underneath a running agent would move its windows out from under it. When the
caller does not pin a size, the CLI grows the display to match the requested density. The daemon
keeps one empty display warm for its lifetime so rapid agent churn reuses a stable framebuffer;
excess empty displays from a larger peak are retired after a grace period.

**Runtime geometry — `ResourceBudget`.** `allocate()` does not impose product-policy ceilings on
sessions, displays, framebuffer totals, or creation rate. It validates positive whole-pixel
geometry representable by Swift and CoreGraphics. `pool` and `doctor` report current usage.
The convenience full-layout API materializes at most
`TileLayout.maximumMaterializedCapacity` entries. That allocation bound is not a density limit:
production per-tile lookup stays O(1) and allocation-free for any positive technically
representable capacity.

### 3.1 Stage — `VirtualDisplay`

The stage contract:

```swift
let stage = try Stage(name: "agent-1", width: 1920, height: 1080, hiDPI: true)
stage.displayID      // CGDirectDisplayID
stage.bounds         // global CGRect
stage.spaces         // the Space it owns
stage.invalidate()   // waits up to its timeout and returns whether removal completed
```

- Backed by `CGVirtualDisplay` + `CGVirtualDisplayDescriptor/Mode/Settings`.
- **Intended lifetime = object lifetime.** Releasing `CGVirtualDisplay` normally removes the
  display. The macOS 27 preview host nevertheless retained three ownerless displays after rapid
  churn, so SpaceO does not trust that contract blindly: teardown is verified and `doctor`
  inventories unmatched vendor/model IDs. Ownerless IDs remain diagnostic and do not block
  another creation attempt.
- The descriptor binds to a **private serial queue, never the main queue.** CoreGraphics
  publishes display lifecycle on that queue, so using the main queue would make creation and
  teardown depend on the *caller* running a main run loop — which an XCTest case or a one-shot
  CLI does not. Symptom when we had this wrong: the display registered but never reported
  bounds, and never went away on release.
- Creation and retirement are serialized process-wide without an application-level cooldown.
- A process-local ownership registry distinguishes its live stages from ownerless SpaceO
  displays in the same graphical login session. Inventory and teardown use the online display
  list, not only active displays, so an inactive-but-still-attached phantom cannot be missed.
- Mirroring, absence or deactivation of a physical display, framebuffer overlap, and ownerless
  displays are diagnostic only.
- Production contains no display-origin mutation, diagonal-parking API, cursor fence, or
  pointer-warp path. `CGConfigureDisplayOrigin` pinned displays and poisoned later virtual-display
  creation in `probes/probe7.m`; see [FINDINGS.md](FINDINGS.md) §4.1.
- Each virtual display receives **its own managed Space**, always current for that display, which
  is what keeps agent windows composited.

### 3.2 Placement — `AppLauncher`, `WindowPlacement`, `WindowWatcher`

```swift
let app = try await session.launch(app: appURL, opening: [fileURL])   // placed into the tile
```

- `NSWorkspace.OpenConfiguration` with `activates = false`, `addsToRecentItems = false`,
  `createsNewApplicationInstance = true`, and running-app substitution disabled. If an app still
  returns an existing PID, launch fails instead of relocating user-owned windows.
- Windows present at launch are relocated immediately via `kAXPosition`.
- Explicit `spaceo adopt --pid` enumerates `kAXWindowsAttribute` and relocates an already-running
  app; launch never adopts implicitly. Adoption claims the process through `ProcessOwnership`
  *before* the first window moves, so a PID a second session already owns is refused without this
  one having disturbed anything.
- Process identity is `(pid, kernel start time)`, not a bare PID — see `ProcessIdentity`. A PID is
  a recycled integer, and a long-lived session holding one would otherwise keep capture, input,
  and *force-terminate* authority over whatever inherited the number. Every teardown and liveness
  check goes through the identity; `quit(force:)` additionally refuses an imprecise one.
- `WindowWatcher` keeps watching. One-shot placement at launch is not enough: apps open windows
  *later* — a restore-session prompt, an update notice, a file dialog, a second document — and
  those land wherever macOS likes, which in practice is the user's screen. Measured with Cursor,
  whose "Reopen?" dialog appeared mid-screen a second after launch. The watcher relocates them
  on the AX notification and counts the ones that refuse (app-modal sheets), so the audit can
  say so rather than quietly pretending everything is contained.
- The watcher does not trust notifications alone. Registration failures are recorded and surfaced
  in the session audit; a bounded periodic sweep (`WindowWatcher.periodicSweepInterval`) runs as a
  backstop for the notification that never arrives; and a notification that lands *during* a sweep
  is coalesced into a repeat rather than dropped (`SweepCoalescer`) — a window created just after
  a sweep began is in neither that sweep nor any later one otherwise.
- Containment is judged on **full window bounds**, not the midpoint. A dialog twice its tile's
  width has its centre in the right place while spilling across a neighbouring session, or off the
  agent display entirely onto the user's screen. Every sweep re-derives containment from the
  WindowServer for every window, including ones already marked handled: `handled` records that we
  acted, not that the window stayed where we put it.
- `SessionManager` runs a daemon-level janitor pass on an interval, covering what a per-app
  watcher structurally cannot — an app that exited, which will never emit another notification.
  Reaping releases the ownership claim, the watcher, and the bridge. Both the watcher timer and
  the janitor task are cancellable, and shutdown cancels them.
- Some apps activate themselves regardless of `activates = false` (Electron shells calling
  `NSApp.activate`). SpaceO cannot prevent that, so it hands the user's frontmost app straight
  back and reports that it had to — a blip rather than a state change.
- Electron renderer control is not treated as Chromium browser control by default. A
  private-profile Cursor launch with remote debugging creates no window while backgrounded, and
  foregrounding it to obtain one violates the invariant above. VS Code-family bundles instead
  receive a per-launch semantic editor adapter from a private temporary extension directory. The
  adapter never activates the app, authenticates over a private Unix socket, and declares scroll
  success only when the editor's visible range changes. The MCP conformance harness separately
  requires rendered pixels to change.

### 3.3 Input — `InputRouter`

The native-input sequence:

1. Capture the user's frontmost app and focused window.
2. `focusWithoutRaise(pid:windowID:)` posted undocumented `SLPSPostEventRecordTo` records. Byte layout:
   `[0x04]=0xf8`, `[0x08]=0x0d`, windowID at `[0x3c]`, `[0x20..0x30]=0xff`, `[0x8a]=0x01`.
   Then a make-key pair with `[0x3a]=0x10` and `[0x08]=0x01` / `0x02`.
3. The record changes global input routing, so SpaceO immediately restores the captured user
   route and verifies the public AppKit frontmost-application state. The incompatible private
   key/typing-focus getters are never resolved or called.
4. `type(_:to:)` — `CGEventPostToPid` with `CGEventKeyboardSetUnicodeString`.
5. `click(at:in:)` — hit-test the global point through Accessibility and perform `AXPress` when
   the element exposes it. Otherwise fall back to `CGEventPostToPid` mouse events in **global**
   coordinates inside the tile, stamped with the target window id. Chromium *web content* needs
   §3.3b instead.
6. `press(element:)` — `AXUIElementPerformAction(kAXPressAction)`. **Preferred.** Coordinate-free,
   needs no focus, cannot miss, works while occluded.

The `AXPress` shortcut in step 5 is taken **only for a plain single left click**. A modifier-held,
multi-, or non-left click means something a press cannot express — shift-click extends a selection,
double-click selects a word, right-click opens a context menu — so substituting a press there
would report success for an action that never happened. An element index carries no button, count,
or modifier state at all, and supplying one is refused rather than silently downgraded.

`move`, `drag`, and `scroll` share `click`'s transaction through one `withPointerTransaction`
body: the target's input route held for the duration, every event stamped with the window it
happened over, and a verified route restore afterwards. Sharing one body is what stops a newly
added action from quietly skipping the stamp — an unstamped per-PID event has no window to route
to and is dropped rather than delivered. A scroll takes a point for the same reason a click does:
an app with two scrollable regions routes the wheel by what is under the pointer.

`InputRouter` does not classify targets by bundle identifier. It attempts the requested per-PID
delivery for native, canvas, game, browser, and Electron processes alike. A target may ignore a
synthetic event, but SpaceO does not turn that prior expectation into an admission policy.

Input priming still captures and restores the user's route when possible. Priming is best-effort:
an unavailable focus route does not block direct per-PID delivery and is not treated as a
display- or application-class restriction.

### 3.3a VS Code-family Electron editors

VS Code-family Electron editors ignore background synthetic wheel events, and their macOS
accessibility tree exposes only a 1×1 screen-reader proxy rather than a settable editor scroll
area. `AppLauncher` recognizes the exact VS Code bundle shape and supplies an isolated
`--extensions-dir` containing SpaceO's embedded semantic adapter. The adapter listens on a
per-launch `0600` Unix socket beneath a `0700` temporary root and accepts a live-memory-only
token. It calls VS Code's `editorScroll` command and returns the editor's visible ranges before
and after the command.

`SessionManager` uses this channel only for an exact owned process with one represented window,
no modifiers, no horizontal delta, and a point whose AX ancestry contains the code-editor marker
in that exact window. The adapter also requires exactly one visible active editor, avoiding a
split-pane request scrolling the wrong editor. `ElectronEditorBridge` independently validates
socket type, ownership and permissions, bounds messages to 16 KiB, and refuses a response without
a real visible-range change. The temporary root is durably recorded for crash cleanup, but the
credential is never written to the session journal. Non-VS Code Electron renderers and hover/drag
remain on the ordinary per-PID path and are not claimed as effect-confirmed.

### 3.3b Web content — `ChromiumBridge`

Synthetic input does not reach Chromium web content. Measured against Google Chrome on
macOS 27:

| | |
|---|---|
| keyboard via `CGEventPostToPid` | works — the address bar receives text |
| `AXPress` on a toolbar control | works |
| `AXPress` on a DOM button | **no DOM click** |
| synthetic mouse at coordinates | **no DOM click**, even stamped with the window id |

The renderer validates event provenance and drops anything the WindowServer did not vouch for.
Silently succeeding here is the worst possible outcome — the agent believes it clicked. So:

- browsers SpaceO **launches** get `--remote-debugging-port` and a private `--user-data-dir`
  (a separate profile is not incidental: it keeps the agent out of the user's cookies and
  forces a genuinely separate instance), and web input goes through DevTools;
- browsers SpaceO **adopts** have no port — a port can only be set at launch — so page input falls
  back to unrestricted per-PID delivery. Chromium may ignore that fallback, but SpaceO does not
  reject the target before trying it.

`spaceo ax` on a browser appends the page's own elements under `wN` references, so an agent sees
one list covering both the browser's chrome and its content.

The bridge binds to **one deliberately chosen page** and never re-points itself. `/json/list`
order is not documented to mean anything, so treating `targets().first` as "the front page" meant
that with a second page open the bridge could read, type into, click, and screenshot a page nobody
asked about — and report success. `attachToLaunchedTarget()` therefore requires exactly one page
(the contract a private-profile browser we started ourselves actually satisfies) and otherwise
fails closed while naming the candidates; `attach(toTargetID:)` is the explicit form. Commands
refuse on an unbound bridge rather than reconnecting to whatever is there now.

The target list is read incrementally and abandoned the moment it crosses
`ChromiumBridge.maximumTargetListBytes` — an over-length `Content-Length` is refused before any
body is read, and the transfer is *cancelled*, not merely thrown away. Buffering first and
checking the size afterwards makes the limit a report rather than a limit, which is what let a
wedged or hostile local endpoint stream unbounded data into the daemon.

### 3.4 Vision — `Capture`, `AXTree`

- `Capture.display(stage)` — `SCContentFilter(display:excludingWindows:)` → PNG. The whole agent
  screen, always renderable because the stage's Space is always active.
- `Capture.window(windowID)` — `SCContentFilter(desktopIndependentWindow:)`, which is documented
  display- and Space-independent and includes full content when occluded.
- `Capture.region(stage:rect:subRect:)` — a session's **tile**, or a sub-region of it, cropped in
  the capture itself via `sourceRect` rather than cropped afterwards, so one agent's screenshot can
  never contain a neighbouring agent's window. An oversized `subRect` clamps to the tile, so a
  caller cannot widen its view past its own tile by asking for a larger rect.

**One scale, and it is reported.** Every agent-facing capture defaults to `Capture.defaultScale`
(1), so one image pixel is one point and a coordinate read off a screenshot is a coordinate
`click` accepts. Window captures were previously hard-coded to 2× while tile captures stayed at
1×: an agent reading a coordinate off the default screenshot clicked at half the intended
position, hitting the wrong control near the top-left and failing as out-of-bounds near the edges,
with no field in the response it could have used to tell the difference. Every capture now returns
an `ImageGeometry` carrying origin kind, scale, pixel and point dimensions, and the captured
area's global origin, plus a one-line `advice` string stating the conversion. Raising `scale`
is available for reading small text and is always reported.
- `AXTree.snapshot(pid:window:)` — walks the accessibility tree and emits **indexed actionable
  nodes**. This is the primary addressing channel for an agent: `click --element 7` beats pixel
  coordinates on every axis (no HiDPI math, no occlusion, no misses). Pixels are the fallback.
- `AXTree.text(in: window)` — reads a *specific* window rather than the app-wide focused element,
  which is ambiguous the moment an app has two windows open.

### 3.5 Session hygiene

- `PasteboardGuard` — bounded snapshot/restore for tests and diagnostics only. It is deliberately
  **not** a production copy/cut guard: `NSPasteboard` has no compare-and-swap, so no
  snapshot/restore bracket can prove it is not overwriting a newer user copy between its final
  check and its write. Production key delivery therefore refuses Command-C and Command-X outright
  (`KeyCombo.requireClipboardSafeRoute`) before synthesising either event. Command-V is *not*
  refused, so an agent can still paste whatever the user last copied — see SPAO-143.
- **Janitor** — periodic sweep: re-park windows that escaped the stage, reap dead launched apps,
  reclaim abandoned sessions, and persist session state. It does not detect focus theft; focus is
  handed back at launch time by `AgentSession` and reported in the response.

### 3.6 Viewer — `MirrorInput`, SpaceO Viewer

The console app for humans. It streams a display with `SCStream` and forwards local mouse and
keyboard events through `MirrorInput`, which reuses `InputRouter`'s delivery rules: Accessibility
press for pressable native controls, per-PID posting as the unrestricted fallback, target-window
stamping, focus-without-raise priming, and the same minimum move/down/up pacing as CLI clicks.
Continuous move and drag events remain a live stream on the input queue.

- `ViewportMapping` is the aspect-fit letterbox math shared by rendering and input, so a click
  can never land beside the pixel it was aimed at.
- Stream and toolbar-screenshot framebuffers use ScreenCaptureKit's authoritative display pixel
  dimensions rather than guessing a scale factor from AppKit points.
- Hit-testing walks the WindowServer's front-to-back on-screen list without layer, process-family,
  or display-provenance exclusions — but **always excluding the viewer's own PID**. Viewing a
  physical display that contains the viewer's window would otherwise let a click select that
  window and be posted straight back into the process that generated it: each forwarded click
  produces another, the queue grows, and the user watches the viewer operate its own controls.
  `MirrorInput`'s delivery primitives refuse a self-target outright as well, so a future code path
  that forgets to filter still cannot start the loop.
- Viewer input has no display-provenance guard. SpaceO and physical displays are both valid
  control targets.
- Every event is admitted through an `InputControlGate` on the main thread and **rechecked at the
  delivery boundary** after the queue hop. Validating only at enqueue meant a click could execute
  after Control was switched off, or against the display that was selected a moment ago. Disabling
  Control or switching displays bumps a monotonic epoch *synchronously*, so the whole queued
  backlog is invalid before the cleanup that follows it is even scheduled, and route restoration —
  guarded by its own lock rather than confined to the input queue — does not wait behind the stale
  events it is cancelling.
- The viewer creates no displays. It streams displays that already exist, primes the selected
  target through the shared focus route, and forwards per-PID events when Control is enabled.

---

## 4. Data model

```swift
struct SessionID: Hashable { let raw: String }        // "agent-1"

final class AgentSession {
    let id: SessionID
    let stage: VirtualDisplay
    private(set) var apps: [OwnedApp]                 // pid, bundleID, launched-by-us flag
    private(set) var windows: [OwnedWindow]           // windowID, pid, placedFrame
}

struct IsolationSnapshot: Equatable {                 // the invariant, made testable
    let frontmostPID: pid_t
    let windowServerFrontPID: pid_t                    // inferred from AppKit in live capture
    let keyFocusPID: pid_t                             // unknown in live capture
    let typingFocusPID: pid_t                          // unknown in live capture
    let cursor: CGPoint
    let activeSpace: UInt64
    let stageRects: [CGRect]
    let coverage: IsolationSnapshotCoverage
    static func capture() -> IsolationSnapshot

    func report(comparedTo: Self) -> IsolationReport  // coverage + per-check result
    func breaches(from: Self) -> [String]             // things SpaceO did
    func ambientChanges(from: Self) -> [String]       // things the user did
}
```

`IsolationSnapshot` is deliberately a first-class type: the whole project's correctness claim is
"this value does not change", so it should be a thing tests can assert on directly.

Every required dimension carries one of three coverage levels:

| dimension | live coverage | source |
|---|---|---|
| menu-bar owner | observed | `NSWorkspace.frontmostApplication` |
| WindowServer front process | inferred | mirrors the AppKit observation; the unsafe private getter is not called |
| key-input route | unknown | no safe public getter is available |
| text-input route | unknown | no safe public getter is available |
| cursor location | observed | CoreGraphics event location |
| active Space | observed | WindowServer active-Space query |

An observed query that returns no usable value is downgraded to `unknown` for that capture rather
than turning a sentinel such as PID/Space `0` or a fallback point `(0,0)` into evidence.

An isolation report is `breached` if a covered check detects an attributable failure, `partial`
when no covered check failed but a required check is unknown, and `intact` only when every
required check has usable coverage and none failed. CLI, JSON, and MCP all expose the same six
checks and their per-check failures. In particular, the zero placeholders retained in live
snapshot route fields are never treated as evidence that an input route is clear.

**Blame attribution matters more than it sounds.** A naive before/after diff cannot distinguish
"the agent grabbed the pointer" from "the user moved their mouse while the command ran", and a
check that reports the second as a violation gets ignored within a day. So the snapshot carries
what belongs to agents (`agentPIDs`, `agentSpaces`, `stageRects`) and only
blames SpaceO for changes that land on agent territory:

| observed change | verdict |
|---|---|
| frontmost app → an **agent's** app | breach — we took the menu bar |
| frontmost app → another of the **user's** apps | ambient — the user is working |
| active Space → an **agent display's** Space | breach — the user was dragged |
| cursor ends up **on an agent screen** | breach — the pointer was pulled away |
| cursor moved anywhere else | ambient |
| the fence pushed the pointer back off | **containment working**, reported, not blamed |

The distinction between the last two lines is the point: the failure is the cursor *arriving* on
an agent screen, not the fence *removing* it. Getting this wrong in either direction ruins the
check — too strict and it cries wolf, too loose and it misses the thing it exists to catch.

---

## 5. CLI surface

```
spaceo doctor                                  capability + TCC gate
spaceo session create [--name N] [--size WxH]  → session id, display id, bounds
spaceo session list | destroy <id>
spaceo run <id> <app-path> [-- files...]       launch into a session, no activation
spaceo windows <id>                            owned windows with ids and frames
spaceo ax <id> [--window W]                    indexed accessibility tree
spaceo click <id> (--element N | --x X --y Y) [--button B] [--count N] [--modifiers M]
spaceo move <id> --x X --y Y                   hover, to reveal hover-only UI
spaceo drag <id> --x X --y Y --to-x X --to-y Y
spaceo scroll <id> --x X --y Y --dy -600       reach content below the fold
spaceo type <id> "text"
spaceo key <id> cmd+s
spaceo screenshot <id> [--window W] [--scale N] [--x X --y Y --width W --height H] -o out.png
spaceo verify <id>                             assert the isolation invariant right now
```

Pointer coordinates are window-local **points** everywhere, and a screenshot at the default
scale 1 returns one pixel per point, so the two spaces are the same numbers by construction.

`spaceo verify` exists so the invariant is checkable in production, not only in tests.

---

## 6. Failure policy

| Condition | Behaviour |
|---|---|
| Private symbol missing | `Capabilities` reports it; affected calls throw `SpaceOError.unavailable(symbol:)` |
| Accessibility not granted | hard error with the exact System Settings path |
| Screen Recording not granted | capture throws; input still works |
| Target app ignores per-PID input | Delivery is still attempted; no bundle-based target block |
| Display creation fails | session creation fails; nothing partially constructed survives |
| Chromium page click without a DevTools port | Attempt unrestricted per-PID delivery without a bridge |
| Non-positive or non-integral display dimensions | rejected before calling the private display API |
| Any positive tile density | accepted; the caller owns the usability tradeoff |
| Daemon receives SIGTERM/SIGINT | sessions destroyed and their apps quit before exit |

Report actual operation failures; do not reject control based on display or application class.
