# SpaceO Tickets

## Product direction

SpaceO permits virtual-display creation and input control without product-enforced allowlists,
caps, incident lockouts, or acknowledgement gates. Runtime prerequisites and structural validity
remain: the operating system must expose the API being called, dimensions must be positive,
finite, integral and representable by the platform type, and failed platform operations are
reported.

Current milestone: **Unrestricted creation and control stabilization**

Status definitions:

- **Done** — implementation and automated regression evidence are complete.
- **In verification** — implementation is complete; live UI/WindowServer evidence is pending.
- **Open** — not yet implemented.

## Active milestone

### SPAO-101 — Restore clean source builds

- Priority: P0
- Status: Done
- Problem: `Transport.Server.start()` captured a later local `thread` declaration, so a clean
  build failed before tests could run.
- Fix: Qualify the instance property as `self.thread`.
- Acceptance:
  - Debug and release targets compile.
  - Starting the same server twice rejects only the second start and leaves the listener healthy.
- Evidence: `testSameServerCannotStartTwiceOrDisruptItsFirstListener`.

### SPAO-102 — Eliminate false native-window placement failures

- Priority: P1
- Status: Done
- Problem: AX position/size mutations publish asynchronously. SpaceO read WindowServer bounds
  immediately, reported a false refusal, and sometimes terminated a correctly moved app.
- Fix: Poll authoritative bounds for the requested origin for up to one second and roll every
  original window back if placement actually fails.
- Acceptance:
  - First-attempt `run`/`adopt` succeeds for TextEdit and Calculator.
  - A real refusal returns authoritative final bounds and does not leave a half-moved app.
- Evidence: First-attempt live placement succeeded for Calculator and TextEdit on separate
  one-display daemon runs. Both sessions remained healthy through capture and teardown.

### SPAO-103 — Make Viewer pointer control functional

- Priority: P1
- Status: Done
- Problem: Viewer displayed “driving” while native AppKit controls discarded its per-PID
  down/up sequence.
- Fix:
  - Hit-test the click point with Accessibility and perform `AXPress` for pressable controls.
  - Keep unrestricted per-PID pointer delivery as the fallback for canvas/custom surfaces.
  - Hold the best-effort input route through the full move/down/up transaction and preserve the
    incoming AppKit event as the synthetic-event template.
- Acceptance:
  - Clicking a Calculator button through Viewer changes its value.
  - TextEdit can be focused and edited through Viewer.
  - Keyboard forwarding continues to work.
- Evidence:
  - Viewer click changed Calculator `0` to `7`; a forwarded key changed it to `79`.
  - Viewer targeted TextEdit and inserted `Viewer TextEdit pass` into its document.
  - Control off/on/off transitions cleared and restored the target note correctly.

### SPAO-104 — Remove virtual-display creation restrictions

- Priority: P1
- Status: Done
- Problem: Creation was blocked by mirror/orphan/user-display checks, a four-display cap, a
  16-session cap, tile/framebuffer limits, a lifecycle cooldown, mandatory cursor fencing, and
  prior teardown failures.
- Fix:
  - Removed all policy caps and display-graph preflight/postflight refusals.
  - Removed cursor fencing, pointer-warp accounting, parking helpers and the lifecycle cooldown.
  - Decoupled session creation from the combined control capability gate.
  - Kept display-graph and teardown observations diagnostic.
- Acceptance:
  - Any positive density and UInt32-representable display dimensions reach the platform API.
  - Mirror/orphan/physical-display state never blocks `session create`.
  - Pool growth is not capped by SpaceO.
- Evidence: unrestricted density, capacity 4,097 and 16,384×16,384 configuration tests.
- Live evidence: Two sequential regression runs each held exactly one 1,600×1,000 SpaceO
  display. Creation, destruction and daemon shutdown succeeded, with no attached SpaceO display
  left afterward.

### SPAO-105 — Remove input-control restrictions

- Priority: P1
- Status: Done
- Problem: Control was blocked for physical displays, nonzero window layers, the Viewer process,
  canvas/game bundle IDs, adopted Chromium targets, reused application processes, and one
  reserved keyboard chord.
- Fix:
  - Viewer Control is available for every selected display.
  - Hit-testing includes desktop, overlay, physical-display and self targets.
  - Removed app-family deny/refusal paths; absent DevTools falls back to per-PID delivery.
  - Focus preparation/restoration is best-effort and never gates direct delivery.
  - Removed the reserved Control-Command-Escape chord.
- Acceptance:
  - Viewer can attempt pointer and keyboard delivery to every visible target.
  - CLI/MCP does not reject a target based on bundle family or display provenance.
  - All command shortcuts are forwarded while Control is enabled.
- Evidence:
  - Viewer exposed an enabled Control toggle for both the SpaceO display and the physical
    Built-in Retina Display.
  - Viewer hit-testing selected Calculator without a display, layer, self or app-family refusal.
  - CLI click/key delivery changed Calculator to `78`; CLI focus and typing entered
    `SpaceO unrestricted input` into TextEdit.

### SPAO-106 — Reset stale Viewer status state

- Priority: P3
- Status: Done
- Problem: Turning Control off cleared the model note but retained the controller’s dedupe cache,
  suppressing the next identical “driving …” status.
- Fix: Clearing Control resets drag, keyboard target and note-cache state on the input queue.
- Acceptance: Re-enabling Control and selecting the same target emits its status again.

### SPAO-107 — Implement machine-readable doctor/version output

- Priority: P3
- Status: Done
- Problem: `doctor --json` was rejected despite the documented global JSON contract.
- Fix: Added structured single-document JSON for `doctor` and `version`; display anomalies are
  reported without affecting doctor health.
- Acceptance:
  - Output parses as exactly one JSON document.
  - Schema includes capabilities, daemon state and display inventories.
- Evidence: black-box version/doctor JSON regression tests.

### SPAO-108 — Correct exclusive-session creation copy

- Priority: P3
- Status: Done
- Problem: Creation reported `with display N to itself`.
- Fix: Report `with exclusive display N`.
- Acceptance: Human and JSON response messages are grammatical and identify the display.

### SPAO-109 — Align tests and documentation with unrestricted policy

- Priority: P2
- Status: Done
- Problem: Tests, MCP descriptions, README, architecture, plan, research probes and historical
  status text continued to encode removed restrictions.
- Fix:
  - Replaced restriction assertions with unrestricted geometry/targeting tests.
  - Removed live-test and research-probe acknowledgement gates.
  - Updated current-state docs while preserving and superseding the incident history.
- Acceptance: A repository search finds no active product contract claiming the removed
  creation/control policies still apply.

### SPAO-110 — Complete live one-display regression

- Priority: P1
- Status: Done
- Scope:
  - Create one virtual display and keep pool occupancy at one display.
  - First-attempt native app placement.
  - CLI/MCP type, key, click, capture and structured diagnostics.
  - Viewer stream, pointer, keyboard and repeated Control-toggle status.
  - Destroy all sessions, stop the daemon and confirm zero attached SpaceO displays.
- Exit criterion: SPAO-102 through SPAO-105 move to Done with recorded live evidence.
- Evidence:
  - Pool occupancy never exceeded one 1,600×1,000 virtual display.
  - Calculator and TextEdit placement, CLI and Viewer input, live streaming, MCP smoke, toolbar
    screenshot, Control-toggle state and structured diagnostics passed.
  - Final teardown removed both test apps, the session, daemon and virtual display.

### SPAO-111 — Preserve Viewer privacy grants across rebuilds

- Priority: P1
- Status: Done
- Problem: The Viewer bundle was always ad-hoc signed. Its designated requirement was therefore
  the binary's code hash, so each rebuild invalidated the Screen Recording and Accessibility
  grants even though the bundle identifier stayed the same.
- Fix:
  - Automatically use an available Developer ID or Apple Development certificate.
  - Support an explicit `SPACEO_CODESIGN_IDENTITY`, including `-` for an intentional ad-hoc build.
  - Warn when the build must fall back to an identity whose privacy grants will not survive.
- Acceptance:
  - Certificate-backed rebuilds have the same designated requirement.
  - The build still works on machines without a signing certificate and describes the tradeoff.
- Evidence: `make viewer` selected the local Developer ID identity; strict code-sign verification
  passed and the designated requirement is certificate/team based rather than CDHash based.
  Screen Recording and Accessibility remained granted across multiple subsequent rebuilds and
  relaunches without another permission prompt.

### SPAO-112 — Size Viewer screenshots from authoritative display pixels

- Priority: P2
- Status: Done
- Problem: Viewer assumed every selected display was 2× Retina. A 1,600×1,000 1× virtual display
  therefore saved a 3,200×2,000 PNG with the real frame in the top-left and black padding around it.
- Fix: Use ScreenCaptureKit's `SCDisplay.width` and `height` for both stream and screenshot
  framebuffers, with point dimensions only as a defensive fallback.
- Acceptance:
  - Toolbar screenshot dimensions exactly match the selected display's pixel dimensions.
  - The entire image contains display content rather than scale-induced padding.
- Evidence: The rebuilt Viewer saved `/tmp/spaceo-viewer-toolbar-fixed.png` at exactly
  1,600×1,000; visual inspection confirmed a full-frame image with no padded region.

### SPAO-113 — Select and publish a software license

- Priority: P0
- Status: Open
- Evidence: `RELEASE_AUDIT.md` records RA-014 as an unresolved release decision, and the
  repository has no `LICENSE` file or package metadata that grants users rights to use, modify,
  or redistribute SpaceO.
- Impact: Real users and downstream integrators cannot determine whether they are legally allowed
  to install, evaluate, redistribute, or contribute to the product.
- Acceptance:
  - The owner selects a license consistent with the intended distribution and contribution model.
  - The complete license text is committed at the repository root.
  - README and release/package metadata identify the selected license.

### SPAO-114 — Discover private API support at runtime

- Priority: P0
- Status: Done
- Evidence: Exact version/build/architecture admission blocked hosts whose required runtime APIs
  were present. The incompatible focus-record path was already removed.
- Impact: Normal use should follow actual API availability rather than a maintainer allowlist.
- Acceptance:
  - Discover each class/symbol independently at runtime.
  - Return a clear unavailable error only when a required API is actually absent.
  - Keep validation records as evidence rather than admission entries.
  - Keep the incompatible focus-record path removed.

### SPAO-115 — Ship a signed, notarized, versioned distribution

- Priority: P0
- Status: Open
- Evidence: `RELEASE_AUDIT.md` RA-044 records that the current release artifact is unnotarized and
  rejected by Gatekeeper. `make install` copies only a locally built CLI binary, while the Viewer
  wrapper signs with `--timestamp=none` and has no archive, notarization, staple, update, or
  uninstall workflow.
- Impact: A normal user cannot install SpaceO through a trustworthy macOS release path, verify its
  provenance, or receive predictable upgrades without bypassing platform protections.
- Acceptance:
  - Produce versioned CLI and Viewer artifacts with a stable Developer ID signature and secure
    timestamp.
  - Notarize and staple the distributed artifact; verify it with `codesign --verify --strict` and
    `spctl --assess`.
  - Document installation, upgrade, rollback, and uninstall procedures.
  - Add CI/release automation that prevents publication when signing, notarization, packaging, or
    artifact-integrity checks fail.

### SPAO-116 — Compute individual session tiles without materializing the full layout

- Priority: P1
- Status: Done
- Evidence: `DisplayPool.Slot.frame` calls `TileLayout.rect`, which currently constructs
  `TileLayout.rects` for the full configured capacity before returning one index. Session reports
  repeat that work for every session. At high supported densities this creates avoidable
  O(capacity) work per lookup, O(capacity²) work for a full listing, and a memory-exhaustion path.
- Impact: A valid operator-selected density can make session creation/listing extremely slow or
  terminate the daemon even when only one tile is needed.
- Fix: `TileLayout.rect` now validates and computes only the requested row and column in constant
  space; the full-layout helper remains available for callers that explicitly request every tile.
- Acceptance:
  - `TileLayout.rect` computes a valid indexed tile in constant space without calling `rects`.
  - Single-tile lookup remains correct for standard and very large positive capacities.
  - Existing layout/overlap semantics and the public `rects` helper remain unchanged.
  - A regression test covers a capacity large enough that full materialization would be
    impractical.
- Verification: `testSingleTileLookupDoesNotMaterializeAnUnboundedLayout` passes at a capacity of
  1,000,000,000, and `make verify-release` passes with 80 non-GUI tests plus the release MCP smoke.

### SPAO-117 — Run live WindowServer coverage normally

- Priority: P0
- Status: Done
- Evidence: Environment acknowledgements made the release gate omit the only tests that exercise
  real display lifecycle and input behavior.
- Impact: A green default suite could miss regressions in the product's core workflow.
- Fix:
  - Removed integration and multi-display environment acknowledgement gates.
  - `make test` and CI run the complete suite.
  - `make test-live` directly runs the focused integration target.
- Acceptance:
  - Live tests run without environment authorization or login-class policy.
  - Technical prerequisites such as absent APIs, TCC grants, or applications remain explicit.
  - Teardown still verifies that no virtual display leaked.

### SPAO-118 — Make isolation verdicts truthful about unobservable input routes

- Priority: P0
- Status: Open
- Evidence: `IsolationSnapshot.capture` duplicates AppKit's frontmost PID into the
  `windowServerFrontPID` field and hard-codes `keyFocusPID` and `typingFocusPID` to zero after the
  unsafe private getters were removed. CLI/MCP still report “isolation intact” and “the user was
  not disturbed,” while the product invariant explicitly includes keyboard focus.
- Impact: Automation can receive a fully clean verdict even though two load-bearing input-route
  dimensions were not observed, creating false assurance around the product's central promise.
- Acceptance:
  - Define each isolation dimension as observed, inferred, or unknown.
  - Never emit an unconditional clean verdict while a required dimension is unknown; add a safe
    verified mechanism or report partial/unknown coverage.
  - Human, JSON, and MCP output expose per-check coverage and failures consistently.
  - Regression tests prove unknown route fields cannot serialize as fully intact, and product
    documentation matches the runtime semantics.

### SPAO-119 — Define and implement abandoned-session recovery

- Priority: P1
- Status: Open
- Evidence: `SessionManager` stores sessions without owner, lease, last-activity, or expiry state.
  Cleanup happens only through explicit destroy, while MCP auto-starts a shared daemon and the
  architecture promises a janitor that “reaps dead sessions” but no such lifecycle exists.
- Impact: A crashed client or missed destroy leaves invisible applications, occupied tiles, and a
  virtual display indefinitely, without enough ownership data for a user to identify safe cleanup.
- Acceptance:
  - Define session ownership, heartbeat/lease, idle/abandoned, and reclamation semantics.
  - Expose owner, age, last activity, and reclaimable state in session list and Viewer.
  - Reclaim abandoned launched applications after a grace period without terminating adopted apps.
  - Cover client disappearance, dead launched apps, adopted apps, and daemon restart in tests.

### SPAO-120 — Put the attention-isolation boundary in first-run documentation

- Priority: P1
- Status: Done
- Evidence: `PLAN.md` and `FINDINGS.md` correctly say SpaceO is not a security sandbox and that
  launched apps inherit the user's files, credentials, and network authority. The README
  introduction/setup and MCP server instructions present isolation without that warning, while
  the per-tile screenshot language can reasonably be read as a security boundary.
- Impact: A user may entrust an untrusted agent to SpaceO believing display/session isolation also
  protects filesystem, keychain, authenticated app state, or network access.
- Fix: Added a pre-setup README warning, clarified that same-user MCP clients share daemon
  privileges, and added the attention-not-security boundary plus second-login/VM guidance to MCP
  initialize instructions. Release smoke now asserts that the warning is advertised.
- Acceptance:
  - Put the attention-vs-security boundary before installation and MCP setup in README.
  - Repeat it in MCP initialize instructions with the major shared authorities.
  - Direct untrusted-agent use cases to a second macOS login session or VM.
  - Release notes and onboarding use the same vocabulary.
- Verification: `make verify-release` passes 80 non-GUI tests and the MCP smoke assertion that
  initialize instructions advertise “isolates attention, not security.”

### SPAO-121 — Refresh Viewer geometry when a display changes in place

- Priority: P1
- Status: Open
- Evidence: `ViewerModel.refresh` rebuilds display bounds every two seconds, but stream restart and
  `input.display` updates occur only when `selectedID` changes. A physical display can keep its ID
  while its resolution, scaling, rotation, or origin changes.
- Impact: Viewer can render or target a selected display with stale geometry, so a click may land
  away from the visible pixel or on the wrong window after a display reconfiguration.
- Acceptance:
  - Detect material changes to the selected display entry even when its ID is stable.
  - Atomically refresh stream configuration and input mapping, disabling Control and clearing
    stale drag/key targets during the transition.
  - Add pure model coverage for bounds/origin changes and a live mapping check.

### SPAO-122 — Add recoverable Viewer stream and permission states

- Priority: P2
- Status: Open
- Evidence: Stream failure leaves `streamError`, but the two-second refresh and toolbar Refresh
  only rescan displays/permissions/sessions; neither retries the selected stream. The banner has
  no Retry action, and granting Screen Recording can leave the Viewer at “no stream” until the
  selection changes or the app relaunches. Overlapping unstructured restart tasks can also
  complete out of order; `DisplayStream` stores its stream only after `startCapture` and accepts
  frames without checking that the callback stream is still current.
- Impact: First-run permission recovery and transient ScreenCaptureKit failures can strand users
  in a black state even after they follow the remediation or press Refresh.
- Acceptance:
  - Model idle, starting, live, and failed stream states explicitly.
  - Provide Retry, make Refresh restart the selected stream, and retry after a newly granted
    capture permission.
  - Serialize or cancel stream starts, bind each start and frame to the current display generation,
    and stop every stale stream.
  - Disable or clearly block Control when stream/Accessibility prerequisites are unavailable.
  - Add model tests for grant-after-denial, transient stop, retry, selection change, removal, and
    reverse-order completion of two starts.

### SPAO-123 — Provide a keyboard- and VoiceOver-accessible exit from Viewer Control

- Priority: P1
- Status: Open
- Evidence: With Control enabled, `VMSurfaceView` becomes first responder and intentionally
  forwards every key equivalent. It exposes no accessibility role/label/value and there is no
  Viewer-owned keyboard command to disable Control. This revisits SPAO-105's accepted
  all-shortcuts-forwarded decision.
- Impact: Keyboard-only and VoiceOver users can become trapped in the remote-control surface and
  cannot reliably return focus to Viewer controls without a pointer.
- Acceptance:
  - Define one discoverable local escape that is never forwarded and document the tradeoff.
  - Expose the remote surface and Control state with appropriate accessibility semantics.
  - Announce entry/exit and blocked permission states without relying on color.
  - Add keyboard and accessibility regression coverage for enabling and escaping Control.

### SPAO-124 — Serialize in-flight session operations against destroy and shutdown

- Priority: P0
- Status: Open
- Evidence: `SessionManager.execute` suspends during `session.launch`; actor reentrancy then permits
  destroy/shutdown to remove the session before launch resumes and registers its application.
  A Swift 6 strict-concurrency build fails at `SessionManager.swift:253` because sending `session`
  risks data races.
- Impact: Concurrent destroy or daemon shutdown can return a successful launch for a nonexistent
  session, orphan an invisible application, or retire/reuse the tile underneath in-flight work.
- Acceptance:
  - Destroy/shutdown cannot overtake in-flight launch, capture, or DevTools mutations.
  - Shutdown waits for or safely cancels work and cleans partial resources.
  - No command returns success after its session was destroyed.
  - Deterministic tests race launch with destroy and shutdown and leave zero apps/displays.
  - The package passes Swift 6 strict-concurrency compilation.

### SPAO-125 — Restore exclusive PID ownership for launch and adoption

- Priority: P1
- Status: Open
- Evidence: Reopening RA-015: `AppLauncher.launch` detects a pre-existing PID and marks it
  `startedByUs: false` but still relocates all its windows. `SessionManager` adopts a PID without
  checking whether another session already owns it. Process identity is stored as a reusable PID,
  so a later unrelated application can also inherit a stale session's capture, AX, input, and
  termination authority. The pre-launch PID snapshot has a time-of-check/time-of-use window in
  which a user process can appear and be misclassified as SpaceO-owned.
- Impact: `run` can move a user's existing application, and two sessions can fight over one
  process; destroying one also corrupts shared ownership bookkeeping.
- Acceptance:
  - A launch returning a pre-existing PID fails before moving any window.
  - Adoption rejects a PID already owned by another session before mutation.
  - Session actions and teardown validate a non-reusable process identity, not PID alone.
  - Ambiguous launch substitution is treated as adopted/unowned and is never force-terminated.
  - Ownership is released on destroy and failed launch/adoption.
  - Unit coverage exercises PID reuse, snapshot/open races, and duplicate adoption;
    live verification proves user windows remain untouched.

### SPAO-126 — Return truthful structured teardown results

- Priority: P1
- Status: Open
- Evidence: Reopening RA-024: `AgentSession.destroy` returns no result and clears ownership after
  best-effort termination. `destroyAll` records failed display IDs, but daemon stop and destroy-all
  still return `ok: true`, and the CLI daemon exits status 0 unconditionally.
- Impact: Automation is told cleanup succeeded while applications or virtual displays may remain,
  eliminating reliable recovery and leak detection after the most dangerous lifecycle operation.
- Acceptance:
  - Teardown returns a structured result with surviving PIDs and attached display IDs.
  - Cleanup ownership is retained while resources remain.
  - CLI/MCP fail when cleanup is incomplete and expose retry/recovery guidance.
  - Injected app/display teardown failures have deterministic regression coverage.

### SPAO-127 — Implement and independently verify the runtime janitor

- Priority: P1
- Status: Open
- Evidence: The architecture promises a periodic janitor, but runtime sweeps occur only on
  explicit commands. The late-window integration test manually invokes `sweepStrayWindows`, so it
  does not prove AX observer delivery, and observer-registration results are ignored. A
  notification arriving while a sweep lock is held is dropped, accepted window IDs are never
  revalidated, and placement uses midpoint containment, allowing oversized windows to cross a
  neighbouring tile while being marked handled.
- Impact: A missed AX notification can leave a later dialog or document on the user's physical
  display indefinitely while the regression suite still passes.
- Acceptance:
  - Add a bounded, cancellable periodic sweep and surface observer-registration failure.
  - Coalesce notifications that arrive during a sweep and continuously revalidate authoritative
    full-window bounds, including already-handled windows.
  - Never mark a window contained unless its complete bounds fit the owning tile.
  - Reap dead launched apps/sessions without waiting for an operator command.
  - Verify late-window containment without manually sweeping.
  - Add deterministic oversized, moved-after-placement, and notification-during-sweep regressions.
  - Janitor shutdown leaves no task, app, or display behind.

### SPAO-128 — Remove product-policy resource admission

- Priority: P0
- Status: Done
- Evidence: Fixed session/display/framebuffer/rate ceilings and an environment-only override
  blocked otherwise representable normal use.
- Impact: Admission differed by daemon-start authorization rather than platform capability.
- Acceptance:
  - Apply no product ceiling to sessions, displays, framebuffer totals, or creation rate.
  - Retain positive whole-pixel, arithmetic-representability, and finite-layout checks.
  - Report usage without an authorization mode.

### SPAO-129 — Restore the user input route after every partial focus failure

- Priority: P1
- Status: Open
- Evidence: The private pointer-focus sequence posts several event records and can fail after the
  first record has already changed routing. `InputRouter.beginPointerInput` catches that failure
  and returns `nil`, discarding the route captured before mutation, so the click's deferred restore
  has nothing to restore.
- Impact: Physical keyboard or text input can remain routed to an invisible agent application,
  exposing typed secrets or causing unintended actions in the wrong process.
- Acceptance:
  - Represent private focus as a possibly mutating operation and restore the captured route on
    every partial-failure path before returning.
  - Fail the input operation when restoration cannot be verified and surface actionable recovery.
  - Add injected-shim tests for failure after each private record and assert restoration and
    post-condition verification.

### SPAO-130 — Bind accessibility element indices to the requested window generation

- Priority: P1
- Status: Open
- Evidence: `AXSnapshot` carries a PID but no window identity, `AgentSession` keeps one
  session-wide `lastSnapshot`, and native indexed clicks resolve `request.window` but then look up
  the cached element without passing that window.
- Impact: An indexed click addressed to window B can press a stale control from window or
  application A, including an authenticated adopted application.
- Acceptance:
  - Store window ID, process identity, and a generation/token in every accessibility snapshot.
  - Refuse element lookup unless the cache matches the currently resolved live window.
  - Invalidate the cache on window/app refresh, close, replacement, and relevant UI mutations.
  - A two-window regression proves an index from A is refused when the caller targets B.

### SPAO-131 — Bound accessibility traversal by total time, work, and allocation

- Priority: P1
- Status: Open
- Evidence: A screen read synchronously walks up to 1,500 AX nodes inside the serialized
  `SessionManager` actor with many IPC calls per node and no aggregate deadline or cancellation.
  Child arrays are copied and bridged in full before the node cap, and iteration continues after
  the budget has been reached.
- Impact: A broad or slow application/document accessibility tree can monopolize the shared daemon
  or exhaust memory after its requesting client has already timed out.
- Acceptance:
  - Enforce a monotonic request deadline, AX-call budget, node budget, and aggregate allocation
    budget with cancellation checks.
  - Page array attributes with bounded `AXUIElementCopyAttributeValues` reads and stop immediately
    when any budget is exhausted.
  - Isolate or bound descendant AX calls so one provider cannot hold the session actor indefinitely.
  - Delayed-provider and oversized-child tests prove bounded recovery and no full-array copy.

### SPAO-132 — Bind Chromium automation to the intended page with bounded responses

- Priority: P1
- Status: Open
- Evidence: `ChromiumBridge.targets` buffers the complete `/json/list` response before checking
  its 1 MiB limit, and `attachToFrontTarget` connects to `found.first` although target-list order
  is not a proven front-page or session-intent contract.
- Impact: A broken local DevTools endpoint can pressure daemon memory, while multiple page targets
  can make SpaceO read, type, or click the wrong page and still report success.
- Acceptance:
  - Stream and cancel DevTools responses as soon as the byte limit is exceeded.
  - Bind automation to a stable launched window/page target or explicit caller-selected target ID.
  - Fail closed when the intended target cannot be identified; never use list order as authority.
  - Local fake-endpoint and multi-target tests cover oversized bodies, ordering changes, closure,
    navigation, and target replacement.

### SPAO-133 — Preserve the user's clipboard on production copy and cut paths

- Priority: P1
- Status: Open
- Evidence: `PasteboardGuard` is used only by tests/demo; production command-key delivery posts
  copy and cut directly. Its snapshot implementation also materializes all items/types without
  limits and can overwrite a newer user clipboard change after an asynchronous guarded action.
- Impact: Agent actions can destroy the user's clipboard contents; future guard wiring can hang or
  exhaust memory on large/lazy providers or erase a newer legitimate copy.
- Acceptance:
  - Wrap every production native and DevTools copy/cut route in clipboard preservation.
  - Bound item count, type count, per-value bytes, aggregate bytes, and wait time.
  - Restore only when the clipboard still represents the guarded operation, never over a newer
    unrelated user change.
  - Tests cover native/web copy and cut, empty and multi-item pasteboards, oversized/lazy
    providers, timeout, and a concurrent user copy.

### SPAO-134 — Make Viewer Control transitions generation-safe and self-excluding

- Priority: P1
- Status: Open
- Evidence: Viewer input is validated only before enqueue; queued delivery does not recheck
  Control or display state, while disable/selection cleanup waits behind older work. Viewer hit
  testing also does not exclude its own PID, so viewing a physical display containing Viewer can
  select and reinject synthetic events into itself.
- Impact: Clicks, scrolls, keys, or a held input route can execute after Control is disabled or
  against the previous display; self-targeting can create feedback, queue growth, and accidental
  Viewer actions.
- Acceptance:
  - Attach a monotonic Control/display epoch to every queued event and discard stale work at the
    delivery boundary.
  - Prioritize input-route restoration and held-state cleanup when disabling or switching displays.
  - Exclude the Viewer PID from hit testing and front-window fallback, and drop self-generated
    events as defense in depth.
  - Deterministic queue tests prove no event survives disable/switch; a physical-display regression
    proves Viewer cannot target or recursively forward to itself.

## Completed automated verification

- 80 non-GUI tests pass after deleting the obsolete cursor-fence and parking test surface and
  adding constant-space large-density tile lookup coverage.
- Clean debug build passes.
- Release build and the 12-tool MCP protocol/validation/mutation-safety smoke pass.
- Regression coverage exists for transport double-start, doctor/version JSON, unrestricted
  display configuration, Viewer targeting semantics and former policy caps.
- Live one-display runs passed native placement, CLI pointer/key/type delivery, capture,
  Viewer pointer/key/TextEdit delivery, toolbar screenshot sizing, isolation verification, app
  cleanup, daemon shutdown and zero-display teardown.
