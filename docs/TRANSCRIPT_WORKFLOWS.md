# Reliable interactive testing after the September transcript review

This contract addresses S01–S14 in the 14 September 2026 external controller transcript review.
The implementation plan and finding ledger are in
[the transcript improvement plan](plans/2026-09-14-transcript-improvements.md).
Historical incidents are not new reproductions. Live qualification remains subject to
[LIVE_TESTS.md](LIVE_TESTS.md); no authentication or focus-isolation bypass is supported.

## Discover and check readiness

Start with `spaceo --help`, `spaceo doctor --json`, and `spaceo schema --json`.
Every advertised command depth accepts `--help` without a daemon, lease or host setup.
The schema lists flags and their value/boolean classification; schema version 1 is additive.
`spaceo setup` is the existing guided configuration flow, to be run when configuring the host.

`ok` retains operation-success semantics. New `readiness` fields describe task prerequisites.
A successful empty session is not ready for an application interaction. `doctor` checks host
health; its separate readiness report requires a running daemon and daemon capabilities.
The client's permissions cannot substitute for the daemon's permissions. Use `doctor --interactive`
when a blocked daemon-readiness state must also make the command exit unsuccessfully.

`permission_state_mismatch` means the client and daemon reported different permission states.
Inspect all sessions before coordinating a restart. A grant already visible to the client does
not need another identical Settings prompt. There is no supported in-process TCC cache reset;
restart the permission-bearing process when the daemon continues reporting stale authorization.
Revocation fails permission checks rather than being interpreted as a missing application window.

Errors expose `errorCode` and, where available, `nextAction`. Examples include `permission_denied`,
`application_exited`, `window_not_ready`, `stale_snapshot`, `stale_geometry`, and
`isolation_requirements_unmet`. Local CLI errors under `--json` also remain JSON.

## Launch, wait, place and select

These examples use placeholders; do not put actual lease values in scripts, logs or documentation.
Keep credentials in the controller's memory. MCP automatically holds and supplies its leases.

```sh
spaceo run /Applications/Example.app --allow-no-windows --session ID --lease UUID --json
spaceo windows --pid PID --timeout 10 --session ID --lease UUID --json
spaceo place --window W --placement preserve --session ID --lease UUID --json
spaceo place --window W --placement cover --session ID --lease UUID --json
spaceo ax --window W --session ID --lease UUID --json
spaceo click --label 'Settings' --window W --session ID --lease UUID --json
```

`--allow-no-windows` distinguishes a launched/adopted live process from its pending window.
Late windows use the same exact-process ownership and existing watcher/janitor containment.
It does not establish a guarantee that an arbitrary app's self-created window never briefly
appears elsewhere. Strict isolation declines when required coverage is unavailable.
A bounded `windows --pid PID --timeout` matches the intended owned process even when another
app already has a window. It distinguishes a live process with no window from an exited process.
Cancellation and permission changes are checked during launch-window waits.

Launch arguments can be supplied as `--arguments-json '["--test-display","20"]'` or MCP's
`arguments` array. There are at most 128 arguments, 4096 bytes per argument and 32768 bytes total.
Custom arguments are refused for SpaceO-managed Chromium/Electron launches: overriding their
private profile, debug port or controller environment would break the managed route.
For rebuild loops, launch the canonical app path again through SpaceO; do not adopt every running
process with the same bundle identifier. External launch plus adoption is a separate input route
and must have its own isolation evidence. No automatic bundle-wide reattachment is performed.

Placement defaults to preserving window size while fitting its bounds into the assigned region.
A panel as large as the display begins exactly at the display origin. Initial placement, late-window
watching and re-parking share this calculation. Explicit policies are:

- `preserve`: retain normal size, clamp oversized dimensions to the region and relocate inside it.
- `fit`: request the normal inset frame, subject to application constraints.
- `cover`: request the exact display bounds; requires an exclusive display and an exact result.

`place` returns requested/observed bounds, exact-frame agreement and overflowing edges, including
on rejection. AX geometry is asynchronous and an application may refuse a resize or placement.
A contained smaller frame can satisfy normal placement; it cannot satisfy `cover`.
`windows` and `verify` no longer request a containment sweep themselves. Existing background
watchers still run. Use `place` or `repark` for an explicit placement action.

AX responses include a snapshot UUID. Supply it with an indexed click using `--snapshot UUID`.
Every new AX walk receives a fresh UUID. Existing stale-index refusal remains in force even when
the optional UUID is omitted. `--label` instead walks the target window afresh and requires exactly
one enabled control with that exact accessible label; missing and ambiguous labels are refused.
It is unsuitable for labels that change with a text field's value. An app-provided stable identifier
is not invented when the application exposes none.

## Geometry, capture source and action evidence

Responses include a `displayTarget` with runtime identity, logical bounds, backing scale and an
opaque topology generation, plus window geometry receipts. The singular `geometry` describes the
addressed or primary window; `geometries` contains receipts for the whole current inventory.
For coordinate click/drag, supply `--geometry TOKEN` (MCP: `geometry`) from the relevant window's
receipt. Display/session replacement, geometry or backing-scale changes invalidate it.
Coordinates remain window-local logical points, not screenshot pixels or global pointer positions.

The screenshot's `image` metadata gives the exact point/pixel mapping, including cropped origin.
For image pixel `(px, py)`, target window origin `(wx, wy)`, image origin `(ix, iy)` and scale `s`:
`x = px / s + ix - wx`, `y = py / s + iy - wy`.
Capture refuses detected target geometry changes during acquisition; refresh after a transition.

A external controller window placed on a SpaceO display does not prove external controller captured that display.
An app that chooses its source through `NSEvent.mouseLocation` still sees the physical pointer.
Integrations must explicitly select their capture display and report that source independently
of the overlay destination. Use distinct synthetic markers for source verification. SpaceO's
capture receipt names a display region or independent window; it does not attest an app's internal
screen-capture source. There is no pointer warp or fallback to a physical display.

Action receipts report route, target, requested duration where applicable and elapsed operation
time. Completion of an operation is not an assertion of the intended application postcondition.
`--duration` on drag is 0.05–30 seconds. Equal start/end coordinates hold in place; movement is
spread across the duration. Native transactions retain balanced release handling, and DevTools
attempts button release on cancellation/error. Verify the application's visible/AX postcondition.
Elapsed operation time includes dispatch, verification and transport-related work, not just hold time.

## Isolation and interruption

Known focus/Space breaches refuse further effects and pause the session. Launch and adoption
report before/after isolation. SpaceO no longer blindly reactivates the app saved before launch:
that could overwrite a newer user choice and conceal the original breach. `repark` reports its
isolation result and explicitly does not claim to restore focus, including when it moves zero windows.
After resolving the breach, explicitly resume. Operator pauses remain stronger than agent pauses.

`verify --require-window` requires an attached app window. `--strict` requires observed passing coverage for all
isolation dimensions; inferred or unknown key/text routing cannot satisfy it. Strict actions refuse before an
effect when the host cannot meet that requirement. Existing observed/inferred/unknown rows remain.
Use `--require-isolation menu_bar_owner,cursor_location,active_space` (MCP: `require_isolation`)
to require specific observed dimensions. The response records required/unmet dimensions and
a separate assertion result without relabeling partial coverage as full isolation.

Capture availability, image pixel variation, usable application content and presentation cadence
are separate facts. Visibility/freshness remain `unknown` where no reliable observation exists.
`rendered=true` is the legacy pixel-variation heuristic, never proof of readiness or animation.
external lock controller is an external authentication surface: SpaceO cannot reliably identify it from arbitrary
pixels or distinguish it from a frozen image of a lock screen. Do not bypass it or silently switch
to physical input. Record a blocked controller state, notify once on the transition, and wait for
manual unlock. Then refresh windows/AX/geometry and take a fresh synthetic sample before resuming
visual assertions. Continue independent source/offscreen work while blocked.

For display handoffs, store the latest user-selected mode, session generation, pending target,
blocked reason and pending postcondition in the controller's task state. This is the controller's
responsibility across compactions; a stale goal description must not override newer user steering.

MCP renews owned leases every ten seconds while the connection is alive, including while parked.
Successful session mutations also renew leases; read-only observations do not. MCP pause/resume
and `spaceo_session_destroy` with `keep_apps:true` support active → parked → active → released.
Connection loss stops renewal; existing expiry/recovery policy takes over. Stale heartbeat replies
cannot restore a released credential or replace a newer one. Credentials are not recovered from lists.
Explicit scoped release preserves unrelated sessions. CLI pause/resume and `destroy --keep-apps`
provide the same transitions. A pending teardown is distinct from future lease expiry and exposes
`lifecycleReason:cleanup_pending`; a missing-window cause is explicitly unknown when not observed.

`daemon stop` now waits for the identified old process to exit after successful teardown.
An older daemon without usable identity can only acknowledge stop, not prove completion.
`daemon wait --timeout 30` waits for an answering daemon and returns its instance/capability metadata;
it does not start one or prove application readiness. Global stop remains an operator action.

## Capture retention and resource limits

MCP screenshots are in memory: the daemon returns bounded PNG bytes without creating a temporary
image file. CLI `screenshot --memory --json` exposes the same route. The memory PNG limit is 5 MiB
within the existing 8 MiB wire frame. Reduce scale or region size when exceeded. Explicit `--output`
exports remain supported, and legacy CLI screenshots without `--memory` retain temporary-file behavior.
Existing artifacts are never removed by this change. For synthetic-only evidence, capture the
explicit window of the fixture below, not a broad display that may contain unrelated overlays.
Only publish reviewed metrics and synthetic evidence; routine support diagnostics contain no pixels.

Defaults admit at most 16 sessions, 8 displays, 16 creation attempts per rolling minute,
67,108,864 framebuffer pixels (256 MiB at four bytes per pixel), an 8192-pixel maximum edge and
320×240 minimum tiles in the requested display-mode geometry. Allocation checks run under the pool lock. Failed creation attempts count
against the rate limit; counts and framebuffer usage are retained only for owned resources.
A deliberate daemon-start `SPACEO_UNRESTRICTED_RESOURCES=1` lifts policy ceilings but retains
checked arithmetic. `pool` reports the effective policy and `unsafeOperatorMode:true` for this
explicit override. These framebuffer figures are admission accounting, not total WindowServer RAM.
Separately, the non-overridable [display-safety policy](DISPLAY_SAFETY.md) checks the display graph,
coordinates display owners, and persists limits of 4 creation attempts/minute and 12/ten minutes
across processes. The override and per-pool usage report do not replace that admission check.

## Bounded presentation fixture and live acceptance

`Tests/LiveFixtures/TranscriptProbe.swift` is a SpaceO-owned Metal/AppKit fixture. It supports a
normal 560×632 window, a fixed display-covering panel, and delayed menu-bar-shaped window creation.
It renders changing synthetic colors and a frame counter, forwards no input and records no desktop
pixels. It requires an explicit display ID and environment opt-in; no display fallback is used.
Building it is safe; executing it is a live test requiring the conditions in LIVE_TESTS.md.

```sh
swiftc -target arm64-apple-macos14.0 -parse-as-library \
  Tests/LiveFixtures/TranscriptProbe.swift -o /tmp/spaceo-transcript-probe
# Only on a dedicated/authorized live-test login:
SPACEO_TRANSCRIPT_PROBE_LIVE=1 /tmp/spaceo-transcript-probe \
  --display-id DISPLAY_ID --mode cover --duration 5 \
  | node scripts/presentation-evidence.mjs
```

The probe is bounded to 15 seconds of rendering plus a two-second callback drain. Raw evidence
separates submissions, GPU completions/failures, callback count and positive presentation timestamps.
The classifier returns null display FPS/drop counts when they are not measured. Complete timestamp
coverage exposes *presentation-timestamp cadence*, not physical scanout. Fresh captured frames and
external visibility remain unknown. See Apple's
[presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime) and
[presentation handler](https://developer.apple.com/documentation/metal/mtldrawable/addpresentedhandler(_:)) contracts.

On a qualified host, exercise the review's full matrix: normal/fixed/sheet/secondary windows at
1x and 2x, moved origins, physical/virtual synthetic source markers, concurrent sentinel typing,
SpaceO-only versus external-launch versus CUA routes, permission grants/revocation, manual
external lock controller lock transitions, process replacement, lease reconnect and final display removal.
A sheet and cross-application typing sentinel require additional controlled fixture orchestration;
the standalone presentation probe does not by itself establish those acceptance results.
Record commands and asynchronous results separately with daemon/session generations and route.
After one inconclusive probe, keep functional testing moving and repeat only after a relevant
state/hypothesis change. Do not extend this into excluded pixel-parity work.
