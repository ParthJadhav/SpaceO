# SpaceO — Product Backlog (PM review, 2026-07-30)

Ready-to-import ticket set from a full product review against the stated goal:

> Give agents a separate display so they can work without interfering with the user, support
> every action a standard agent computer-use implementation issues, and let the user take over
> that display whenever they want.

Existing `TICKETS.md` (SPAO-101…134) covers *engineering correctness under the current feature
set*. This backlog covers **the gap between that feature set and the product goal**. Numbering
continues at SPAO-135 so the two files can be merged or imported into Plane without collision.

Priority key: **P0** blocks the product claim · **P1** blocks a credible v1 · **P2** quality.

---

## Epic A — Computer-use parity

The product promises to "support all the agent's default computer-use implementation." Measured
against the standard computer-use action set, SpaceO currently implements screenshot, left click,
type, and key. Everything else is missing, partial, or silently ignored. An agent handed a SpaceO
session instead of a normal desktop cannot scroll a page, drag a slider, hover a menu, or
shift-click a range — these are ordinary steps in ordinary tasks, not edge cases.

### SPAO-135 — Expose scroll to agents

- Priority: **P0**
- Status: Done — see TICKETS.md
- Evidence: `InputRouter.scroll(_:dx:dy:ticks:)` is fully implemented at
  `Sources/SpaceOKit/InputRouter.swift:593-605` and has **zero call sites** in `Sources/`. There is
  no `spaceo_scroll` MCP tool, no `spaceo scroll` CLI command, and no `scroll` daemon command.
  Only the Viewer path (`MirrorInput.scroll`, `MirrorInput.swift:267-281`) is wired.
- Impact: An agent cannot reach anything below the fold. Any list, document, settings pane, or web
  page taller than the tile is unreachable. This is the single largest functional gap in the
  product and the implementation is already written.
- Acceptance:
  - `spaceo_scroll` MCP tool and `spaceo scroll` CLI command with `x`/`y` (or `element`), `dx`,
    `dy`, and `ticks`.
  - Deltas are documented in the same coordinate space as `spaceo_click` (see SPAO-142).
  - Scroll targets the window under the point and is stamped like clicks are.
  - Live evidence: an agent scrolls a long TextEdit document and a Chromium page (via DevTools
    `Input.dispatchMouseEvent` type `mouseWheel`) to content that was off-tile.

### SPAO-136 — Add pointer move and hover

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: No `mouse_move`/`hover` exists on any agent surface. A `mouseMoved` event is emitted
  only as an internal prelude inside `InputRouter.click` (`InputRouter.swift:562-567`) and is not
  separately invocable. The Viewer has the primitive (`MirrorInput.swift:217-222`).
- Impact: Hover-only UI — menu bars that open on hover, tooltips, disclosure affordances, drag
  handles that appear on hover — is invisible and unusable to the agent.
- Acceptance:
  - `spaceo_move` (or `spaceo_hover`) delivers a per-PID `mouseMoved` to a point without pressing.
  - A follow-up `spaceo_read_screen` reflects hover-revealed elements.
  - Live evidence: an agent reveals a hover-only control and then presses it.

### SPAO-137 — Add press-and-hold drag

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: No agent path for drag. `MirrorInput` implements `.drag` → `leftMouseDragged`
  (`MirrorInput.swift:217`, `:225`) but only `ViewerInputController` calls it
  (`ViewerInputController.swift:347-351`). No `mouse_down`/`mouse_up` primitives exist either.
- Impact: Sliders, reordering, text selection by drag, resizing, canvas work, and drag-and-drop are
  all impossible. Text selection in particular is a precondition for many edit flows.
- Acceptance:
  - Either `spaceo_click_drag` (from/to) or the primitive pair `spaceo_mouse_down` /
    `spaceo_mouse_up`, with a documented pacing contract.
  - The drag stays bound to the window it started on, matching the Viewer's semantics.
  - Live evidence: an agent selects a paragraph in TextEdit by dragging and moves a slider.

### SPAO-138 — Complete the click matrix: middle button, and honour button/count on element clicks

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: `MouseButton` is `case left, right` only (`InputRouter.swift:7`); the MCP schema enum is
  `["left","right"]` (`MCPServer.swift:477`). On the **element** path, `SessionManager.swift:1158-1159`
  calls `InputRouter.press(element)` which performs `AXPress`/`AXConfirm` only — it silently drops
  both `button` and `count`. On the **coordinate** path, `InputRouter.swift:536` short-circuits to a
  single `AXPress` whenever an AX-pressable control sits under the point, silently discarding
  `count`.
- Impact: `spaceo_click --element 7 --button right --count 2` is accepted, reports success, and
  performs a single left press. Silently doing the wrong thing is worse than refusing — the agent
  proceeds believing a context menu opened.
- Acceptance:
  - `middle` added to the button enum and delivered on the coordinate path.
  - Element clicks with `button != left` or `count > 1` either perform a real synthetic
    button/multi-click at the element's frame, or fail with an explicit error. Never silently
    downgrade.
  - Regression tests assert that a dropped modifier/button/count is a hard error, not a success.

### SPAO-139 — Support modifier-held clicks

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: `InputRouter.click` never sets `event.flags` (`InputRouter.swift:570-583`). Modifiers
  exist only for standalone key presses (`KeyCombo`, `:48-52`).
- Impact: Shift-click (range select), Cmd-click (multi-select / open in new tab), Option-drag
  (duplicate), and Ctrl-click (context menu) are all unavailable. These are core interaction
  idioms, not power-user extras.
- Acceptance:
  - `spaceo_click` accepts a `modifiers` array and stamps `CGEventFlags` on down/up (and on drag
    when SPAO-137 lands).
  - The AX `press` short-circuit is skipped when modifiers are requested — a modifier click is
    semantically different from `AXPress`.

### SPAO-140 — Add key hold, cursor position, and wait

- Priority: **P2**
- Status: Open
- Evidence: `postKey` is strictly down → 15 ms → up (`InputRouter.swift:499-510`), with no duration
  and no separate down/up. No command returns a pointer location. No wait/sleep tool exists;
  `spaceo_session_heartbeat` renews a lease, it does not wait.
- Impact: Games and canvas apps need held keys. Agents that poll for a UI transition currently have
  to burn a tool call on a screenshot to pass time, and have no cheap way to idle.
- Acceptance:
  - `spaceo_press_key` accepts `hold_ms`, or `spaceo_key_down`/`spaceo_key_up` exist.
  - `spaceo_wait` with a bounded `seconds` (the daemon should not block the global operation gate
    for the duration — see SPAO-152).
  - Decide and document whether `cursor_position` is meaningful at all: SpaceO's design is that the
    agent's pointer never moves. If so, return the last synthetic point or refuse explicitly rather
    than leaving the action undefined.

### SPAO-141 — Add region and full-display capture

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: `spaceo_screenshot` accepts only `session`/`window`/`full` (`MCPServer.swift:822`).
  `Capture.region` exists but is hard-wired to `session.frame` (`SessionManager.swift:1292`, `:1300`).
  `Capture.display(_:)` (`Capture.swift:15-31`) has **zero call sites**.
- Impact: No zoom-in on a small control, and no way to re-read a sub-region cheaply. Every look
  costs a full-tile PNG through the model's context.
- Acceptance:
  - `spaceo_screenshot` accepts optional `x`/`y`/`width`/`height` cropped in the capture itself,
    clamped to the session's own tile.
  - Region coordinates use the same space as clicks (SPAO-142).

### SPAO-142 — Reconcile screenshot and click coordinate spaces

- Priority: **P0**
- Status: Done — see TICKETS.md
- Evidence: Four incompatible spaces are in play with nothing telling the agent which it has —
  - `spaceo_click x/y`: window-local, **points** (`InputRouter.swift:516-534`).
  - `spaceo_screenshot` window mode: window-local, **hard-coded 2×** (`Capture.swift:75-77`).
  - `spaceo_screenshot --full`: **tile**-local, **1×** (`Capture.swift:57-59`).
  - Chromium clicks: rebased again into CSS viewport coordinates
    (`SessionManager.swift:1165-1169`); `viewportOnScreen` reads `devicePixelRatio` and then
    discards it (`ChromiumBridge.swift:324-336`).
  Virtual displays are created `hiDPI: true` (`Stage.swift:90`), so the 2× is real.
  `Demo.swift:243-245` encodes the ambiguity as an assertion that accepts *either* scale.
- Impact: **This is the bug that makes vision-driven agents fail silently.** An agent that reads a
  coordinate off the default screenshot and clicks it lands at half the intended position — near
  the top-left it clicks the wrong control, near the edges it gets a hard out-of-bounds error
  (1 pt tolerance, `InputRouter.swift:531-534`). Every standard computer-use agent works this way.
  The AX-index path is excellent, but the pixel fallback must be correct for agents that use it.
- Acceptance:
  - One documented agent-facing coordinate space; every screenshot response states its origin,
    scale factor, and point dimensions in machine-readable form.
  - Window and tile captures agree on scale, or the response distinguishes them explicitly.
  - `spaceo_list_windows` and `spaceo_session_list` expose enough geometry for an agent to convert
    between tile-relative and window-relative without guessing.
  - Regression: a click derived from a screenshot pixel hits the same control the pixel shows, at
    1× and 2×, for window mode and tile mode.

### SPAO-143 — Give agents a working clipboard

- Priority: **P1**
- Status: Open
- Evidence: `requireClipboardSafeRoute` refuses any `cmd`+`c`/`x` before synthesising an event
  (`InputRouter.swift:23-35`, `:487-497`) — the SPAO-133 fail-closed decision. But `cmd+v` is **not**
  blocked (`mutatesPasteboard` matches only keyCodes 8/7), so an agent can paste **the user's**
  clipboard into an app. There is no tool to read or write a clipboard for the agent.
  `PasteboardGuard` is documented in `ARCHITECTURE.md:259-261` as `withPasteboardPreserved { }` —
  **that symbol does not exist**; the file's own header says it is deliberately not a production
  guard (`PasteboardGuard.swift:4-9`).
- Impact: The asymmetry is the worst of both worlds — the agent cannot copy, but can leak the
  user's clipboard into an agent app. Copy/paste is table stakes for real work.
- Acceptance:
  - Decide the model: per-session pasteboard, or explicit `spaceo_clipboard_get`/`_set` scoped to
    the session, or a documented refusal of both directions.
  - Whatever is chosen, `cmd+v` and `cmd+c` behave consistently under it — no path where the
    user's clipboard reaches an agent app implicitly.
  - `ARCHITECTURE.md` §3.5 corrected to describe the code that exists.

### SPAO-144 — Expose window-scoped text reading and flag truncation

- Priority: **P2**
- Status: Open
- Evidence: `AXTree.text(in: window)` (`AXTree.swift:157`) — the window-scoped reader — has no
  production caller; only `Demo.swift:206`. `spaceo_type` returns `AXTree.focusedValue(pid:)`
  (`SessionManager.swift:1223`), which is app-wide and ambiguous with two windows open.
  `AXSnapshot.find(_:)` (`AXTree.swift:55-58`) is unused — there is no search-by-label tool.
  Traversal budget exhaustion (`AXTraversal.swift:440-444`) and the 200-element web cap
  (`ChromiumBridge.swift:497`) truncate silently.
- Impact: An agent cannot reliably read a specific window's text, cannot search for a control by
  name, and cannot tell a complete screen read from a truncated one — so it reasons over a partial
  view believing it is complete.
- Acceptance:
  - `spaceo_read_screen` reports `truncated: true` plus the budget that was hit.
  - A window-scoped text read is reachable from CLI and MCP.
  - Optional: `spaceo_find_element` by label, returning an index.

### SPAO-145 — Make multi-tab browsers drivable

- Priority: **P1**
- Status: Open
- Evidence: `attachToLaunchedTarget()` fails closed when a browser has 2+ page targets and tells the
  caller to "Attach to one explicitly" (`ChromiumBridge.swift:178`) — but `attach(toTargetID:)`
  (`:186`) has **zero call sites** and is reachable from no CLI or MCP command. `verifyBoundTarget()`
  (`:204-215`), documented as the pre-action guard against a closed or replaced page, is also never
  called. `evaluate` (`:468-480`) and `screenshot` (`:485-494`) are likewise unreachable. If the
  bridge fails to attach, `AgentSession.swift:409-415` stores nothing and raises nothing — later web
  clicks fall back to per-PID delivery, which `FINDINGS.md:265-274` proves does nothing at all for
  Chromium web content.
- Impact: The moment an agent opens a second tab, its browser becomes permanently undrivable — and
  worse, the degraded path *silently does nothing* rather than erroring, which is the exact failure
  mode `FINDINGS.md:275` says is unacceptable.
- Acceptance:
  - `spaceo_list_targets` / `spaceo_attach_target` (or equivalent) expose target selection.
  - `verifyBoundTarget()` runs before every web action.
  - A missing bridge on a Chromium web-content action is a **hard error**, never a silent per-PID
    fallback.
  - `spaceo_read_screen` states which target it read.

### SPAO-146 — Add URL navigation

- Priority: **P2**
- Status: Open
- Evidence: `spaceo_open_app`'s `files` are coerced with `URL(fileURLWithPath:)`
  (`SessionManager.swift:960-962`), so an `https://` string becomes a nonsense file path.
- Impact: Getting a browser to a URL requires launch → find address bar → click → type → Return,
  five tool calls with several failure points, for the most common agent action there is.
- Acceptance: `spaceo_open_url` (or a `url` parameter on `open_app`) that launches or reuses the
  session's browser and navigates via DevTools, returning the resolved page title.

---

## Epic B — Multi-agent correctness and daemon health

### SPAO-147 — Authorize destructive and cross-session commands

- Priority: **P0**
- Status: Open
- Evidence: Leases gate only the named-session mutations. **`session.destroy --all` requires no
  lease** (`SessionManager.swift:876-903`), **`daemon.stop` requires no lease** (`:821-838`), and
  **every read command is unauthenticated** — `session.list`, `windows`, `ax`, `screenshot`,
  `verify`, `pool`, and `pool.configure`. `case "screenshot"` resolves via `resolve(request.session)`
  (`:1280`), not `resolveForMutation`. A raw socket client that omits `controllerOwner` on
  `session.create` gets `allowsLeaseOmission = true` (`:302`).
- Impact: Any process running as the same user can screenshot another agent's tile, dump its full
  accessibility tree, change global pool density, destroy every session and quit every app, or stop
  the daemon. With several agents on one machine — the documented deployment model — one
  misbehaving or buggy client takes out all the others, and cross-agent context leakage is total.
  The uid trust boundary is a documented and accepted *security* stance; this ticket is about
  *coordination* between cooperating clients, which the lease system already models but does not
  enforce here.
- Acceptance:
  - `destroy --all` and `daemon.stop` require either every affected session's lease or an explicit
    operator-scoped confirmation flag.
  - Reads scoped to a session (`ax`, `screenshot`, `windows`, `verify`) require that session's lease;
    unscoped inventory (`session.list`, `pool`) stays open but redacts other controllers' detail.
  - `pool.configure` requires operator scope.
  - `allowsLeaseOmission` is unreachable over the socket.
  - Tests: a second client cannot screenshot, read, or destroy the first client's session.

### SPAO-148 — Stop oversized windows leaking across tiles

- Priority: **P1**
- Status: Open
- Evidence: `Capture.region` crops in-capture via `sourceRect` (`Capture.swift:38-64`), so a
  session's own window never spills into a neighbour's shot. But `WindowWatcher` re-fits an
  oversized window to `min(tile, max(320|240, current))` and, when it still does not fit, counts it
  in `refused` rather than relocating it (`WindowWatcher.swift:154-195`). A refused window
  physically overlaps the neighbouring tile, so it **appears in the neighbour's screenshot**. The
  doc comment at `Capture.swift:33-37` claims the opposite property.
  The 2026-07-31 full live run reproduced the gate: 15/16 checks passed, while
  `testTwoSessionsOnOneDisplayStayInTheirOwnTiles` failed because the right session reported two
  windows that refused movement into its tile. The targeted repeat failed at the same placement
  boundary. Cleanup returned the host to zero SpaceO and orphan displays.
- Impact: A genuine cross-agent context leak at any density above 1 — one agent reads another
  agent's work. `ARCHITECTURE.md:81-83` calls this out as the thing tiles exist to prevent.
- Acceptance:
  - An oversized window that cannot fit its tile is either moved to its own display, or the session
    is upgraded to an exclusive display, or the overlap is excluded from neighbours' captures via
    `SCContentFilter(display:excludingWindows:)`.
  - A `refused` window is surfaced as a session health error, not a counter.
  - Regression: a deliberately oversized window in tile 0 never appears in tile 1's capture.

### SPAO-149 — Fix TileLayout.rects / rect divergence above capacity 64

- Priority: **P2**
- Status: Done — see TICKETS.md
- Evidence: `rects` clamps `n = min(64, capacity)` then computes `grid(for: n)`
  (`TileLayout.swift:51-52`); `rect` computes `grid(for: capacity)` (`:74`). At capacity 100,
  `rects` yields an 8×8 grid of 240×135 tiles while `rect` yields 10×10 of 192×108 — overlapping,
  inconsistent geometry.
- Impact: Any consumer mixing the two (diagnostics, Viewer overlays, future UI) gets wrong tile
  rects, and overlapping rects are exactly the cross-agent leak SPAO-148 is about.
- Acceptance: `rects` either matches `rect` for every index it returns, or refuses above the
  materialization bound instead of returning a different layout. Property test over capacities
  1…1000 asserting `rects[i] == rect(index: i)` wherever both are defined.

### SPAO-150 — Keep the daemon responsive during teardown

- Priority: **P1**
- Status: Open
- Evidence: `SessionManager` is an actor, but teardown blocks synchronously inside it —
  `waitForExit` busy-waits with `usleep(120_000)` for up to 6 s + 3 s (`AgentSession.swift:17-25`,
  `:852-858`), `Stage.invalidate` blocks up to 10 s in `DispatchQueue.sync`
  (`Stage.swift:179-208`), and `SessionLifecycle.destroy` does `NSCondition.wait()` on the actor
  thread (`SessionLifecycle.swift:163-168`). The global `SessionOperationGate` serialises everything.
- Impact: Destroying one session freezes **every** other agent for up to ~20 seconds — no
  screenshot, no click, no list. With multiple agents that reads as the whole product hanging.
- Acceptance:
  - Teardown waits are async and do not hold the global operation gate.
  - A second session remains fully driveable while a first is being destroyed (deterministic test
    measuring p99 command latency during teardown).

### SPAO-151 — Cut janitor write amplification and gate-holding

- Priority: **P2**
- Status: Open
- Evidence: `runJanitorPassNow` calls `persistSession` for every session on every 3 s tick
  regardless of change (`SessionManager.swift:197-201`, interval `:59`); each write is temp file +
  `fsync(file)` + `rename` + `fsync(dir)` (`SessionStore.swift:770-841`), preceded by a full ledger
  `load()`. The pass runs while holding `operationGate` (`:186`) and can invoke recovery cleanup
  with `Thread.sleep` (`DetachedSessionRecovery.swift:176-181`).
- Impact: 2N fsyncs every 3 seconds forever, plus a periodic global stall on disk I/O. On a laptop
  this is a measurable battery and SSD cost for an idle daemon.
- Acceptance: Persist only on state change; run recovery I/O outside the global gate; an idle
  daemon with N sessions performs no periodic writes.

### SPAO-152 — Make the transport accept loop concurrent

- Priority: **P2**
- Status: Open
- Evidence: `acceptLoop` calls `serve(client)` inline (`Transport.swift:173`), and `serve` blocks
  reading the request with a 2 s `SO_RCVTIMEO` / 3 s deadline (`:183-195`).
- Impact: One same-uid client that connects and never writes stalls all accepts for up to 3 s; a
  loop of such connections is a trivial local denial of service against every agent on the machine.
- Acceptance: Accept and serve are decoupled; a non-writing client cannot delay other clients'
  requests. Test: 100 idle connections while a normal command completes within its usual latency.

### SPAO-153 — Ledger garbage collection and schema migration

- Priority: **P2**
- Status: Open
- Evidence: The ledger namespace is an FNV-1a hash of the socket path
  (`SessionStore.swift:406-414`), which lives under `NSTemporaryDirectory()`. If the socket path
  changes, the old `sessions-socket-*.json` is orphaned and never read or pruned. Schema is v1 only
  with no migration (`:263`, `:432-436`) — a version mismatch makes the daemon refuse to start
  rather than quarantining the file. `RELEASE_AUDIT.md:216-218` also records ~419 MB of historical
  Chromium profile directories deliberately left on disk.
- Impact: Unbounded disk growth from agent browser profiles, and a future version bump that bricks
  the daemon for anyone with an old ledger.
- Acceptance: Orphan ledgers and stale agent profiles are GC'd on startup with a documented
  retention policy; an unsupported schema version is quarantined with a readable message and the
  daemon still starts.

---

## Epic C — The user's half: taking over the display

The goal says "if the user wants to use the display, they should be able to." The Viewer streams
and controls well, but its control plane is read-only-plus-destroy, and one failure mode leaves the
user's whole machine in a bad state.

### SPAO-154 — Restore host input state if the Viewer dies while captured

- Priority: **P0**
- Status: Done — see TICKETS.md
- Evidence: Entering capture calls `CGAssociateMouseAndMouseCursorPosition(0)`, `NSCursor.hide()`,
  and disables host global hotkeys via `SPOSetGlobalHotKeysEnabled`
  (`SurfaceView.swift:321-345`, `MirrorInput.swift:116-119`); `endHostInputCapture` restores them
  (`:347-358`). If the Viewer crashes or is force-quit while captured, that cleanup never runs.
- Impact: The user is left with a hidden cursor, a decoupled mouse, and **system-wide global
  hotkeys disabled** — Spotlight, Mission Control, screenshot shortcuts, everything. For an app
  whose entire promise is "we never disturb your machine," this is the worst possible failure, and
  the recovery (log out and back in) is not discoverable.
- Acceptance:
  - A watchdog or `atexit`/signal handler restores cursor association, cursor visibility, and hotkey
    mode on abnormal termination.
  - On launch, the Viewer detects and repairs a previously-abandoned capture state.
  - Test: `SIGKILL` the Viewer while captured; verify hotkeys, cursor association, and cursor
    visibility are restored automatically.

### SPAO-155 — Give the Viewer a real session control plane

- Priority: **P1**
- Status: Open
- Evidence: The daemon exposes `session.create`, `session.destroy`, and `session.heartbeat`
  (`SessionManager.swift:840-880`), but the Viewer only ever sends `session.list`, `pool`,
  `pool.configure`, `daemon.stop` (`ViewerModel.swift`). Abandoned/reclaimable sessions offer only
  an "Inspect" action (`:460-469`); recovery rows are entirely inert
  (`ContentView.swift:172-186`).
- Impact: The user can watch agents and can stop the entire daemon, but cannot create a display for
  their own use, cannot destroy one runaway session, and cannot clean up a stuck recovery record.
  The only lifecycle control offered is the most destructive one available.
- Acceptance:
  - New Session, Destroy Session (with confirmation), and Reclaim/Forget on recovery rows.
  - Destroying one session never requires stopping the daemon.
  - Health alerts for abandoned/reclaimable sessions carry the matching action.

### SPAO-156 — Fix the first-run permission dead end

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: `ViewerModel.requestPermissions()` (`ViewerModel.swift:1169-1179`) has **no callers**.
  Because `restartStreamForCurrentSelection` refuses to start capture without a pre-flight grant
  (`:965-972`), macOS's own first-capture prompt never fires either.
- Impact: On first launch the user sees a banner and must find System Settings, locate the app, and
  add it manually — the standard one-click prompt never appears. This is the very first thing every
  new user experiences.
- Acceptance:
  - A prominent "Grant access" action calls `CGRequestScreenCaptureAccess()` and
    `AXIsProcessTrustedWithOptions` with the prompt option.
  - After granting, the stream starts without relaunching.
  - First-run flow verified on a machine with no prior grants.

### SPAO-157 — Fix the scope picker dead end and surface screenshot failures

- Priority: **P2**
- Status: Done — see TICKETS.md
- Evidence: The Session/Display picker is disabled when `selectedSession == nil`
  (`ContentView.swift:755`), but `selectDisplay` clears `selectedSessionID`
  (`ViewerModel.swift:768-779`) — so once the user picks a display row, they can never return to
  Session scope from the toolbar, and the fallback at `:783-787` is unreachable. Separately,
  `@Published streamError` (`:259`) is written but read by no view, so a failed toolbar screenshot
  (`:1113`) is completely silent.
- Impact: Two dead ends in the primary UI. The user presses Screenshot, nothing happens, and there
  is no error and no saved file.
- Acceptance: Scope is always switchable when the selected display hosts a session; screenshot
  success shows the path with Reveal in Finder, and failure shows an error.

### SPAO-158 — Show what the agent is doing, and let the user interrupt it

- Priority: **P1**
- Status: Open
- Evidence: The only activity signal is `Last activity Ns ago` from controller metadata
  (`ViewerModel.swift:129-142`). The status line advertises "Human and agent can work
  concurrently" (`ContentView.swift:380`). `MirrorInput.setHostGlobalShortcutsEnabled` explicitly
  notes it "does not pause the agent" (`MirrorInput.swift:113-118`).
- Impact: The user takes control of a display an agent is actively driving, and the two fight over
  the same windows with no arbitration and no warning. There is no way to say "stop, I'm driving
  now." This is the core interaction the product goal describes — user and agent sharing one
  display — and it is currently unmediated.
- Acceptance:
  - A live indicator on the canvas when the session has had agent input in the last N seconds,
    naming the action.
  - A Pause/Resume control that makes the daemon refuse or queue that session's input commands with
    a clear error the agent can act on.
  - Taking Control offers to pause the agent; releasing offers to resume.
  - Event feed records agent actions, not only session lifecycle.

### SPAO-159 — Make ⌃⌘Esc the only advertised escape, or make ⇧⌘I work

- Priority: **P2**
- Status: Open
- Evidence: The menu advertises ⇧⌘I as "Release Input" (`ViewerApp.swift:21-27`), but while
  captured `performKeyEquivalent` intercepts before the main menu
  (`SurfaceView.swift:257-262`), so ⇧⌘I is forwarded to the agent instead. ⌃⌘Esc
  (`ViewerInputController.swift:34-63`) is the only working escape. ⌘Q and ⌘W are also forwarded,
  so the Viewer cannot be quit while captured.
- Impact: The user presses the shortcut the menu shows, it does nothing locally and types into the
  agent's app instead. SPAO-123 established one discoverable escape; a second advertised-but-broken
  one undermines it.
- Acceptance: Either ⇧⌘I is also reserved locally while captured, or the menu item is disabled with
  help text pointing at ⌃⌘Esc while captured.

### SPAO-160 — Clipboard and file transfer between user and agent display

- Priority: **P2**
- Status: Open
- Evidence: No `NSPasteboard` code anywhere in `Sources/SpaceOViewer`; `VMSurfaceView` implements no
  `NSDraggingDestination`. ⌘C/⌘V are forwarded as raw key events.
- Impact: The user watching an agent's screen cannot copy an error message out of it, and cannot
  drop a file onto the agent's display to hand it over. Every VM console solves both; these are the
  two most common "I want to help the agent" gestures.
- Acceptance: Copy-from-remote (via the session AX tree or DevTools) and drop-a-file-to-open, both
  respecting whatever clipboard model SPAO-143 settles on.

### SPAO-161 — Viewer polish: icon, persisted state, fit/fullscreen, multi-window

- Priority: **P2**
- Status: Open
- Evidence: `make-viewer-app.sh:69-87` writes no `CFBundleIconFile` and there is no `.icns` in the
  repo; no `NSHumanReadableCopyright`, no `LSApplicationCategoryType`. No `@AppStorage`/
  `UserDefaults` anywhere — zoom, selection, inspector section, and density reset every launch. Zoom
  is 1×–4× toolbar-only with no ⌘+/⌘−, no reset, no fit-to-window; panning is scroll-only
  (`SurfaceView.swift:224-232`) despite an `.openHand` cursor (`:142`). `WindowGroup` permits ⌘N but
  the shared `@StateObject` has a single `onFrame` closure the newest surface overwrites
  (`:417-419`), so a second window blanks the first.
- Impact: The app looks unfinished before it is used — generic Dock icon, nothing remembered — and
  ⌘N produces broken behaviour rather than a second console.
- Acceptance: App icon and complete bundle metadata; zoom/selection/inspector persisted; Fit and
  Actual Size commands with standard shortcuts; drag-to-pan; ⌘N either works or is disabled.

### SPAO-162 — Stop restarting the stream when the agent moves a window

- Priority: **P2**
- Status: Open
- Evidence: `currentStreamTarget` includes the session's tile geometry
  (`ViewerModel.swift:724-726`), and any change to it tears down and restarts the ScreenCaptureKit
  stream.
- Impact: An agent resizing or moving its window makes the user's live view flicker to black and
  restart — during exactly the moments the user most wants to watch.
- Acceptance: Tile-geometry changes update `sourceRect` on the existing stream where SCK allows it;
  only display identity or pixel-dimension changes force a restart.

---

## Epic D — Isolation: close the gap between the claim and the evidence

### SPAO-163 — Find a safe way to observe the keyboard input route

- Priority: **P1**
- Status: Open
- Evidence: `keyFocusPID` and `typingFocusPID` are hard-coded `0` at capture
  (`IsolationSnapshot.swift:228-229`); the private getters were removed after proven memory
  corruption (RA-027). `focus-without-raise` is unconditionally unavailable
  (`SpaceOPrivate.m:78-81`), so `prepareForInput` is a no-op and `focus()` always throws.
  SPAO-118 correctly made the *reporting* honest — every live verdict is `partial`, never `intact`.
- Impact: The product's central promise is "your keystrokes still go where you're typing," and
  SpaceO cannot observe that dimension at all. `partial` forever is honest but it is not a proof,
  and it is what a user is really asking about. This is the highest-value open research question in
  the project.
- Acceptance:
  - Investigate observable proxies: `AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplication)`,
    `kAXFocusedWindow`/`kAXFocusedUIElement` on the frontmost app, or a bounded event-tap probe.
  - If a safe observer exists, promote `key_input_route` to `observed` or `inferred` with stated
    evidence; if none does, document the negative result in `FINDINGS.md` so it is not re-litigated.
  - Either way, `verify` explains in one sentence what `partial` does and does not rule out.

### SPAO-164 — Harden Space attribution

- Priority: **P1**
- Status: Done — see TICKETS.md
- Evidence: `SPOSpacesForDisplay` matches a display entry when the UUID matches **or**
  `displays.count == 1` **or** the entry's `Display Identifier` is literally `"Main"`
  (`SpaceOPrivate.m:271-273`). Those fallbacks can return the *user's* main display's Spaces for an
  agent display id, and the result is fed to `AgentActivity.claim(spaces:)`
  (`DisplayPool.swift:135`, `AgentSession.swift:490`).
- Impact: Misattribution corrupts the isolation verdict in both directions — the user's own Space
  can be classified as agent territory (every `verify` fails, users stop reading the check), or a
  genuine Space breach is masked. This sits underneath every isolation claim the product makes.
- Acceptance: Match on display UUID only; when the UUID cannot be resolved, report the Space set as
  unknown and downgrade `active_space` coverage rather than guessing. Test covering single-display,
  mirrored, and multi-display arrangements.

### SPAO-165 — Ship a documented mitigation for notifications, Dock, Cmd-Tab, and audio

- Priority: **P2**
- Status: Open
- Evidence: No code touches any of these. `README.md:380` says "Not solvable on-host";
  `FINDINGS.md:247` suggests a Focus filter. Audio has zero coverage anywhere — an agent app's
  sound is fully audible.
- Impact: The agent is invisible on screen but still present in the user's attention — its apps
  appear in Cmd-Tab and Mission Control, post notification banners onto the user's display, and
  make noise. "Isolates attention" is the product's own framing, and these are attention leaks.
- Acceptance:
  - Ship a Focus filter profile or setup guide as a first-class onboarding step, not a footnote.
  - Investigate per-session muting (e.g. launching agent apps with an audio route that is not the
    default output) and record the result.
  - `doctor` reports whether the recommended mitigations are in place.

### SPAO-166 — Remove or gate the dead private focus-record path

- Priority: **P2**
- Status: Open
- Evidence: `SPOFocusWithoutRaiseResult` still contains the full `SLPSPostEventRecordTo` byte
  layouts (`SpaceOPrivate.m:316-353`) and is a public C entry point, even though the gate at `:320`
  makes it return `NotAttempted`. Similarly `kCGMouseEventWindowUnderMousePointer` is hard-coded as
  raw field ids 91/92 (`InputRouter.swift:589-591`) with no availability detection — if Apple
  renumbers them, every agent click silently stops reaching apps.
- Impact: Shipped, callable code that writes undocumented byte layouts into a private API is the
  exact shape of the 2026-07-26 incident. The unversioned CGEventField constants are an undetectable
  break on any macOS update.
- Acceptance: Either delete the dead focus-record path or make it unreachable from outside the
  module; add a runtime self-check that a stamped click actually reaches a known-good target, so a
  field-id change surfaces as a `doctor` failure rather than silent inaction.

---

## Epic E — Prove it works

### SPAO-167 — Run and record a live multi-agent regression

- Priority: **P0**
- Status: Open
- Evidence: `RELEASE_AUDIT.md:443` — "The live suite was not executed as part of this change."
  Seven findings are marked *Fixed; live rerun pending* (RA-015, 023, 026, 032, 035, 037, 043).
  SPAO-110's live evidence covers **one** display and **one** session. Everything about tiling,
  cross-session isolation, and concurrent agents is unproven live.
- Impact: The product's differentiating claim — several agents working simultaneously without
  disturbing the user — has never been demonstrated end to end. The one-display run is a good
  smoke test, not a proof of the thing being sold.
- Acceptance:
  - A scripted live run: 3 concurrent sessions on ≥2 displays, each launching a different app class
    (AppKit, Electron, Chromium), driving them for ≥10 minutes while a human works normally.
  - Assert: no window escapes its tile, no tile screenshot contains a neighbour's window, isolation
    reports no covered breach throughout, the user's frontmost app and cursor are undisturbed, and
    teardown leaves zero displays and zero surviving apps.
  - Record wall-clock latency for each agent action and the daemon's p99 during a concurrent
    teardown (ties to SPAO-150).

### SPAO-168 — Build a computer-use conformance suite

- Priority: **P1**
- Status: In progress
- Evidence: `scripts/computer-use-check.mjs` now drives the release binary through its real MCP
  stdio transport against TextEdit, Google Chrome, and Cursor. It uses screenshot differences,
  page-title state, isolation audits, and explicit refusal checks rather than successful return
  values. The latest matrix passes all 25 checks, including a Cursor editor scroll confirmed both
  by its semantic visible-range delta and an independent screenshot difference. Slider,
  multi-select, context-menu, and CI publication coverage remain.
- Impact: Without an end-to-end conformance harness, parity regressions land silently and "supports
  computer-use" stays an assertion rather than a measurement.
- Acceptance:
  - A fixture app (or web page) with a scrollable list, a hover-only menu, a slider, a multi-select
    list, a context menu, and a text field.
  - One test per computer-use action, driven through the MCP surface exactly as an agent would.
  - The suite reports a parity percentage, published in the README, and fails CI on regression.

### SPAO-169 — Fail fast on missing prerequisites at session create

- Priority: **P2**
- Status: Open
- Evidence: `Capabilities.requireDriving()` has **zero call sites** — only `requireCapture()` is
  used (`SessionManager.swift:1283`). The sole gate on create is `SPOCapabilityAvailable(.virtualDisplay)`
  inside `Stage.init` (`Stage.swift:94-99`). Accessibility is never checked before launch, so an
  AX-denied host fails late with "pid N has no accessibility windows"
  (`WindowPlacement.swift:97`).
- Impact: A new user's first `session create` succeeds and their first `run` fails with a message
  that does not mention permissions. The information needed to fix it exists and is not used.
- Acceptance: `session.create` (or the first mutation) checks Accessibility and reports the exact
  System Settings path — the same quality of message `doctor` already produces.

### SPAO-170 — Correct documentation that describes code which does not exist

- Priority: **P2**
- Status: Open
- Evidence:
  - `ARCHITECTURE.md:259-261` documents `PasteboardGuard.withPasteboardPreserved { }`; the symbol
    does not exist.
  - `ARCHITECTURE.md:262-263` says the janitor detects "owned-PID focus theft";
    `runJanitorPassNow` (`SessionManager.swift:192-225`) does no such thing.
  - `ResourceBudget.swift:17-28` doc comments still describe 64-megapixel caps and rate limits that
    are now `Int.max`.
  - `ResourceLimitsReport` ships `Int.max` sentinels over the wire (`Protocol.swift:172-185`) as if
    they were real limits; `poolSummary` takes a `budget` it discards with `_ = budget`
    (`SessionManager.swift:1362-1364`).
  - `README.md:238-239` says session tiles are outlined with their ids, true only in Display scope.
  - `spaceo demo --no-capture` (`main.swift:812`) and `spaceo session create --lease`
    (`main.swift:651`) are implemented but undocumented.
  - The Viewer's entire control plane — scope modes, zoom/pan, six inspector sections, event log,
    daemon start/stop, density stepper — is absent from the README.
- Impact: These documents are the project's primary asset and are the first thing a contributor or
  evaluator reads. Each false statement costs someone a debugging session.
- Acceptance: Every claim in `README.md` and `ARCHITECTURE.md` maps to a symbol that exists; wire
  reports omit or null out limits that are not enforced; CLI usage text matches the parser.

### SPAO-171 — Define and instrument product success metrics

- Priority: **P2**
- Status: Open
- Evidence: There is no telemetry, no success/failure counters, and no way to answer "does this work
  for a real user" beyond a manual run.
- Impact: Every prioritization decision after this backlog is a guess. The audit trail is
  exceptionally strong on *correctness* and has nothing on *usage*.
- Acceptance: Agree a small opt-in local metrics set — action success rate by action type, isolation
  verdict distribution, session duration, teardown completeness, time-to-first-successful-action —
  exposed through `spaceo doctor --json` and the Viewer's Events pane. No network egress.

---

## Suggested sequencing

**Milestone 1 — "an agent can actually use it"**
SPAO-135 (scroll), SPAO-142 (coordinates), SPAO-137 (drag), SPAO-136 (hover), SPAO-138 (click
matrix), SPAO-139 (modifiers), SPAO-145 (multi-tab browsers), SPAO-168 (conformance suite).
Exit: the conformance suite passes for every standard computer-use action.

**Milestone 2 — "several agents and a user share one Mac safely"**
SPAO-147 (authorization), SPAO-148 (tile leak), SPAO-150 (teardown responsiveness),
SPAO-164 (Space attribution), SPAO-167 (live multi-agent regression).
Exit: the three-session live run passes with no cross-agent leak and no user disturbance.

**Milestone 3 — "the user can take the wheel"**
SPAO-154 (host-state recovery), SPAO-156 (first-run permissions), SPAO-155 (session control plane),
SPAO-158 (activity + pause), SPAO-157/159 (dead ends), SPAO-161 (polish).
Exit: a new user installs, grants, watches, takes control, and hands back without reading docs.

**Milestone 4 — "ship it"**
SPAO-115 (signed/notarized release, already open), SPAO-170 (doc truth), SPAO-169 (fail fast),
SPAO-163 (input-route observability), SPAO-165 (attention leaks), SPAO-171 (metrics).
