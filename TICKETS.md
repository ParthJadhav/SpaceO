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

### SPAO-192 — Prevent Chromium launch from taking the user's focus and Space

- Priority: P0
- Status: Open; release blocker
- Evidence: the September 16 full live suite ran 16 tests with no skips and failed the Chromium
  isolation check. A focused checkpoint reproduced the breach before DevTools input. Passing
  documents on the command line did not fix it; that production trial was reverted. The public
  MCP launch correctly refused with `isolation_breached`, but the disturbance had already occurred.
- Acceptance: identify and prevent launch-time activation without blind foreground restoration,
  then repeat the full no-skip live suite and matrix on an undisturbed authorized login and the
  exact release candidate. Retain pre/post focus, Space, display, and cleanup evidence.
- Record: [September 16 diagnostic evidence](docs/validation/2026-09-16-live-qualification.json).

### SPAO-193 — Diagnose Cursor exiting before launch process identification

- Priority: P1
- Status: Open; release blocker
- Evidence: the September 16 matrix returned `launch_failed`: Cursor.app exited before SpaceO
  could identify it. Subsequent Electron actions were not exercised. This run cannot qualify the
  host because an unrelated default-socket daemon appeared during testing.
- Acceptance: determine the exit cause without disturbing an existing user instance, verify the
  intended private instance launches, and pass the complete Electron and cleanup sequence in a
  full matrix run on the final source/candidate.
- Record: [September 16 diagnostic evidence](docs/validation/2026-09-16-live-qualification.json).

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
- Superseded in part: two of the removals above were later put back deliberately, and the text
  of this ticket no longer describes shipped behaviour.
  - Viewer Control is **not** available for every selected display. SPAO-123 reinstated
    Control-Command-Escape as a local-only exit, and `ViewerControlPolicy.controlRequest` now
    refuses a physical display ("Physical displays are view-only; select a SpaceO display") and
    an empty SpaceO display held for its reuse grace. Arming Control on the user's own monitor
    would route the Viewer's input straight back to the desk SpaceO exists to keep clear.
    Pinned by `ViewerAccessibilityTests.testModelRefusesControlOnPhysicalOrEmptySpaceODisplays`
    and `testControlAdmissionExplainsEveryBlockedPermissionStateInWords`.
  - Everything else in this ticket stands: display provenance is not an allowlist for *watching*,
    and the CLI/MCP input paths still reject no target on bundle family or provenance.

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
- Status: Done
- Evidence: The repository-root `LICENSE` contains the complete MIT License, and the README
  identifies the project as MIT-licensed.
- Decision: MIT was selected as a conventional permissive license that permits use, modification,
  redistribution, and commercial integration while preserving the copyright and warranty notice.
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
- Evidence: The fail-closed Developer ID DMG, notarization, stapling, checksum-signing, fresh-mount
  verification, GitHub workflow, and install/upgrade/rollback/uninstall documentation are
  implemented. `RELEASE_AUDIT.md` RA-044 remains unresolved because no credentialed,
  qualified public artifact is recorded.
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

### SPAO-117 — Separate safe tests from live WindowServer tests

- Priority: P0
- Status: Done
- Evidence: Running live WindowServer tests by default mutates the user's display graph, launches
  applications, and sends input during ordinary development and CI.
- Impact: `make test` must stay non-mutating while live coverage stays one command away.
- Fix:
  - `make test` and CI use `scripts/test.sh safe` and exclude `IntegrationTests`.
  - `make test-live` runs `IntegrationTests` in the current graphical login with no opt-in
    environment variables, host attestation, or qualification record.
- Acceptance:
  - Safe tests never create displays, launch GUI applications, or send input.
  - Live tests skip only on an unmet technical prerequisite.
  - Teardown still verifies that no virtual display leaked.

### SPAO-118 — Make isolation verdicts truthful about unobservable input routes

- Priority: P0
- Status: Done
- Original problem: `IsolationSnapshot.capture` duplicated AppKit's frontmost PID into the
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
- Verification: `IsolationCoverageTests` proves live input-route dimensions remain unknown,
  verdicts stay partial, and CLI/MCP output never claims intact or undisturbed coverage.

### SPAO-119 — Define and implement abandoned-session recovery

- Priority: P1
- Status: Done
- Original problem: `SessionManager` stored sessions without owner, lease, last-activity, or expiry state.
  Cleanup happens only through explicit destroy, while MCP auto-starts a shared daemon and the
  architecture promises a janitor that “reaps dead sessions” but no such lifecycle exists.
- Impact: A crashed client or missed destroy leaves invisible applications, occupied tiles, and a
  virtual display indefinitely, without enough ownership data for a user to identify safe cleanup.
- Acceptance:
  - Define session ownership, heartbeat/lease, idle/abandoned, and reclamation semantics.
  - Expose owner, age, last activity, and reclaimable state in session list and Viewer.
  - Reclaim abandoned launched applications after a grace period without terminating adopted apps.
  - Cover client disappearance, dead launched apps, adopted apps, and daemon restart in tests.
- Verification: controller, reclamation, persistence, detached-recovery, recovery-coordinator,
  and daemon-restart integration suites cover owner metadata, leases, fencing, grace, retry, and
  launched-versus-adopted cleanup.

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
- Status: Done
- Original problem: `ViewerModel.refresh` rebuilt display bounds every two seconds, but stream restart and
  `input.display` updates occur only when `selectedID` changes. A physical display can keep its ID
  while its resolution, scaling, rotation, or origin changes.
- Impact: Viewer can render or target a selected display with stale geometry, so a click may land
  away from the visible pixel or on the wrong window after a display reconfiguration.
- Acceptance:
  - Detect material changes to the selected display entry even when its ID is stable.
  - Atomically refresh stream configuration and input mapping, disabling Control and clearing
    stale drag/key targets during the transition.
  - Add pure model coverage for bounds/origin changes and a live mapping check.
- Verification: `testSameIDGeometryChangeAtomicallyResetsInputAndRestartsStream` and viewport
  mapping tests cover stable-ID bounds/origin changes.

### SPAO-122 — Add recoverable Viewer stream and permission states

- Priority: P2
- Status: Done
- Original problem: Stream failure left `streamError`, but the two-second refresh and toolbar Refresh
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
- Verification: `ViewerStreamLifecycleTests` covers every listed state and reverse-order start;
  native bug-bash verification passed Retry/Refresh, physical/virtual streaming, and removal.

### SPAO-123 — Provide a keyboard- and VoiceOver-accessible exit from Viewer Control

- Priority: P1
- Status: Done
- Original problem: With Control enabled, `VMSurfaceView` became first responder and intentionally
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
- Verification: `ViewerAccessibilityTests` covers the reserved Control-Command-Escape lifecycle,
  VoiceOver-visible role/value/help, announcements, held-key release, and near-miss forwarding.

### SPAO-124 — Serialize in-flight session operations against destroy and shutdown

- Priority: P0
- Status: Done
- Original problem: `SessionManager.execute` suspended during `session.launch`; actor reentrancy then permitted
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
- Verification: `SessionLifecycleRaceTests` and strict-concurrency warnings-as-errors builds pass.

### SPAO-125 — Restore exclusive PID ownership for launch and adoption

- Priority: P1
- Status: Done
- Original problem: Reopening RA-015: `AppLauncher.launch` detected a pre-existing PID and marked it
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
- Verification: ownership/budget and live integration suites cover substitution, duplicate claims,
  exact process identity, PID reuse, failed ownership, and release.

### SPAO-126 — Return truthful structured teardown results

- Priority: P1
- Status: Done
- Original problem: Reopening RA-024: `AgentSession.destroy` returned no result and cleared ownership after
  best-effort termination. `destroyAll` records failed display IDs, but daemon stop and destroy-all
  still return `ok: true`, and the CLI daemon exits status 0 unconditionally.
- Impact: Automation is told cleanup succeeded while applications or virtual displays may remain,
  eliminating reliable recovery and leak detection after the most dangerous lifecycle operation.
- Acceptance:
  - Teardown returns a structured result with surviving PIDs and attached display IDs.
  - Cleanup ownership is retained while resources remain.
  - CLI/MCP fail when cleanup is incomplete and expose retry/recovery guidance.
  - Injected app/display teardown failures have deterministic regression coverage.
- Verification: `TeardownFailureTests` and recovery integration tests cover surviving apps,
  attached displays, retryable ownership, structured CLI/MCP failure, and successful cleanup.

### SPAO-127 — Implement and independently verify the runtime janitor

- Priority: P1
- Status: Done
- Original problem: The architecture promised a periodic janitor, but runtime sweeps occurred only on
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
- Verification: `JanitorAndControlTests`, reclamation tests, and
  `testWindowWatcherContainsLateWindowsWithoutBeingSweptByHand` cover these paths.

### SPAO-128 — Remove bounded WindowServer resource admission

- Priority: P0
- Status: Done
- Evidence: Bounded session, display, framebuffer, tile-size and creation-rate ceilings refused
  workloads the platform would have accepted, and the display-graph preflight blocked creation
  outright on a mirrored desk setup.
- Impact: By owner decision SpaceO imposes no product-policy ceilings; CoreGraphics and
  WindowServer failures are surfaced to the caller instead.
- Fix: Removed the finite ceilings, the `SPACEO_UNSAFE_RESOURCE_LIMITS` operator budget, and the
  pre/post-attach display-graph refusal and rollback.
- Acceptance:
  - Any positive, representable geometry and density reaches the platform API.
  - Mirror, orphan, overlap, and physical-display state never blocks `session create`.
  - Usage is still reported; teardown is still verified.

### SPAO-129 — Restore the user input route after every partial focus failure

- Priority: P1
- Status: Done
- Original problem: The private pointer-focus sequence posted several event records and could fail after the
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
- Verification: `FocusRecoveryTests` injects failure after every record and covers successful,
  failed, and unverifiable restoration without sending input after unsafe recovery.

### SPAO-130 — Bind accessibility element indices to the requested window generation

- Priority: P1
- Status: Done
- Original problem: `AXSnapshot` carried a PID but no window identity, `AgentSession` kept one
  session-wide `lastSnapshot`, and native indexed clicks resolve `request.window` but then look up
  the cached element without passing that window.
- Impact: An indexed click addressed to window B can press a stale control from window or
  application A, including an authenticated adopted application.
- Acceptance:
  - Store window ID, process identity, and a generation/token in every accessibility snapshot.
  - Refuse element lookup unless the cache matches the currently resolved live window.
  - Invalidate the cache on window/app refresh, close, replacement, and relevant UI mutations.
  - A two-window regression proves an index from A is refused when the caller targets B.
- Verification: `AXSnapshotGenerationTests` covers cross-window refusal, invalidation, and
  superseded traversal generations.

### SPAO-131 — Bound accessibility traversal by total time, work, and allocation

- Priority: P1
- Status: Done
- Original problem: A screen read synchronously walked up to 1,500 AX nodes inside the serialized
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
- Verification: `AXTraversalTests` covers deadline, cancellation, call/node/allocation budgets,
  paged children, provider timeouts, and immediate exhaustion.

### SPAO-132 — Bind Chromium automation to the intended page with bounded responses

- Priority: P1
- Status: Done
- Original problem: `ChromiumBridge.targets` buffered the complete `/json/list` response before checking
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
- Verification: `ChromiumBridgeTests` covers streaming size refusal, loopback binding, ambiguous
  and unknown targets, explicit target identity, and closed/unbound commands.
- 2026-09-22 follow-up: new-tab bodies now use the same streaming bounds; queued commands and
  compound input/navigation operations retain their original socket/target through suspension.
  Deterministic cancellation/rebind regressions are recorded as AE-021 and AE-022 through AE-027
  in `docs/AGENT_EFFICIENCY.md`. These do not replace live release qualification.
- Evaluation follow-up AE-046/047/048 requests an engine execution budget, releases returned
  remote object groups under the original command lease/binding, and validates viewport/error
  results through the common evaluator. A Node/V8 protocol probe supplements deterministic
  command tests; it does not qualify a Chrome build.

### SPAO-133 — Preserve the user's clipboard on production copy and cut paths

- Priority: P1
- Status: Done
- Original problem: `PasteboardGuard` was used only by tests/demo; production command-key delivery posted
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
- Resolution/verification: native and DevTools Command-C/Command-X routes now fail closed because
  macOS offers no atomic restore that cannot overwrite a newer user copy. `PasteboardGuard` is
  bounded for controlled flows, and `PasteboardGuardProductionTests` covers native/web refusal,
  limits, lazy providers, timeout, and concurrent clipboard changes.
  Efficiency follow-up AE-043/044/045 removes unused native/Web clipboard parameters and
  validates refusal without contacting a desktop service. Diagnostic bounds share the same
  algorithm with an in-memory provider; the single-worker timeout now covers metadata and
  values. Real AppKit adapter behavior still requires host qualification.
  Selection follow-up AE-049/050/051/052 separates bounded previews from complete clipboard
  reads, refuses oversized or incomplete selections before copy/cut, and requires a known
  complete value before append-style paste. Cut receipts no longer equate selection changes
  with confirmed deletion. See `docs/AGENT_EFFICIENCY.md` for deterministic evidence and limits.

### SPAO-134 — Make Viewer Control transitions generation-safe and self-excluding

- Priority: P1
- Status: Done
- Original problem: Viewer input was validated only before enqueue; queued delivery did not recheck
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
- Verification: `JanitorAndControlTests`, `ViewerAccessibilityTests`, and the native physical-
  display bug bash cover epochs, transition cleanup, held keys, self-exclusion, and local escape.

### SPAO-135 — Expose scroll, hover, and drag to agents

- Priority: P0
- Status: Done
- Original problem: `InputRouter.scroll` was fully implemented and had zero call sites; there was
  no MCP tool, CLI command, or daemon command for scroll, pointer move, or drag. Measured against
  a standard computer-use action set, SpaceO implemented screenshot, left click, type, and key,
  and nothing else.
- Impact: An agent could not reach anything below the fold of any window, could not reveal a
  hover-only menu or tooltip, and could not move a slider, reorder a list, or select text by
  dragging. These are ordinary steps on ordinary UI, not edge cases.
- Fix:
  - Added `spaceo_scroll`, `spaceo_move`, and `spaceo_drag` across MCP, CLI, and the daemon.
  - Extracted `InputRouter.withPointerTransaction` so every pointer action shares one route-hold,
    window-stamp, and verified-restore body; a new action cannot skip the stamp.
  - A scroll and a hover both take a point, because an app with two scrollable or hoverable
    regions routes by what is under the pointer.
- Acceptance:
  - Every pointer action is reachable from MCP and the CLI and posts stamped per-PID events.
  - The MCP smoke asserts all three tools are advertised.
- Verification: `PointerSurfaceTests`, `scripts/mcp-smoke.mjs` (16 tools).

### SPAO-138 — Complete the click matrix and stop silent downgrades

- Priority: P1
- Status: Done
- Original problem: `MouseButton` was `left`/`right` only. On the element path,
  `InputRouter.press(element)` silently dropped both `button` and `count`; on the coordinate path
  the `AXPress` short-circuit silently dropped `count`. `spaceo_click --element 7 --button right
  --count 2` reported success and performed a single left press.
- Impact: Silently doing the wrong thing is worse than refusing — the agent proceeded believing a
  context menu had opened or a word had been selected.
- Fix:
  - Added `middle` to `MouseButton` with its own down/up/dragged event types.
  - The accessibility shortcut is taken only for a plain single left click.
  - An element reference with a button, count, or modifiers is refused at both the MCP boundary
    and the daemon, naming the coordinate alternative.
- Verification: `PointerSurfaceTests.testElementClickRefusesPointerOnlyArguments`, MCP smoke.

### SPAO-139 — Support modifier-held pointer actions

- Priority: P1
- Status: Done
- Original problem: `InputRouter.click` never set `event.flags`, so shift-click, cmd-click, and
  option-drag were impossible. Modifiers existed only for standalone key presses.
- Fix: Added `ModifierKeys.parse` and a `modifiers` argument on click, move, drag, and scroll,
  stamped onto every synthesised event in the transaction.
- Verification: `PointerSurfaceTests.testModifierParsingAcceptsAliasesAndRejectsUnknownNames`.

### SPAO-141 / SPAO-142 — One capture scale, reported

- Priority: P0
- Status: Done
- Original problem: `spaceo_click` took window-local points; window captures were hard-coded to 2×
  (`Capture.swift`) while tile captures stayed at 1×; Chromium clicks rebased again into CSS
  viewport coordinates. Nothing in any response told the agent which space it had.
  `Demo.swift` encoded the ambiguity as an assertion that accepted either scale.
- Impact: This is the defect that made vision-driven agents fail silently. An agent reading a
  coordinate off the default screenshot clicked at half the intended position — the wrong control
  near the top-left, a hard out-of-bounds error near the edges.
- Fix:
  - `Capture.defaultScale` is 1 for both window and region capture, so an image pixel and a click
    coordinate are the same number.
  - Every capture returns an `ImageGeometry` (origin kind, scale, pixel and point dimensions,
    global origin, window id) plus a one-line `advice` string, carried in the response message.
  - Added an optional `scale` (1–4) and a tile-relative `x/y/width/height` sub-region, clamped to
    the session's own tile so a caller cannot widen its view past its tile.
  - Out-of-bounds refusals name the scale mistake rather than leaving the agent to guess.
- Verification: `PointerSurfaceTests` coordinate-space cases, the tightened
  `testCapturesTheAgentScreen` live assertion, and `spaceo demo`'s
  "tile screenshot pixels equal click points" check.

### SPAO-149 — Make TileLayout.rects and rect agree

- Priority: P2
- Status: Done
- Original problem: `rects` clamped `n = min(64, capacity)` and computed `grid(for: n)` while
  `rect` computed `grid(for: capacity)`. At capacity 100 the two produced an 8×8 layout of
  240×135 tiles against a 10×10 layout of 192×108.
- Impact: Overlapping tile rects are exactly the cross-agent leak tiling exists to prevent.
- Fix: `rects` derives the grid from the true capacity and clamps only how many rects it
  materialises, so the allocation bound stops silently changing the layout.
- Verification: property test asserting `rects[i] == rect(index: i)` across the 64 boundary.

### SPAO-154 — Restore host input state if the Viewer dies while captured

- Priority: P0
- Status: Done
- Original problem: Entering Control decoupled the mouse, hid the cursor, and disabled system-wide
  global hotkeys; only the normal exit path restored them. A crash or force-quit while captured
  left the user's whole machine with a hidden cursor, a decoupled mouse, and Spotlight, Mission
  Control, and screenshot shortcuts disabled, recoverable only by logging out.
- Fix: `HostInputGuard` — a durable Application Support breadcrumb written before the machine-wide
  change, signal and `atexit` handlers that restore the minimum critical state, an
  `applicationWillTerminate` hook, and a launch-time repair pass for deaths the previous run could
  not observe. Restoration is idempotent, so every path may run redundantly.
- Verification: `HostInputGuardTests` — 16 tests over the `breadcrumb:` and `restore:` seams:
  breadcrumb lifecycle; `beginCapture` arming both the on-disk marker and the in-process flag before
  the host is touched; abandoned-capture repair, including restore-before-clear so a death mid-repair
  is still repairable, one-shot behaviour, and presence alone as the signal so a torn write is never
  read as "no capture was active"; the `applicationWillTerminate` path and its idempotence; repair of
  a marker left by a process that ran no teardown at all; that the signal handler's pre-encoded
  `unlink` path is exactly the file `mark` writes; and `sigaction` read-back proving every catchable
  signal is armed. Mutation-checked — dropping `breadcrumb.mark()` from `beginCapture`, clearing
  before restoring, and removing `SIGTERM` from the handled set each fail the suite.
  Manual-only: the restore running *inside* a real signal or `atexit` context. It flips machine-wide
  cursor, mouse-association, and hotkey state and cannot be asserted from a test process; it is
  qualified by force-quitting a Viewer that is holding Control.

### SPAO-156 / SPAO-157 — Viewer first-run and dead ends

- Priority: P1
- Status: Done
- Original problem: `ViewerModel.requestPermissions()` had no callers, and because stream start
  refuses without a pre-flight grant, macOS's own first-capture prompt never fired either — a new
  user had to find System Settings and add the app by hand. The Session/Display scope picker
  disabled itself permanently once a display row was selected. `saveScreenshot` reported failure
  only through `streamError`, which no view read, so a failed screenshot was completely silent.
- Fix:
  - A Grant Access action raises the real system prompts, then re-polls and restarts the selection
    so a granted permission produces a live stream without relaunching.
  - Scope switching is gated on `canSwitchCanvasMode` — whether the display *hosts* a session,
    not whether one is currently selected.
  - Screenshot outcomes surface as a banner with Reveal in Finder, an accessibility announcement,
    and an event-log entry.
- Verification: `ViewerControlPlaneTests`.

### SPAO-164 — Match Space attribution on display UUID alone

- Priority: P1
- Status: Done
- Original problem: `SPOSpacesForDisplay` accepted a managed-display entry when the UUID matched
  **or** there was only one entry **or** the entry was literally named `Main`, so it could return
  the *user's* main display's Space list for an agent display id.
- Impact: That result reaches `AgentActivity.claim(spaces:)`, which every isolation verdict is
  decided against — the user's own active Space filed as agent territory makes `verify` report a
  breach on every run the user caused themselves, and a check that cries wolf stops being read.
- Fix: Match on UUID only; report no Spaces when there is no UUID to match, so callers treat the
  set as unknown instead of inheriting a guess. `Stage.hasOwnSpace` already fails safe on empty.

### SPAO-172 — Derive the MCP lease-injection set from one shared definition

- Priority: P1
- Status: Done
- Original problem: `MCPControllerContext.prepare` matched owner-scoped mutations against a
  hard-coded string list that had to stay in sync with the daemon's `resolveForMutation` call
  sites by hand. Adding `scroll`, `move`, and `drag` to the daemon without adding them to that
  list made all three permanently uncallable over MCP.
- Impact: The failure is unrecoverable from the client's side — the daemon answers "controller
  lease is required", and leases are deliberately never returned in a session list, so the agent
  has no way to obtain one. A new pointer command looked implemented and was unusable.
- Fix: `DaemonCommand.ownerScopedMutations` in `Protocol.swift` is the single definition both
  sides read.
- Verification: `PointerSurfaceTests.testEveryPointerCommandIsOwnerScopedSoMCPAttachesItsLease`,
  and the end-to-end MCP run that first exposed it.

### SPAO-173 — Scroll through accessibility, because synthetic wheel events do not arrive

- Priority: P0
- Status: Done
- Evidence: Measured against TextEdit on macOS 27 through a standalone probe: per-PID scroll wheel
  events in pixel units and line units, stamped and unstamped with the window id, with and
  without an explicit event location, and with the continuous-phase field set — **every variant
  reported success and moved nothing**. The same host reports `MISS focus-without-raise` in
  `doctor`, and a per-PID coordinate click into a document did not move the insertion point
  either, which points at the removed focus record as the load-bearing dependency.
- Impact: `spaceo scroll` returned `ok: true` while the view did not move. Silent success is the
  failure mode this project treats as worse than refusal, and it made every below-the-fold task
  quietly impossible.
- Fix:
  - `AX.scrollArea(at:in:windowID:)` resolves the scroll area **within the requested window**.
    An app-wide hit test answers with the frontmost window, and TextEdit's document and Untitled
    windows occupy identical frames — so the first implementation scrolled the wrong window and
    reported success.
  - `AX.scroll` sets the scroll bar's documented 0...1 `AXValue` and **compares the read-back
    against the starting value**, so an element pinned at its limit or ignoring the write is
    reported as not scrolled rather than as a scroll.
  - The synthetic wheel remains a fallback for canvas surfaces with no scroll bar, and that path
    now ends in an explicit unconfirmed error rather than a success.
- Verification: live before/after capture — content moved from lines 1–70 to 128–200, bringing
  the deliberately off-screen `TARGET-BELOW-THE-FOLD` marker into view.

### SPAO-174 — Report unconfirmed pointer delivery instead of bare success

- Priority: P0
- Status: Done (reporting); the underlying delivery gap is tracked below
- Evidence: A coordinate click into a TextEdit document reported `ok: true` and did not move the
  insertion point — a marker typed after the click landed immediately after the pre-click marker.
  Coordinate clicks only take effect when an accessibility element under the point accepts an
  `AXPress`; the raw per-PID fallback is not known to reach AppKit on a host without the
  focus-without-raise record.
- Impact: The agent believes it clicked. Every downstream step then reasons from a state that
  never happened, which is strictly worse than a refusal it could have handled.
- Fix: `InputRouter.click` returns a `PointerDelivery` distinguishing a confirmed accessibility
  action from unconfirmed synthetic delivery. `Response.warnings` carries the distinction, the
  CLI prints it as `unconfirmed:`, and MCP renders it as `UNCONFIRMED:` ahead of ambient notes.
- Remaining decision for the owner: whether unconfirmed coordinate delivery should become a hard
  error. SPAO-105 deliberately moved this surface from refusing to attempting, so leaving it as a
  loud warning respects that decision rather than silently reversing it.

### SPAO-175 — A running daemon keeps executing the binary it started with

- Priority: P2
- Status: Done
- Original problem: `make install` replaces `~/.local/bin/spaceo`, but the daemon is a long-lived process
  and continues to run its original image. Three rebuild-and-retest cycles during the SPAO-173
  investigation silently tested unchanged behaviour, and the fix only appeared after
  `spaceo daemon stop`.
- Impact: Anyone developing against SpaceO — or upgrading it — can conclude a change had no
  effect, or run a mixed pair of new client and old daemon whose wire expectations differ.
- Acceptance:
  - `spaceo doctor` reports the running daemon's version alongside the CLI's, and flags a
    mismatch.
  - A client refuses, or clearly warns, when its protocol expectations exceed the daemon's.
  - Installation and upgrade documentation states that the daemon must be restarted.
- Fix: Every daemon response carries its startup-time version, Mach-O build UUID, executable
  SHA-256, pid, instance id, and capability state. `spaceo doctor` compares the build UUID first
  (signing changes the digest but not the compiled image), falls back to SHA-256, and fails on a
  known mismatch. MCP startup emits the same mismatch/unknown warning, and the install/upgrade
  guide requires a restart before interpreting a new client against an old daemon.
- Verification: `UnitTests.testCurrentExecutableBuildUUIDIsAvailable`, protocol round trips, MCP
  smoke, and the retained computer-use records cover current-image reporting and a matching
  signed Viewer helper.

### SPAO-176 — Give web content the pointer actions it can actually receive

- Priority: P0
- Status: Done
- Evidence: `ChromiumBridge` implemented click, type and key but had **no scroll, hover, or drag**.
  Web content is the one surface where nothing else can substitute: the renderer drops synthetic
  events the WindowServer did not vouch for (`FINDINGS.md` §4.7), and a page's scroller is not an
  accessibility scroll bar, so neither native path can move it either. A page was therefore
  unscrollable — the single most common thing an agent does on the web.
- Impact: Every below-the-fold web task was impossible, and hover-revealed menus and drag
  interactions were unreachable.
- Fix:
  - `scroll`, `move`, and `drag` dispatched through `Input.dispatchMouseEvent`.
  - `viewportPoint(windowLocal:windowOrigin:)` shared by every pointer action, so a click and a
    scroll aimed at the same pixel cannot land in different coordinate spaces.
  - The bridge's click no longer maps every non-right button onto left, which had turned a middle
    click into an ordinary click on whatever was under it.
- Verification: `scripts/computer-use-check.mjs --suite=web` asserts DOM effects, not return
  values — click fires a DOM click, scroll reaches `scrollY` 1541, hover fires `mouseenter`, drag
  produces a selection, and typing reaches an input.

### SPAO-177 — Make `web` mean "these are viewport coordinates" on pointer actions

- Priority: P1
- Status: Done
- Original problem: `spaceo_read_screen` prints page elements with **CSS viewport** coordinates
  (`[w0] button — CLICK ME at (70,37)`), but every pointer tool takes **window-local** points.
  Browser chrome offsets the two by its own height, so an agent that read its own screen output
  and passed those numbers back aimed roughly a toolbar above its target. `click --web` already
  existed as a flag and was accepted and silently ignored.
- Impact: The only positional information an agent has about a page was not usable with the tools
  that consume positions.
- Fix: `web: true` on click, scroll, move and drag means the supplied coordinates are already CSS
  viewport coordinates and are dispatched straight through DevTools. The previously dead `--web`
  flag on click now does this.
- Verification: the web suite drives hover and drag from coordinates it reads out of
  `read_screen`, which is the path an agent actually takes.

### SPAO-178 — Disclose a clipped screen read

- Priority: P1
- Status: Done
- Evidence: `AXTraversal` clips every value at 480 bytes and marks it with an ellipsis, but
  nothing above that reported the clipping. A 200-line document read back as its first few lines,
  looking exactly like a complete read of a short document.
- Impact: An agent concludes content does not exist and moves on — the same class of failure as a
  silent click, one level up.
- Fix: `Response.truncated` is set when any value was clipped, and the message says so in words
  and names the alternatives (screenshot, or scroll and read again).
- Verification: the native suite asserts that a clipped read discloses the clipping.

### SPAO-179 — Electron renderer scrolling has no safe channel

- Priority: P1
- Status: Done (vertical VS Code-family editor scrolling)
- Evidence: Cursor's editor has no settable AX scroll area and ignores background synthetic wheel
  input. A private-profile DevTools launch reached an endpoint but produced no AX window unless
  Cursor was foregrounded, which visibly stole the user's route and was rejected. Screen-reader
  mode exposed richer AX text ranges, but per-PID keys, selected-range mutation, and
  `AXScrollToVisible` all produced byte-identical screenshots.
- Fix:
  - Exact VS Code-family bundles receive a private, per-launch extension directory containing a
    small semantic adapter. It invokes the editor's own `editorScroll` command without activating
    the app or moving the physical pointer.
  - A random live-memory-only token authenticates a bounded protocol over a `0600` Unix socket in
    a `0700` temporary root. The socket's type, owner and permissions are checked on every call.
  - Routing fails closed unless the process has one represented window, exactly one visible
    active editor, and the requested point's AX ancestry identifies a code editor in that exact
    window. Only unmodified vertical scroll is admitted.
  - The adapter reports visible ranges before and after; unchanged ranges are an error. The MCP
    conformance test independently requires a before/after screenshot difference.
  - The credential is never persisted. Only the temporary root is journaled so orderly and crash
    recovery cleanup can remove it safely after the owned process exits.
- Verification: The production release binary passed the real MCP Electron suite 8/8 against
  Cursor: launch, readable AX tree, rendered window, observable editor scroll, isolation, and
  clean teardown. The full native/web/Electron matrix passes 25/25. Physical cursor coordinates
  and the user's frontmost application were unchanged across the semantic scroll.
- Remaining scope: Split editors, arbitrary Electron shells, horizontal or modifier-held editor
  scrolling, renderer hover, and renderer drag do not use this VS Code semantic path and remain
  unconfirmed; this ticket closes the scrolling release blocker without claiming generic pointer
  parity.

## Product trust audit — 2026-09-05

The following implementation fixes have deterministic regression coverage. They do not close the
live or independently signed release gates. Evidence and remaining work:
[product trust audit](docs/validation/2026-09-05-product-trust-audit.md).

### SPAO-180 — Make guided setup exercise the current ownership and cleanup contract

- Priority: **P1**
- Status: Source fixed; live verification blocked by Accessibility
- Setup omitted `controllerOwner`, so every self-test create was refused by the current daemon.
  Cleanup responses were discarded and a fixed session name could collide with another run.
- Setup now owns a unique session, carries its lease, validates a private PNG, and reports failed
  or unknown cleanup. Lost create responses never trigger an unowned destroy.

### SPAO-181 — Check daemon readiness and generate usable MCP configuration

- Priority: **P1**
- Status: Source fixed; deterministic checks pass
- Setup checks daemon build identity and daemon-local driving/capture prerequisites. Doctor
  refuses unknown daemon provenance/health. Configuration paths survive quotes, backslashes,
  dollar signs, command-substitution characters, and newlines in shell, JSON, and TOML.

### SPAO-182 — Keep failed display retirement out of allocation

- Priority: **P1**
- Status: Source fixed; deterministic failure reproduced and regression passes
- A failed retirement retains its display for cleanup but invalidates its backing. Pool allocation
  now skips that backing. Occupancy reports copy mutable state while holding the pool lock.

### SPAO-183 — Keep total framebuffer accounting representable

- Priority: **P2**
- Status: Source fixed; boundary regression passes
- Individually valid display sizes could overflow aggregate byte accounting. Admission now checks
  the aggregate integer boundary. No product-policy display or session cap was introduced.

### SPAO-184 — Refuse blocked and stale Viewer Control transitions

- Priority: **P1**
- Status: Source fixed; deterministic admission/transition checks pass; live verification pending
- Blocked admission fell through into Control enablement. Delayed pause replies could arrive
  after permission loss, and rapid release/retake could race an older resume. Admission returns
  immediately on refusal, final enablement rechecks current state, and transitions cannot overlap.
  A failed takeover reports any failed resume rollback with affected session IDs and recovery
  guidance; a deterministic regression reproduces the previously suppressed failure.

### SPAO-185 — Prevent delayed Viewer polls from discarding newer state

- Priority: **P1**
- Status: Source fixed; delayed-transport regression passes
- Polls could overlap indefinitely and an older empty list could remove a newly created lease.
  One poll runs at a time with one coalesced follow-up; completed mutations invalidate older replies.

### SPAO-186 — Require real evidence from the computer-use matrix

- Priority: **P1**
- Status: Source fixed; app-free harness tests pass; fresh full live matrix pending
- JSON-RPC errors with no tool result could read as success; failed/missing captures could count
  as pixel changes; partial isolation could pass. These now fail or report blocked explicitly.
- Early process exit no longer hangs cleanup. Run fixtures use a private unique directory and
  raw error text stays out of the privacy-safe report's step labels.

### SPAO-187 — Release Viewer pauses after a daemon transport outage

- Priority: **P1**
- Status: Source fixed; deterministic timeout regression passes; live reconnect check pending
- Five seconds of failed transport was treated as proof the daemon had exited and lost its
  pause flags. Disconnect now attempts to resume pauses placed by the Viewer; failures identify
  affected sessions and explain manual recovery without claiming the agent resumed.
- Verification: `ViewerControlPlaneTests.testDisconnectAttemptsOwnedPausesAndReportsUnconfirmedResume`
  reproduces the missing resume before the fix and verifies the failed-resume report afterward.

### SPAO-188 — Preserve signing identity for repeated local audits

- Priority: **P1**
- Status: Signed local CLI and Viewer built and verified; live access verified through cmux
- Ordinary Swift builds leave the CLI linker/ad-hoc signed with a hash-based designated
  requirement. `make signed` now creates Developer ID artifacts at fixed `.build/signed` paths,
  rejects ad-hoc fallback, and verifies a replacement CLI against the previous CLI's requirement.
- Verification: real certificate signing, strict CLI/nested Viewer verification, repeat signing,
  and refusal of an explicit ad-hoc identity without modifying the existing signed CLI.
- Signing does not grant privacy access. The signed CLI still reports Accessibility denied on
  the task launcher while cmux grants access. The clean signed matrix subsequently passed all
  36 checks through cmux; notarized public distribution remains unqualified.

### SPAO-189 — Repeat matrix after interrupted graphical session

- Priority: **P1**
- Status: Closed as interrupted-run qualification; clean rerun passed all 36 checks
- The 2026-09-05 signed matrix through cmux returned 32 pass / 3 fail / 1 blocked / 0 skipped.
  Electron published no windows and no usable AX outline. Its renderer scroll remains blocked
  by SPAO-179. User display IDs changed during the run and an orphaned SpaceO display remained
  after the audit daemon exited, despite its pool reaching zero sessions/displays.
- The original login later returned with its original display IDs and no SpaceO/orphaned displays.
  No recovery was required. This interrupted run cannot qualify app reliability or establish a
  SpaceO defect. Retained outcomes and exact limitations: `docs/validation/2026-09-05-product-trust-audit.md`.
- The full XCTest live suite separately passed all 16 tests with zero skips. The clean matrix
  rerun passed Electron and cleanup, retained unchanged user topology, and left no SpaceO or
  orphaned displays. Record: `docs/validation/2026-09-05-signed-matrix-clean-actions.json`.

## Completed automated verification

- The deterministic suite passes, including the semantic Electron adapter and scoped cleanup,
  agent pointer surface,
  capture coordinate space,
  unrestricted geometry/density admission and constant-space large-density tile lookup, without
  invoking live WindowServer tests. Exact counts belong to a dated run, not to this summary:
  `make test` prints them, and the records under `docs/validation/` retain them.
- Clean debug build passes with no warnings.
- Release build and the MCP protocol/validation/mutation-safety smoke pass. `scripts/mcp-smoke.mjs`
  pins the advertised tool count itself, so that number lives in the gate rather than here.
- `scripts/computer-use-check.mjs` drives the real MCP stdio server end to end across three
  application classes — native AppKit (TextEdit), Chromium web content (Google Chrome), and
  Electron (Cursor). Where an action has an observable effect the suite asserts the *effect*:
  native scroll is checked by comparing screenshots, and every web action is checked against page
  state the fixture encodes in its window title. Cursor editor scroll requires both an adapter
  visible-range delta and an independent screenshot difference. The latest full run passes every
  step it exercises; the harness prints the count, and `docs/validation/` retains it per run.
  Run it with `node scripts/computer-use-check.mjs [--suite=native|web|electron|all]`. A suite
  whose host application is missing is reported `SKIP` and holds the run at exit `2`; add
  `--require-full` (or `make computer-use-check-full`) to make that a hard failure at release time.
  It found SPAO-172 through SPAO-178, none of which any unit test or the protocol smoke saw.
- Regression coverage exists for transport double-start, doctor/version JSON, bounded display
  configuration, Viewer targeting semantics, and release qualification records.
- Live one-display runs passed native placement, CLI pointer/key/type delivery, capture,
  Viewer pointer/key/TextEdit delivery, toolbar screenshot sizing, isolation verification, app
  cleanup, daemon shutdown and zero-display teardown. `scripts/test.sh live --require-full` has
  since run the whole suite with no failures and no skips, including
  `testTwoSessionsOnOneDisplayStayInTheirOwnTiles`, which had failed in the 2026-07-31 run;
  the retained green record is `docs/validation/2026-08-03-live-suite-arm64.md`. The later
  `docs/validation/2026-08-29-claude-full-feature-regression.md` audit is explicitly blocked and
  is not a green live qualification. The placement-boundary defect
  behind that earlier failure is tracked as SPAO-148 in PRODUCT_BACKLOG.md. The later
  2026-09-05 dedicated rendered-pixel proof closes its verification; the general live suite alone
  was insufficient evidence.

### SPAO-190 — Keep agent input paused throughout Viewer Human Control

- Priority: P1
- Status: Done
- Evidence: In the live Viewer, Control paused the session but the still-enabled Resume Agent
  button unpaused it while Human Control remained enabled. This allowed conflicting input.
- Fix: Disable manual Pause/Resume throughout Human Control and outstanding pause/resume
  transitions. Pending manual changes also block a new takeover and another manual change, so
  requests cannot arrive in the wrong order. Published transition state updates the UI immediately.
  The model rejects bypass attempts with an actionable Release Input message.
- Verification: `ViewerControlPlaneTests.testManualAgentResumeIsRefusedWhileHumanControlIsEnabled`
  and a rebuilt, Developer ID-signed live Viewer confirm the refusal/disabled state. Local
  Control–Command–Escape resumes the agent and re-enables manual pause. Normal Viewer quit
  also resumes an externally owned session without destroying it.
- Usability: The empty Viewer now exposes New Session in the canvas, with an accessible label
  and Command–Shift–N menu shortcut. Verified both through the live accessibility tree and keyboard.

### SPAO-148 / SPAO-163 / SPAO-168 — Close retained live-evidence gaps

- Status: Done (development-host verification; exact distribution qualification remains open).
- SPAO-148: two live rendered-pixel runs confirm a foreign oversized window is visible in the
  positive control, absent from the protected neighboring CLI capture, and reported as a failed
  source-session health audit. Fixture process, daemon, and displays clean up with unchanged
  physical topology. See `docs/validation/2026-09-05-capture-isolation-repeat.json`.
- SPAO-163: the same granted-host report records the safe public AX key/text-route proxy as
  inferred with its precise limits, without the incompatible private getters.
- SPAO-168: the expanded signed MCP matrix passes 36/36 with no skips, blocks, or failures;
  retained JSON and README now report that result.

### SPAO-159 — Advertise the local release shortcut during Control

- Status: Done
- The menu now switches from Command–Shift–I for entry to Control–Command–Escape for release,
  matching the chord reserved by the input surface. Native menu release and local Escape were
  exercised live. The signed Viewer builds and passes signature verification.
- Related usability fix: the canvas offers Capture Input only when the same prerequisites as
  the toolbar hold. Physical displays and missing-permission states no longer invite a blocked action.


## September 14 transcript review (S01–S14)

Implementation and deterministic regression work is tracked in
[the finding ledger](docs/plans/2026-09-14-transcript-improvements.md), with the agent-facing
contract in [TRANSCRIPT_WORKFLOWS.md](docs/TRANSCRIPT_WORKFLOWS.md). Code fixes cover placement,
readiness/errors, strict refusal, launch/window lifecycle, memory capture, controller renewal,
stop completion and allocation budgets. The synthetic presentation probe compiles independently.
Historical findings are not closed as live-qualified: the review's macOS/permission/external lock controller,
source-marker, foreground-sentinel and presentation matrix remains required on a qualified host.
Application-owned capture selection and controller compaction state remain integration duties.
