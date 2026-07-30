# SpaceO Release Audit

This is the defect log for the end-to-end release-hardening pass started on 2026-07-26.
Rounds 1–5 preserve the historical containment record. The runtime capability blocks were
removed on 2026-07-27 after the owner accepted the lifecycle and input-route fixes.

## Environment

- macOS 27.0 (26A5368g), Apple Silicon
- Physical displays: built-in Liquid Retina XDR plus AW3225QF at 240 Hz, mirrored
- Swift 6.4 toolchain; package language mode 5.9
- Accessibility and Screen Recording granted

## Findings

| ID | Severity | Status | Finding |
|---|---:|---|---|
| RA-001 | Critical | Fixed; live regression coverage enabled | Local displays and input can freeze after repeated MCP/integration runs |
| RA-002 | High | Fixed | Release daemon can ignore SIGTERM and remain orphaned |
| RA-003 | High | Fixed | A negative MCP `window` argument crashes the stdio server |
| RA-004 | High | Fixed | Concurrent daemon startup can unlink and replace a live daemon socket |
| RA-005 | Medium | Fixed | Stable MCP revision `2025-11-25` is not negotiated |
| RA-006 | Medium | Fixed | Default test command performs unsafe rapid virtual-display churn |
| RA-007 | Medium | Fixed | Installation, CI, artifact hygiene, and repeatable release smoke testing were missing |
| RA-008 | Low | Fixed | README test count and MCP tool list are stale |
| RA-009 | High | Fixed | A disconnected Unix-socket peer can terminate the daemon/MCP with `SIGPIPE` |
| RA-010 | High | Fixed | Native socket/CLI input can request unbounded click or typing work |
| RA-011 | Medium | Fixed | MCP startup/input framing can hang or consume unbounded memory |
| RA-012 | Critical | Fixed | Ownerless SpaceO displays are not detected before creating more |
| RA-013 | Medium | Fixed | Skipped live tests still wait in teardown with an invalid display baseline |
| RA-014 | Release | Owner decision required | No public license has been selected |
| RA-015 | High | Fixed; live rerun pending | App launch could reuse a user-owned process and two sessions could fight over one PID |
| RA-016 | Medium | Fixed | Private Chromium profiles leaked and DevTools/profile permissions were underspecified |
| RA-017 | Medium | Fixed | Space ownership, dead-app evidence, and isolation failures were reported incorrectly |
| RA-018 | Medium | Fixed | Invalid display sizes, densities, session names, coordinates, and counters were insufficiently validated |
| RA-019 | Medium | Fixed | Multi-monitor cursor coordinates and late-window refusal accounting were incorrect |
| RA-020 | Medium | Fixed | JSON-RPC request semantics and MCP tool schemas accepted ambiguous or unknown input |
| RA-021 | Release | Superseded | Exact-host qualification blocked runtime-compatible hosts |
| RA-022 | Low | Fixed | Release smoke returned before its auto-started daemon completed socket cleanup |
| RA-023 | Critical | Fixed; live rerun pending | Virtual-display attachment was allowed while physical displays were mirrored |
| RA-024 | High | Fixed | Concurrent shutdown could double-close the daemon listener and teardown failures were masked |
| RA-025 | High | Fixed | Auto-started daemons inherited a pipe whose reader disappeared with the MCP process |
| RA-026 | High | Fixed; live rerun pending | Chromium DevTools port allocation was racy and accepted wildcard/redirected endpoints |
| RA-027 | Critical | Fixed | Private key/typing-focus getters corrupt memory on macOS 27 |
| RA-028 | Critical | Fixed; live regression coverage enabled | Display graph contained only three ownerless SpaceO displays, disabling the physical screens |
| RA-029 | Medium | Superseded after capability restoration | Unsafe containment build still advertised itself as public version 1.0.0 |
| RA-030 | Medium | Fixed | Invalid CLI numeric flags were silently treated as omitted |
| RA-031 | High | Fixed | Public tiling/display APIs accepted memory-exhausting capacities and framebuffer sizes |
| RA-032 | Critical | Fixed; live rerun pending | Cursor and teardown fallbacks could target a SpaceO virtual main display |
| RA-033 | High | Fixed | Unicode, framing, timeout, capture, AX, session, and collection limits were incomplete |
| RA-034 | Critical | Fixed | A diagnostic probe still called corrupting getters and mutating binaries lacked runtime gates |
| RA-035 | High | Fixed; live rerun pending | Chromium sessions could outlive failed DevTools attach or silently fall back to browser-chrome input |
| RA-036 | High | Fixed | MCP screenshot responses could disclose an unexpected local path; demo used the general pasteboard |
| RA-037 | Medium | Fixed; live rerun pending | Multi-window placement was non-transactional and accepted invalid returned geometry |
| RA-038 | Medium | Fixed | Unknown CLI options and malformed display-size syntax were accepted |
| RA-039 | Medium | Fixed | Slow text input could outlive the client timeout after global input routing changed |
| RA-040 | High | Fixed | A remaining private front-process getter still relied on an undocumented output ABI |
| RA-041 | Critical | Fixed | Public production API still exposed the display-origin mutation proven to pin displays |
| RA-042 | Medium | Fixed | Failed-daemon startup diagnostics were read into memory without a size bound |
| RA-043 | Critical | Fixed; live rerun pending | Teardown and orphan guards ignored attached SpaceO displays once they became inactive |
| RA-044 | Release | Open | Release artifact is ad-hoc signed, unnotarized, and rejected by Gatekeeper |
| RA-045 | High | Fixed | Concurrent DevTools commands interleaved on one WebSocket and could drop each other's replies |
| RA-046 | Medium | Fixed | Every Chromium launch leaked an uninvalidated `URLSession` for the daemon's lifetime |
| RA-047 | High | Fixed | Window-watcher AX callbacks held an unretained watcher pointer and could use freed memory |
| RA-048 | Medium | Fixed | A cursor-fence startup failure during allocation left the new display attached until `deinit` |
| RA-049 | Medium | Fixed | Failed-teardown display IDs were never re-checked, refusing sessions after the display detached |
| RA-050 | Medium | Fixed | Coordinate web-clicks silently used zero window bounds when the bounds query failed |
| RA-051 | Low | Fixed | `\r\n` text was typed as two Return keystrokes; demo failures left launched apps running |
| RA-052 | Low | Fixed | Daemon transport errors lost their message through `localizedDescription`; page-read failures reported as an empty page |
| RA-053 | Low | Fixed | MCP daemon auto-start resolved a bare/relative argv[0] against the client's working directory |
| RA-054 | Low | Fixed | Socket line reads issued one syscall per byte; the cursor fence queried the display list twice per event |

### RA-001 and RA-012 — local display/input freeze and ownerless displays

**Observed:** The physical screen stopped updating and the local keyboard, trackpad, and mouse
appeared unresponsive while audio and networking continued. It has happened more than once during
SpaceO testing. The 2026-07-26 occurrence followed a full 60-test run and several MCP
daemon/display lifecycle runs.

**Live evidence:** There was no remaining `spaceo`, XCTest, or probe process. `WindowServer`,
audio, networking, and HID services were alive, and the built-in keyboard/trackpad was registered
without critical/reset errors. The initial active-display diagnostic saw one awake physical
display group. A later vendor/model inventory identified three attached SpaceO displays—IDs 291,
292, and 293—with no daemon owner. A final active/online inventory made the failure definitive:
the built-in display (ID 1) and external display (ID 4) remain online but are both inactive,
while only the three SpaceO displays were active. Re-associating the cursor and reactivating the
frontmost app did not recover it. A display-only sleep/wake cycle removed IDs 291–293, and a
remote screenshot subsequently showed the macOS lock screen. The latest CoreGraphics inventory
still reported the external display asleep and both physical displays inactive, however, so local
display/input recovery remains unconfirmed until the user verifies it or the graphical session is
reset.

**Confirmed defects:**

1. `SPOFocusWithoutRaise` makes the agent active for WindowServer input routing, but type, key,
   and coordinate-click commands did not route input back to the user's app.
2. `CursorFence.startIfNeeded()` checked whether the asynchronously created event tap existed,
   not whether its initializer thread existed. Rapid calls could start multiple session-wide
   head-insert taps, while teardown tracked only one.
3. The integration suite created and retired many virtual displays in roughly 34 seconds,
   including three simultaneously, on an active mirrored/high-refresh setup.
4. Display teardown success was ignored, ownerless SpaceO displays were not inventoried, and
   later sessions could add displays to an already-damaged graphical login session.
5. SpaceO allowed virtual-display attachment while the two physical displays were in a hardware
   mirror set; no post-attach check proved that the physical displays remained active.
6. Cursor-fence and teardown fallbacks used `CGMainDisplayID()`, which can designate a SpaceO
   virtual display after the physical graph has already failed.

**Containment:** The key/typing-focus verification was itself unsafe (RA-027) and has been removed.
The `focus-without-raise` capability is now unconditionally unavailable, so normal session
creation fails before attaching a virtual display or changing input state. Cursor-fence startup is
single-threaded. Display attach/detach is serialized with settling time, mirrored configurations
are refused, every attach must preserve all active non-SpaceO displays and avoid their bounds, one
idle daemon display is reused, teardown returns success/failure, `doctor` compares attached IDs
with the daemon pool and reports online/active user displays, and new sessions fail closed while
an ownerless display remains. Cursor recovery and surviving-window evacuation now use only an
active non-SpaceO display; when none exists, they fail without moving input or windows.

**Current closure:** The incompatible private focus design was removed, display/input use runtime
API discovery, and lifecycle/recovery tests run in the current graphical login without a policy
gate.

### RA-027 and RA-028 — memory corruption and physical-display loss

**Crash evidence:** Calling the presumed
`SLPSGetKeyFocusProcess(ProcessSerialNumber *)` /
`SLPSGetTypingFocusProcess(ProcessSerialNumber *)` ABI produced `EXC_BREAKPOINT`/malloc corruption
inside `GetProcessPID`. The relevant macOS diagnostic reports are
`spaceo-2026-07-26-155746.ips` and `probe2-2026-07-26-155528.ips`. The symbol names still resolved;
runtime symbol presence therefore did not establish ABI compatibility.

**ABI evidence:** Read-only disassembly of the macOS 27 arm64e dyld shared-cache image shows
`SLPSGetKeyFocusProcess` consuming `x0` and `x1`, then writing 8 bytes through `x0` and 1 byte
through `x1`. The old one-pointer declaration left `x1` undefined, explaining the memory
corruption. `SLPSGetTypingFocusProcess` consumes no arguments and returns a 32-bit value. These
signatures are not re-enabled merely from disassembly; the incompatible path remains removed.

**Safety change:** SpaceO no longer resolves or calls either getter. Snapshot fields remain only
for synthetic unit comparisons. `doctor` uses public display inventory plus safe capability
checks and no longer captures those focus values. Both virtual-display creation and focus routing
are fail-closed at the Objective-C boundary, making `Capabilities.canDrive == false`; this
deliberately blocks the product's core workflow even for direct library callers.

**Recovery attempted:** `CGRestorePermanentDisplayConfiguration()` did not change the damaged
graph. A display-only power cycle (`pmset displaysleepnow`, followed by a user-activity wake)
removed the three ownerless virtual displays without terminating applications or deleting data,
but local display/input recovery is not yet confirmed. This procedure is documented for incident
response, not automated: programmatically sleeping a user's display is itself disruptive.

**Historical release decision:** this incident stopped the release until the incompatible focus
path was removed and lifecycle behavior was repaired. Exact-host and special-login gates were
later removed by owner direction.

### RA-002 — release daemon ignores SIGTERM

**Cause:** Optimized builds released two locally held `DispatchSourceSignal` instances after their
last lexical use, while SIGINT/SIGTERM had already been changed to `SIG_IGN`.

**Fix/verification:** Signal sources are retained for daemon lifetime. The optimized daemon exited
with status 0 on SIGTERM and removed its isolated Unix socket.

### RA-003 — malformed MCP input crashes

**Reproduction:**

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
  "name":"spaceo_screenshot","arguments":{"window":-1}
}}
```

The original server exited with status 133 and `Fatal error: Negative value is not representable`.
Numeric conversion is now exact and nontrapping. Unit coverage and release MCP fuzz return tool
errors for negative, fractional, boolean, and enormous values without exiting.

### RA-004 and RA-009 — Unix transport lifecycle

The original server unconditionally unlinked its socket before binding, and `write(2)` to a
disconnected peer could deliver process-fatal `SIGPIPE`.

Startup is now serialized by a lock file; live SpaceO and foreign listeners are never unlinked;
cleanup verifies the bound socket's device/inode; accepted reads time out; clients and accepted
sockets use `SO_NOSIGPIPE`; and send/receive operations are bounded. Listener state is locked so
signal, command, and `atexit` cleanup cannot double-close a file descriptor that the OS has
already reused. Tests cover duplicate servers, concurrent stop, non-socket paths, foreign
protocol listeners, overlong paths, invalid timeouts, and disconnects.

### RA-005 — stale MCP negotiation

The server previously supported MCP through `2025-06-18`. It now negotiates the current stable
revision `2025-11-25` while retaining overlapping older versions. The July 2026 revision remains a
release candidate and is not targeted.

### RA-006, RA-010, and RA-011 — unsafe defaults and unbounded work

- `swift test` now includes live WindowServer coverage; `make test-live` remains the focused live
  target.
- Clipboard tests use a private named pasteboard rather than the user's general pasteboard.
- Every native input boundary caps clicks at three and text at 8,000 characters, requires finite
  coordinates, and validates keys, scroll ticks, PIDs, and window IDs.
- MCP stdio has a one-megabyte streaming line limit. Failed auto-start children are terminated by
  exact PID, and startup never blocks reading diagnostics from a still-running child. Daemon
  startup diagnostics use an unlinked temporary file rather than a transient parent's pipe, so
  a later write cannot terminate the daemon with `SIGPIPE`.
- Skipped integration tests now bypass display-leak teardown unless setup captured a real
  baseline; the old path waited 15 seconds per skipped case and left XCTest running.

### RA-015 through RA-020 — application, isolation, and validation correctness

- Launch always requests a new application instance and disables running-app substitution. If an
  app still returns an existing PID, SpaceO refuses to move user-owned windows. Explicit adoption
  rejects a PID already owned by another session.
- Chromium profiles are tracked, created with mode 0700, exposed only through a loopback DevTools
  listener, and removed after exit or partial-launch failure. Chromium now binds port zero
  atomically and publishes the selected port through its private profile; wildcard origins are
  not enabled, and target WebSockets must remain on the exact loopback port. About 419 MB of
  historical profile directories remain recovery/user data and were deliberately not deleted
  automatically.
- Releasing a pool now releases owned-Space bookkeeping. Refreshing windows no longer erases the
  evidence that an owned app exited. Audit findings and interaction-time isolation breaches now
  produce failed responses instead of `ok: true`.
- Display dimensions must be finite whole pixels, fit in 32 bits, and provide tiles of at least
  800×600; framebuffers are capped at 8192 pixels per side and 33,554,432 pixels total. Public
  tiling helpers refuse pathological materialization counts. Density must be positive. Session
  ids, keys, text, files, clicks, coordinates, PIDs, and window ids have explicit bounds and
  nontrapping conversions. CLI flags distinguish an omitted value from an invalid one instead
  of silently falling back to a different target. Public waits clamp or reject non-finite and
  effectively unbounded timeouts.
- Cursor snapshots now use CoreGraphics' live global event location rather than deriving
  coordinates from one screen's height. Window-watcher state is locked, refusals are deduplicated,
  and closed windows leave the refusal set.
- JSON-RPC version/id/method/params are validated; id-less tool mutations are ignored; tool
  arguments reject unknown keys; schemas advertise the same limits enforced by the daemon.
- Release smoke now waits until its unique daemon socket is removed, preventing a following
  verification run from racing the daemon's asynchronous orderly shutdown.

### RA-032 through RA-043 — second containment audit

- Cursor-fence recovery no longer assumes the CoreGraphics main display is physical. Teardown
  likewise evacuates windows only to an active non-SpaceO display.
- Native, CLI, transport, and MCP boundaries now consistently cap UTF-8 bytes, Unicode scalars,
  collection sizes, sessions, virtual displays, framebuffer pixels, Accessibility-tree work,
  screenshots, coordinates, waits, and request/response framing. Unix connect and read operations
  have total deadlines and handle interruption without unbounded retry.
- The capability probe no longer invokes either incompatible getter. Probe acknowledgement gates
  were removed; generated binaries were removed after verification.
- Chromium launch succeeds only after attaching to its private loopback DevTools endpoint.
  Partial launches are terminated and cleaned up, late app activation is rechecked, protocol
  messages are bounded, and explicit web input never silently falls back to browser chrome.
- MCP screenshot ingestion accepts only the exact UUID-named regular PNG it requested, rejects
  symlinks and oversized files, and always cleans up. The demo uses a private pasteboard instead
  of snapshotting the user's general clipboard.
- Window placement validates finite, bounded frames, requires each window to accept its tile, and
  rolls earlier windows back if a later placement fails.
- The CLI rejects unknown flags and requires exact `WIDTHxHEIGHT` syntax. Text input is rejected
  before focus mutation when its estimated delivery time would exceed the request budget.
- The remaining `SLPSGetFrontProcess` lookup/call was removed. Live frontmost-app checks use
  AppKit; the old C entry point is a non-querying compatibility stub. The production
  diagonal-parking entry point was later removed completely; display-origin experiments remain
  only in historical research probes.
- Failed-daemon diagnostic ingestion is capped at 64 KiB.
- Display removal is now complete only after the ID leaves the online display inventory.
  Diagnostics and orphan guards likewise include inactive-but-online SpaceO displays; live-test
  baselines use the online graph. A pure regression test prevents active-only retirement logic
  from returning.

### RA-045 through RA-054 — third non-GUI hardening pass

- `ChromiumBridge` is an actor, but actor reentrancy let a second DevTools command start while
  the first was suspended in `receive()`; each receiver could consume — and drop — the other's
  reply, turning concurrent commands into spurious timeouts. Commands now take a FIFO slot, so
  exactly one request/reply exchange is in flight per WebSocket. The bridge also invalidates its
  `URLSession` on teardown; previously every browser launch leaked one for the daemon's lifetime.
- `WindowWatcher` registered its AX observer callback with an unretained pointer to itself. A
  session destroyed on the daemon actor while the main run loop was mid-callback dereferenced a
  freed watcher. The refcon is now a retained box holding only a weak reference, released on the
  main run loop strictly after any in-flight callback, and `stop()` is idempotent under a lock.
- `DisplayPool.allocate` now retires the freshly created display immediately when the cursor
  fence fails to start, instead of leaving an unfenced framebuffer attached until a best-effort
  `deinit` ran.
- `SessionManager` re-checks recorded teardown failures against the online display inventory
  before refusing a session: a detach that completed after its timeout no longer blocks the
  daemon forever with a message claiming the display "remains attached". Displays that genuinely
  remain attached are still refused, and the independent orphan inventory still applies.
- Coordinate clicks routed through the DevTools bridge refused to proceed when the WindowServer
  bounds query failed, rather than translating page coordinates from a zero rect.
- `InputRouter.type` collapses `\r\n` to a single Return keystroke; the pre-flight duration
  estimate mirrors the same rule and has a regression test. The demo's cleanup now quits the
  apps it launched even on early FAIL paths.
- Daemon responses built from `TransportError` carry the error's real description instead of the
  generic `localizedDescription` of a Swift enum. `ax` reports a DevTools page-read failure in
  the outline instead of implying the page was empty.
- MCP daemon auto-start resolves the executable through `Bundle.main.executableURL`, so a bare
  or relative argv[0] no longer resolves against the client's working directory.
- Transport line framing reads in 64 KiB chunks (the protocol is one message per connection, so
  over-read bytes are never wanted by anyone), and the cursor-fence event tap fetches the display
  list once per event instead of twice. Framing edge cases — chunked arrival, empty line,
  unterminated EOF tail, oversized line — are pinned by a unit test.

## Verification history

### Round 1 — baseline before fixes

- `swift test`: 60 passed (46 unit, 14 live integration), 0 failed.
- `swift build -c release`: passed.
- Direct stdio MCP workflow: 12 tools listed; TextEdit launch, AX read, typing, key input,
  142,510-byte PNG screenshot, isolation audit, error result, and teardown passed.
- Official MCP Inspector `tools/list` against the release binary: passed.
- Result: **not release-ready**.

### Round 2 — non-GUI verification after fixes

- Default `swift test`: 77 discovered, 61 non-GUI tests passed and 16 live WindowServer tests
  skipped in 0.02 seconds, with no lingering XCTest process.
- Debug and optimized builds passed with warnings treated as errors.
- Release MCP smoke passed: stable protocol, 12 unique tools, malformed JSON/request handling,
  negative numeric containment, id-less mutation prevention, and clean stdio exit.
- Release daemon SIGTERM regression passed with status 0 and socket removal.
- Orphan guard regression passed on the affected login session: session creation was refused and
  attached SpaceO IDs remained exactly 291, 292, and 293.
- `make install`, CI, and release-smoke infrastructure exist. Public licensing remains unresolved.
- Result: **not release-ready** until graphical-session recovery and a cautious live workflow pass.

### Round 3 — incident containment

- Ownerless display IDs 291–293 disappeared and a remote screenshot rendered the macOS lock
  screen; local display/input recovery is still awaiting user confirmation.
- Both unsafe focus getter symbols were removed from resolution and all call sites.
- `virtual-display` and `focus-without-raise` are deliberately unavailable; `doctor` exits
  nonzero with `can drive sessions: no` and reports no SpaceO displays.
- At that historical containment point, 68 non-GUI unit tests passed while 16 live tests were
  omitted. Debug tests and optimized warnings-as-errors builds passed, as did Address Sanitizer.
- CLI and MCP now identify as `0.0.0-stopship`; installation requires an explicit development
  acknowledgment. MCP smoke proves a real session-create request is refused and leaves no session.
- Result at that historical point: containment only. Live GUI testing has since been restored.

### Round 4 — second non-GUI containment audit

- `make verify-release` passed: optimized build, 79 unit tests, stable MCP negotiation, 12 unique
  tools, malformed-input and stop-ship interlock checks, and clean MCP exit.
- The optimized build passed with warnings treated as errors.
- All 79 unit tests passed independently under Address Sanitizer and Thread Sanitizer with no
  reported memory or data-race finding.
- Default `swift test` discovered 95 tests: 79 passed, and all 16 live WindowServer tests were
  skipped before any display or input mutation.
- The MCP smoke script passed JavaScript syntax validation. No SpaceO daemon, Swift test/build,
  generated probe executable, or release-verification process remained afterward.
- SwiftPM reports no external package dependencies. The arm64 release binary links only system
  frameworks, but it is linker/ad-hoc signed with no Team ID and `spctl` rejects it. A Developer
  ID signature, notarization, and a versioned installation/distribution path remain required for
  direct public binary installation.
- The formal Codex Security workbench failed to initialize, so this audit makes no claim that a
  completed formal security scan exists; the static boundary review and sanitizer passes above
  are not a substitute for that release gate.
- A final read-only `doctor` check reported no daemon and no SpaceO displays, but both physical
  display IDs 4 and 1 were online and inactive with mirroring unsafe. Local recovery therefore
  remains unconfirmed.
- Result at that historical point: containment only. The replacement direct-delivery design and
  normal live testing were restored in later rounds.

### Round 5 — third non-GUI hardening pass (RA-045 through RA-054)

- `make verify-release` passed: optimized build, 81 unit tests, stable MCP negotiation, 12 unique
  tools, malformed-input and stop-ship interlock checks, and clean MCP exit.
- All 81 unit tests passed independently under Address Sanitizer and Thread Sanitizer.
- New regression tests: CRLF typing-duration equivalence, and transport line framing under
  chunked arrival, empty lines, unterminated EOF tails, and oversized lines.
- The live suite was not run in this historical round; later verification includes it normally.
- Result: containment posture unchanged; **still not release-ready** (RA-001/021/027/044 remain).

### Round 6 — capability restoration

- Removed the unconditional `virtual-display` and `focus-without-raise` capability blocks.
- Capability discovery now reflects the required runtime classes and symbols.
- Kept the serialized display lifecycle, mirroring refusal, post-attach physical-display checks,
  verified teardown, ownerless-display guard, cursor fence, and safe recovery targets.
- Kept the corrupting private focus getters removed. Input routing restores the captured user
  route and verifies public AppKit frontmost-application state before agent events are sent.
- Restored the 1.0.0 CLI/MCP identity, normal installation, operational MCP instructions, and
  session-creation contract.
- Live WindowServer tests run normally in the current graphical login.

### Round 7 — unrestricted creation and control policy

- Removed product caps on displays, sessions, tile density, framebuffer size, capture size, and
  session-id length. Positive, finite, integral and platform-representable values remain required.
- Removed creation refusals based on mirroring, ownerless SpaceO displays, physical-display
  activity/deactivation, framebuffer overlap, teardown history, and cursor-fence availability.
  Those conditions remain observable through diagnostics.
- Removed cursor fencing, pointer-warp accounting, parking helpers and lifecycle cooldowns from
  the codebase. Display mutations remain serialized, and teardown is still verified and reported.
- Removed the Viewer physical-display lockout, self/layer target exclusions, canvas/game denylist,
  adopted-Chromium refusal, and reserved Control-Command-Escape chord. Control is attempted for
  every selected display and target.
- Viewer pointer delivery now uses the proven focus-prime, stamped-move, down/up pacing sequence.
  The controller note cache resets when Control turns off.
- Fixed the clean-build `Transport.Server.thread` shadowing error, asynchronous AX placement
  verification race, `doctor --json`, and exclusive-session creation copy.
- Removed live-test and research-probe acknowledgement gates. Historical incident evidence remains
  in this document and the incident report, but its restrictions are superseded by owner decision.
- Added regression coverage for same-server double start, structured CLI JSON, unrestricted
  density/display geometry, and current Viewer targeting semantics.
