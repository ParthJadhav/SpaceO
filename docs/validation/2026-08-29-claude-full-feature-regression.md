# 2026-08-29 — full-feature regression, macOS 27.0 arm64

Independent feature-by-feature audit of the working tree, run locally in the current graphical
login. Every documented, supported surface was exercised at least once; every row below ends
PASS, FIXED + PASS, BLOCKED with a concrete technical reason, or a documented non-goal.

This record does not supersede any earlier record under `docs/validation/`.

## 1. Artifact and host binding

| | |
|---|---|
| repository | `/path/to/SpaceO`, branch `main`, worktree off |
| starting commit | `925fe29f70c23b3039bb5660305bbf456b9d8190`, 0 ahead / 0 behind `origin/main` |
| starting checkout | intentionally dirty (see §7) |
| host | macOS 27.0 (build 26A5406e), arm64, Apple M5 Pro |
| toolchain | Swift 6.3.3 (swiftlang-6.3.3.1.3), Xcode 26.6 |
| CLI under audit, as found | `.build/release/spaceo` SHA-256 `7982c315b031f3e86816f9527f74459d334737ad78c83fe6d7c689e0445e380c`, identical to the installed `~/.local/bin/spaceo` |
| final CLI after the fixes in §5 | SHA-256 `da6fb526cc1351f41e07fe44b8b6e28daac5332af0dbdc923218bfb850a2f28e`, Mach-O build UUID `ab705852-5a42-37b5-aec1-979217de831b` |
| final Viewer helper | `.build/SpaceO Viewer.app/Contents/Helpers/spaceo` (Developer ID signed), SHA-256 `c3c9da8e78eaf04213915bebda358222919de819fc1890dbff64b3bfb84c3568`, build UUID `ab705852-…` — **same build UUID as the final CLI** |
| end-to-end computer-use gate build | CLI/helper build UUID `16923e02-6ddd-36ce-80e0-d18c512dad41`; `spaceo doctor` reported `daemon matches CLI: yes` before the 30/30 run |
| capabilities | virtual-display, space-query, per-pid-events, ax-window-id, accessibility, screen-recording all `ok`; `focus-without-raise` `MISS` (documented, load-bearing for BUG-1) |

A signed helper and the standalone CLI have different SHA-256 values while sharing a build UUID;
that is the documented identity rule, and the UUID is what binds these results to a build.

### Physical display environment — read this before interpreting §4

This host has a **built-in Color LCD plus an external AW3225QF (3840×2160, UI 1920×1080 @ 240 Hz),
hardware-mirrored**. The external panel slept and woke on its own several times during the audit
with no SpaceO action in between; `spaceo doctor` reported `online 1; active 1 / mirroring off`
and `online 2, 1; active 2 / mirroring on` at different points. The live gate below was affected,
and its row says so explicitly. This is the exact configuration README's
"Display-stack risk" boundary names.

Start and end state are the same mirrored topology: AW3225QF master mirror, Color LCD hardware
mirror, both online, zero SpaceO displays.

## 2. Gate results

Deterministic gates, run after the fixes below. The computer-use row records its exact build
binding because one isolated cache-enumeration hardening change landed after that end-to-end run:

| gate | result |
|---|---|
| `make verify-release` | **PASS** on final UUID `ab705852-…` — release build, **554 safe tests, 0 failures**, MCP smoke: protocol, 17 tools, validation, mutation safety, clean exit |
| `make test` (safe suite) | **PASS** — included in the above; 529 at HEAD → 554 with the 25 regression tests added here |
| `Tests/ReleaseSecurityTests.sh` | **PASS** (not invoked by any Makefile target; run by hand) |
| `Tests/LiveTestGateTests.sh` | **PASS** (same) |
| `make computer-use-check-full` | **PASS** on UUID `16923e02-…` — **30/30 exercised steps**, exit 0, native + Chromium + Electron, no skips; the later isolated partial-enumeration hardening is covered by the final 554-test suite and 8 focused blackout tests |
| `make viewer` | **PASS** — bundle built and signed with Developer ID Application (Team `75LRT8TRQY`), satisfies its Designated Requirement |
| `make release-check` | **PASS** — release configuration consistent for 1.0.0 |
| `make release-dry-run` | **PASS** — plan printed, signing identity and notarization input reported `MISSING (publication will fail closed)`, nothing mutated |
| `make release-preflight` | **fails closed** as designed without `SPACEO_CODESIGN_IDENTITY` — correct behaviour, not a defect |
| `make verify-distribution` / `make verify-release-candidate` | **PASS** — both refuse with a usage message when their required argument is absent |
| `scripts/check-swift-toolchain.sh` | **PASS** — fail-closed CI guard; refuses without `SPACEO_REQUIRED_*` / `DEVELOPER_DIR` pinning |
| `git diff --check` | **PASS** — clean |
| `scripts/metrics-report.mjs` | **PASS** — text and `--json` summaries over a tagged run; log and report both `0600` |
| `make test-live-full` | **BLOCKED** — see below |

### `make test-live-full` — BLOCKED, with evidence

Earlier in the session, on the **unmodified HEAD build with the external display asleep**, this
gate passed cleanly:

```
live test run: 16 executed (16 passed, 0 failed), 0 skipped, 16 defined
live test run check passed: all 16 live tests executed against the real WindowServer
```

Re-run on the final work while the external display was **awake and mirrored**, it initially
exposed two independent symptoms:

1. **`testStageCreateAndDestroyLeavesNoDisplay`** compared raw display-mode snapshots even though
   production teardown deliberately treats the inactive hardware-mirror follower's synthetic
   mode as invisible. The built-in follower changed from `modeWidth 1920 / modePixelWidth 3840`
   to `modeWidth 960 / modePixelWidth 1920` while the virtual display was attached and returned to
   baseline by teardown. BUG-11 corrects the test to assert the same safety contract production
   uses. The corrected targeted live test **passes with the external panel awake and mirrored**.
2. **Application-launching live tests** intermittently fail with
   `launch failed: pid N produced no window within 15s`. This is BUG-9 below and was
   **reproduced on the untouched HEAD binary** (§5, BUG-9 control run).

A second attempt minutes later was worse, not better — **6 of 16 failed**, five of them the same
`AppLauncher` launch timeout and the sixth the same display-mode assertion. The accessibility
blackout had broadened to affect every live test that launches an application:

```
testCaptureOfAgentScreenIsActuallyRendered      launch failed: … produced no window within 15s
testFullWorkflowHasNoCoveredIsolationBreach     launch failed: … produced no window within 15s
testJanitorReapsAnExitedAppAndReleasesItsClaim  launch failed: … produced no window within 15s
testTwoSessionsOnOneDisplayStayInTheirOwnTiles  launch failed: … produced no window within 15s
testWindowWatcherContainsLateWindows…           launch failed: … produced no window within 15s
testStageCreateAndDestroyLeavesNoDisplay        attaching the virtual display changed a user monitor setting
```

After the test-contract correction, the mirror-follower observation is no longer a failure. The
remaining full-suite blocker is the accessibility blackout. A later attempt broadened from two
to five application-launch failures, all with WindowServer evidence that the application had
drawn its windows. `Stage.swift` and `AppLauncher.swift` are not modified; the only production
change on this failure path is appended diagnostic text, which cannot cause the timeout.

**A skip is not a pass, and neither is this.** The gate remains BLOCKED by BUG-9's intermittent
host Accessibility failure. Qualifying a host for release still requires a green no-skip run per
`docs/RELEASE_POLICY.md`.

## 3. Feature matrix

Legend: **P** pass · **F+P** fixed then passing · **B** blocked · **N** documented non-goal.

### A. Build and test gates

| # | feature | result |
|---|---|---|
| A1 | `swift build` (debug), no warnings | P |
| A2 | `swift build -c release` | P |
| A3 | safe suite excludes `IntegrationTests` | P |
| A4 | `make verify-release` | P (554/0) |
| A5 | `make test-live-full` strict mode | **B** — BUG-9 / §2 |
| A6 | `make computer-use-check-full` strict mode | P (30/30) |
| A7 | `Tests/ReleaseSecurityTests.sh` | P |
| A8 | `Tests/LiveTestGateTests.sh` | P |
| A9 | `scripts/check-live-test-run.sh` skip/undercount gate | P — correctly failed the blocked runs in §2 rather than exiting 0 |
| A10 | `make viewer` | P |
| A11 | `git diff --check` | P |

### B. Release gates (non-mutating only; nothing published, notarized, uploaded, or signed for distribution)

| # | feature | result |
|---|---|---|
| B1 | `release check` | P |
| B2 | `release dry-run` | P |
| B3 | `release preflight` fail-closed without credentials | P |
| B4 | `verify-distribution` argument guard | P |
| B5 | `verify-release-candidate` argument guard | P |
| B6 | `check-swift-toolchain.sh` fail-closed pinning | P |
| B7 | `release package` / `candidate` / publication | **N** — requires external credentials; explicitly out of scope |

### C. CLI surface

| # | feature | result |
|---|---|---|
| C1 | no args prints usage, exit 0 | P |
| C2 | `--help` / `help` / `-h` | P |
| C3 | `version`, `--version`, `version --json` | P |
| C4 | `doctor`, `doctor --json` | P — includes daemon/CLI build-UUID comparison |
| C5 | `setup` flag surface | P (flag table + usage; guided run not executed — it rewrites MCP client config) |
| C6 | unknown command → error + usage, exit 1 | P |
| C7 | `daemon` lifecycle | P |
| C8 | `daemon stop --operator` | P — displays retired immediately, zero left |
| C9 | `pool`, `pool --json` | P |
| C10 | `pool set N --operator` | P — operator scope enforced (`LeaseAuthorizationTests` + live refusal) |
| C11 | `session create` + `--controller-*` + `--controller-ttl` | P |
| C12 | `session list`, redaction of other controllers' detail | P — verified live: `apps/windows redacted: another controller holds this session` |
| C13 | `session heartbeat --lease` | P |
| C14 | `session destroy` incl. `--all`, `--keep-apps`, `--operator` | P — incomplete teardown reported truthfully and succeeded on retry |
| C15 | `run <app>` | P |
| C15b | `run <app> <file>` | **F+P (diagnosis) / open (cause)** — BUG-9 |
| C16 | `adopt --pid` | P — including the exclusive-ownership refusal for a pid owned elsewhere |
| C17 | `windows` | P |
| C18 | `ax`, `--window`, clipping disclosure | P |
| C19 | `click --element N` / `wN` / `--x --y` | P |
| C20 | `click --button/--count/--modifiers` | P — coordinate click with no element reports UNCONFIRMED |
| C21 | `move` | P |
| C22 | `drag` incl. modifiers | P |
| C23 | `scroll --dy/--dx/--ticks`, sign convention | P — one convention, consistent across CLI, MCP schema and `ScrollDelta` |
| C24 | `select` (editor text) | P |
| C25 | `type`, `--web` | **F+P** — BUG-1, BUG-4 |
| C26 | `key`, `--web` | **F+P** — BUG-1 |
| C27 | `screenshot` window / `--full` / region / `--scale` | P — geometry and the coordinate-conversion formula disclosed on every capture |
| C28 | `verify` + `--json` isolation contract | P — `verdict`/`checks`/`coverage`/`failures`; `drift` omitted for partial |
| C29 | `repark` | P |
| C30 | `demo` | **B** — blocked by BUG-9 (its fixture opens a file) |
| C31 | `SPACEO_SOCKET` / `SESSIONS_PER_DISPLAY` / `DISPLAY_SIZE` | P |
| C32 | daemon log, `SPACEO_LOG_FILE/METRICS/DEBUG/RUN_ID` | **F+P** — BUG-3 |
| C33 | `scripts/metrics-report.mjs` | P |

### D. MCP surface — all 17 tools exercised

`spaceo_session_create`, `_list`, `_heartbeat`, `_destroy`, `spaceo_open_app`,
`spaceo_read_screen`, `spaceo_click`, `spaceo_scroll`, `spaceo_move`, `spaceo_drag`,
`spaceo_select_text`, `spaceo_type`, `spaceo_press_key`, `spaceo_screenshot`,
`spaceo_list_windows`, `spaceo_verify_isolation`, `spaceo_pool_status` — **all P**, each called
directly at least once against a live daemon.

| # | feature | result |
|---|---|---|
| D18 | negative validation | P — unknown session, unresolvable app, non-pressable element, out-of-range and incomplete arguments all rejected with actionable errors |
| D19 | lease fencing | P — read without lease and read with a wrong lease both refused; `session.list` redacted |
| D20 | protocol: initialize / ping / tools/list / unknown method | P — via `scripts/mcp-smoke.mjs` |

Notable honest-reporting behaviours confirmed live: stale AX index refused rather than guessed;
Electron horizontal scroll reported UNCONFIRMED with its reason; a non-editor Electron surface
refused by name; a self-activating Electron app reported that focus was handed back.

### E. Live behaviour

| # | feature | result |
|---|---|---|
| E1 | native AppKit matrix | P |
| E2 | Chromium web content via DevTools | P |
| E3 | Electron semantic adapter incl. `select_text` | P |
| E4 | coordinate / scale / origin contracts | P — window capture 1 px = 1 pt; tile and region captures state their global origin and the conversion formula; scale 2 verified |
| E5 | containment and late-window repark | P — a modal Save panel opened by the Viewer landed inside the tile |
| E6 | isolation reporting | P — `partial` verdict with per-check coverage; user-caused cursor and frontmost changes reported as notes, not violations |
| E7 | concurrent tiled sessions | P |
| E8 | teardown, display retirement, 15 s debounce | P — measured: three empty displays retired after the grace, the occupied one kept |
| E9 | physical topology preservation | P, including the inactive hardware-mirror follower contract in BUG-11 |
| E10 | stale-state traps | P — window-generation binding refused a stale element index |

### F. Viewer

| # | feature | result |
|---|---|---|
| F1 | build, bundle, Developer ID signing | P |
| F2 | branding / icon | P — `CFBundleIconFile` present, mark rendered in the sidebar |
| F3 | empty / offline states | P — daemon-offline path offers **Start Daemon**; verified by source and by the disconnected state |
| F4 | session / display / recovery / search UI | P — sessions, SpaceO displays, and physical displays (incl. `· inactive`) listed; search field present with correct placeholder and label |
| F5 | stream lifecycle, Retry, Refresh | P |
| F6 | session-vs-display scope | P — capture button and status bar both re-label (`Tile-scoped stream` ↔ `Whole display stream`) |
| F7 | screenshot messages | **F+P** — BUG-6 |
| F8 | overlay mapping | P — tile outlined and labelled with its session id, with a full accessibility description |
| F9 | zoom / pan | P — Zoom Out correctly disabled at 100 % |
| F10 | Control admission | P — offered only for a SpaceO display holding a session |
| F11 | pointer / keyboard forwarding | P |
| F12 | held-input release | P — covered by `HeldPointerReleaseTests` / `KeyEquivalentReleaseTests` and the Control-off path |
| F13 | local Control-Command-Escape | P — verified live: sending the chord exited Control and was not forwarded |
| F14 | physical / empty-display refusal | P — toggle disabled for a physical display; policy refuses with "Physical displays are view-only" |
| F15 | accessibility / VoiceOver labels | P — e.g. "Session claude-viewer. Status: Owned. Owner: … Last activity 24s ago · Age 52s." |
| F16 | final zero-session UI | P |

### G. Documentation versus behaviour

| # | claim | result |
|---|---|---|
| G1 | README Viewer Control on physical displays | **F+P** — BUG-7 |
| G2 | README / TICKETS counts and live-run status | **F+P** — BUG-8 |
| G3 | `docs/LIVE_TESTS.md`, `RELEASE_POLICY.md`, `SESSION_RECOVERY.md` | P |
| G4 | CLI help text | **F+P** — BUG-5 |
| G5 | CHANGELOG / VERSION | P — the dated `1.0.0` source notes match `VERSION`; no downloadable artifact publication is claimed |
| G6 | MCP tool descriptions | P |
| G7 | SPAO-148 (oversized windows across tiles) | **N** — tracked Open in `PRODUCT_BACKLOG.md`; not reproduced here and not in scope to fix |

## 4. Bug ledger

### BUG-1 — `type` and `key` deliver to the wrong window and report success — P1 — FIXED

*Affected:* `spaceo type`, `spaceo key`, `spaceo_type`, `spaceo_press_key` (per-pid delivery path).

*Expected:* text and keystrokes reach the window named by `--window` / `window`, or the command
fails.

*Actual:* they reach whichever window the application currently considers key, and the command
returns `ok`.

*Reproduction* (TextEdit, two documents adopted into one session):

```
$ spaceo type "MARKER-INTO-ALPHA " --session typeprobe --lease … --window 15506   # DOC-ALPHA
before  15505 DOC-BETA  : "BETA-ORIGINAL-CONTENT"
before  15506 DOC-ALPHA : "ALPHA-ORIGINAL-CONTENT"
after   15505 DOC-BETA  : "MARKER-INTO-ALPHA BETA-ORIGINAL-CONTENT"   <- the text went here
after   15506 DOC-ALPHA : "ALPHA-ORIGINAL-CONTENT"                    <- the window asked for
exit 0
```

TextEdit then autosaved, so `DOC-BETA.txt` **on disk** ended up containing
`MARKER-INTO-ALPHA BETA-ORIGINAL-CONTENT` while `DOC-ALPHA.txt` was untouched. This is data
written into a file the caller never named.

*Root cause:* `CGEventPostToPid` addresses a process; the process routes to its own key window.
`InputRouter.prepareForInput` was the step meant to make the requested window key, and it
`return`s immediately — doing nothing — when `SPOCapabilityAvailable(.focusWithoutRaise)` is
false. That is every host where the private focus path is absent, which `spaceo doctor` reports
plainly as `MISS focus-without-raise`.

*Fix:* a shared pre-send gate for both surfaces. `AXTree.focusWindow` first asks the application
to make the window key through **public** Accessibility (`AXMain`/`AXFocused`, which does not
activate or raise the app), then `InputRouter.keystrokeTargeting` decides on the re-read:

- application focuses the requested window → deliver;
- application focuses a different window → **refuse before sending**, naming both windows;
- application will not say, and it owns exactly one window → deliver with an explicit
  unverified-delivery warning (there is nowhere else to misroute to);
- application will not say, and it owns any other number of windows → **refuse**.

*Verification:* the same reproduction on the fixed build put `FIXED-MARKER ` into DOC-ALPHA and
left DOC-BETA untouched; re-targeting typed into DOC-BETA and left DOC-ALPHA untouched;
`key cmd+a` + `key delete` aimed at DOC-ALPHA cleared DOC-ALPHA only. `make computer-use-check-full`
still passes 30/30, so the gate does not ground native, web, or Electron typing.

*Regression:* `KeystrokeTargetingTests` — 7 tests over every branch, including `key`, the
unknown-focus single-window allowance, and the unknown-focus zero- and multi-window refusals.

### BUG-2 — a blank accessibility read erases a live session's windows — P2 — FIXED

*Expected:* an empty `kAXWindowsAttribute` answer for a live app is a failed read.

*Actual:* `AgentSession.refreshWindows()` assigned it straight over `windows`, so the session
reported itself clean, empty and healthy while the app's windows were still on screen.

*Reproduction (observed):* a live TextEdit owned by session `claude-audit-1` reported
`no windows yet` from `spaceo_list_windows`, `no covered audit failures` from `verify`, and
`re-parked 0 window(s)` from `repark`, while `CGWindowListCopyWindowInfo` listed both of its
document windows — at that moment sitting on the user's physical display. Every consumer is
derived from that one list: `audit()`, `reparkEscapedWindows()`, `windows`, `ax`, and teardown's
evacuation of windows that outlive the session.

`captureWindowIdentities()` already refused to forget on this answer, for capture privacy; the
rest of the session believed it. The asymmetry was unintended.

*Fix:* merge enumerated windows with cached windows the WindowServer still has for the live app,
using **its** current geometry so containment stays checkable. This covers both a completely blank
AX read and a partial read that omits one live window. Ownership is re-checked because a
`CGWindowID` is recycled exactly like a `pid_t`; an id owned by another process or with unknown
ownership is dropped. Enumerated data wins by id, so merging cannot duplicate or overwrite it.

*Regression:* `AccessibilityBlackoutWindowTests` — 8 tests: complete-blackout retention, dropping
a genuinely closed window, repark and teardown evacuation, recycled and unnameable owners,
partial-enumeration retention/repark, and no duplicate when cached and enumerated ids overlap.
The partial-enumeration test was red-confirmed against the earlier empty-only guard.

### BUG-3 — reaping an owned app left no trace — P2 — FIXED

*Expected:* README documents the daemon log as carrying "every failed request, janitor
reclamation, and lifecycle event".

*Actual:* reclaiming a whole abandoned session logged `janitor.reclaimed`; reaping the apps
*inside* a live session logged nothing. A session went from "1 app, 1 window" to empty with no
record anywhere.

*Fix:* emit `janitor.reaped` with the session id, the count, and the names of the apps removed.
Bounded by `DaemonLog.event`; a pass that reaps nothing stays silent.

*Regression:* `JanitorReapObservabilityTests` — 2 tests, cleanup awaited via `addTeardownBlock`.

### BUG-4 — `type` confirmed itself with another window's text — P3 — FIXED

`response.value = AXTree.focusedValue(pid:)` is app-wide. `AXTree`'s own documentation says to
prefer the window-scoped read, and the live suite already did. Fixed to read the focused element
only when the application agrees that window has focus, falling back to a window-scoped read.
The ambiguous app-wide reader was removed so nothing can reach for it again.
*Regression:* `TypeReadBackAttributionTests`.

### BUG-5 — CLI usage advertised an argument that does not exist — P3 — FIXED

`spaceo select <id> …` documented a positional id that `case "select"` never reads and
`validateFlags` silently discards, and the insertion orphaned `scroll`'s `--dy`/`--dx`
explanation underneath `select`, which accepts neither flag. Introduced at HEAD.
*Regression:* `UsageTextContractTests` — every long flag printed in a command's usage block must
be a flag that command accepts, plus a positional check for `select`. Both fail on the old text.

### BUG-6 — a whole-display capture was saved under a session name — P3 — FIXED

`setCanvasMode(.display)` deliberately keeps `selectedSessionID`; the save panel keyed its
suggested name off that alone, so **Capture Display** wrote an image of every tile on the display
as `spaceo-session-<id>.png`. Named from `canvasMode` now, like the toolbar label and the stream
target. *Regression:* `ViewerScreenshotNamingTests`.

### BUG-7 — README claimed Control works on physical displays — P3 — FIXED (docs)

README: "Control is available for both SpaceO virtual displays and physical displays; display
provenance is not an input allowlist." The shipped policy is the opposite and deliberately so —
`ViewerControlPolicy.controlRequest` refuses with "Physical displays are view-only; select a
SpaceO display", and the toolbar toggle is disabled, which this audit confirmed live. README
rewritten to describe watch-versus-control accurately; SPAO-105 annotated as superseded in part
rather than rewritten.

### BUG-8 — stale counts and a superseded live-run status — P3 — FIXED (docs)

`TICKETS.md` claimed 308 deterministic tests (actual 529 at HEAD), a 16-tool MCP smoke (actual
17), a 25-step computer-use matrix (actual 30), and "the latest complete live run passed 15/16 …
that remaining live gate is SPAO-148" — superseded by the retained 2026-08-03 16/16 record.
README carried the same 25-step claim. Rewritten so the numbers live in the gates and the dated
records rather than in prose that rots.

### BUG-9 — `launch failed: … produced no window` while the WindowServer has the window — P2 — OPEN, diagnosis improved

*Expected:* `spaceo run <app> <file>` places the app's document window in the tile.

*Actual, intermittently:*

```
$ spaceo run TextEdit /private/tmp/spaceo-diag-probe.txt --session … --lease …
error: launch failed: pid 17209 produced no window within 15s
```

while, sampled every 2 s for the whole 15 s wait:

```
win 15986 pid 17209 layer 0 onscreen false 656x422 at (213,77) "spaceo-diag-probe.txt"
```

`spaceo run <app>` **with no file** succeeded throughout. `spaceo demo` (whose fixture opens a
scratch file) failed for both TextEdit and Calculator.

*Not a regression from this audit — control run:* the untouched HEAD binary
`~/.local/bin/spaceo` (SHA-256 `7982c315…`, byte-identical to the artifact under audit) fails
identically:

```
$ node scripts/computer-use-check.mjs ~/.local/bin/spaceo --suite=native
FAIL  [native] launch TextEdit onto the agent display
FAIL  harness error: native launch failed: launch failed: pid 14858 produced no window within 15s
```

Ruled out: a stale TCC grant from rebuilding an unsigned binary — the **Developer ID signed**
Viewer helper daemon fails the same way. Not root-caused further. The condition is intermittent:
the same host passed `computer-use-check-full` 30/30 both before and after the affected window.

*Partial fix shipped:* the failure now says which failure it is. `WindowPlacement` appends the
windows the WindowServer can see, so "the app drew nothing" is no longer printed for what is
actually a failed accessibility read:

```
launch failed: pid 17682 produced no window within 15s; but the WindowServer lists 2 window(s)
for it (16060, 16061), so this is an accessibility read failure rather than an app that drew
nothing — check that Accessibility is granted to the process hosting the SpaceO daemon
(`spaceo doctor`), and that the app is not still starting up
```

*Not fixed:* the underlying read failure. Making the launch wait fall back to the WindowServer
would be wrong without more evidence — SpaceO needs AX *elements* to place windows, so seeing
them in `CGWindowList` does not mean it can move them. This needs a product decision and belongs
in a ticket, not in an audit patch.

### BUG-10 — the Viewer process was replaced twice — OPEN, not reproduced

While the Viewer streamed the mirrored external display, its process was replaced twice
(73366 → 85666 at 17:44:46, → 90481 at 17:50:15, both `ppid 1`) with **no crash report** in
`~/Library/Logs/DiagnosticReports` (including `Retired/`). The replacement instance was not owned
by the session and opened on the user's physical display. Quitting it did not produce a relaunch,
so it is not a supervised restart loop. Rebuilding the package does not reproduce it.

Recorded as an observation with a timeline, deliberately **not** root-caused. BUG-3's new
`janitor.reaped` record means a recurrence will now leave a trace naming the app that vanished,
which is what made this one impossible to reason about after the fact.

### BUG-11 — live test contradicted the display-safety contract for an inactive mirror follower — P3 — FIXED

*Expected:* the Stage lifecycle live test should fail when a SpaceO display changes a user-visible
display setting and accept the one synthetic mode transition production teardown deliberately
defines as invisible: an inactive hardware-mirror follower whose active master is unchanged.

*Actual:* `testStageCreateAndDestroyLeavesNoDisplay` used raw snapshot equality. On the mirrored
host it failed while the virtual display was attached because macOS republished the inactive
built-in follower at a different synthetic mode, even though `Stage.UserDisplayConfiguration`
and the test's own teardown use `changes(from:)` to ignore exactly that case.

*Fix:* both attach and retire assertions now use `changes(from:).isEmpty`, preserving the
fail-closed contract while aligning the test with production semantics. The targeted live test
passes with the external panel awake and hardware mirroring enabled.

## 5. Changed paths

Fixes and their regression tests from this audit:

```
Sources/SpaceOKit/AXSupport.swift        setBool
Sources/SpaceOKit/AXTree.swift           focusedWindowID, focusWindow, window-scoped read-back
Sources/SpaceOKit/AgentSession.swift     window retention + owner re-check; liveOwnerPID driver
Sources/SpaceOKit/InputRouter.swift      keystrokeTargeting (the shared pre-send decision)
Sources/SpaceOKit/SessionManager.swift   requireKeystrokeTarget for type and key; janitor.reaped
Sources/SpaceOKit/WindowPlacement.swift  liveOwnerPID; windowServerDisagreement diagnosis
Sources/SpaceOViewer/ViewerModel.swift   screenshotFileName
Sources/spaceo/main.swift                usage text
README.md                                Viewer Control wording; matrix-count wording
TICKETS.md                               stale counts; SPAO-105 superseded-in-part note

Tests/SpaceOKitTests/AccessibilityBlackoutWindowTests.swift   (8)
Tests/SpaceOKitTests/IntegrationTests.swift                   mirror-follower safety contract
Tests/SpaceOKitTests/JanitorReapObservabilityTests.swift      (2)
Tests/SpaceOKitTests/KeystrokeTargetingTests.swift            (7)
Tests/SpaceOKitTests/TypeReadBackAttributionTests.swift       (2)
Tests/SpaceOKitTests/UsageTextContractTests.swift             (2)
Tests/SpaceOKitTests/ViewerScreenshotNamingTests.swift        (4)
```

Every one of those tests was confirmed to fail against the pre-fix code before being accepted,
except the two complement guards that are expected to pass either way and exist to stop the fix
from over-reaching (`testAWindowTheWindowServerHasForgottenIsStillDropped`,
`testAJanitorPassThatReapsNothingWritesNothing`).

Safe-suite count: **529 → 554**.

## 6. Cleanup evidence

```
$ spaceo pool --operator
0 display(s), 0 session(s), 1 per display
  usage: sessions 0, displays 0, pixels 0, new displays this minute 0
no agent displays

$ spaceo doctor
  daemon matches CLI : yes
  SpaceO displays    : none
  user displays      : online 2, 1; active 2
  display mirroring  : on (display ids 2, 1)
```

No owned sessions, no SpaceO displays after the debounce, no orphaned displays. Every application
launched or adopted by this audit was quit or released; adopted applications were released without
termination, and the one teardown that reported incomplete succeeded on the retry it promised.
Chrome and Cursor temporary profiles were removed by their own launches' cleanup. Audit logs and
reproduction fixtures under `.artifacts/claude-2026-08-29/` and `/private/tmp` were working
evidence, not release inputs; their durable findings and commands are recorded here. The two probe
documents were confirmed unmodified on disk except where BUG-1 itself wrote to one — recorded
above as evidence. After evidence collection, the audit-launched Viewer and its daemon were
stopped; an exact-path process check found neither still running.

Physical display topology is the mirrored configuration it started in.

## 7. Pre-existing working-tree changes, preserved

This audit did not revert, stash, reformat, or commit any of the in-flight work it found:
`README.md` (branding header), `Sources/SpaceOViewer/ContentView.swift`,
`scripts/make-viewer-app.sh`, `Assets/Brand/*`, `Sources/SpaceOViewer/SpaceOBrandMark.swift`,
`Today.md`, `scripts/build-brand-assets.sh`. `README.md` was edited concurrently by its owner
during the audit; the two documentation corrections here were re-applied on top of that owner's
version rather than over it. Nothing was staged, committed, pushed, branched, or cleaned.

## 8. Verdict

The product's core claims hold up. Isolation reporting, capture geometry, lease fencing,
containment, teardown truthfulness, the Electron and Chromium boundaries, and the Viewer's control
admission all behave as documented, and several of them refuse honestly in exactly the places a
weaker implementation would have guessed.

One P1 defect was found and fixed: `type` and `key` silently delivered to the wrong window of a
multi-window application and reported success, with a measured write to the wrong file on disk.
Two P2 defects were fixed (a blank accessibility read erasing a live session's windows; app
reaping leaving no trace) and six P3 defects, including CLI/UI contract errors, stale
documentation, and the live test's inactive-mirror comparison.

Two issues remain open and are **not** cleared by this run: BUG-9's intermittent launch failure,
reproduced on the untouched HEAD artifact, and BUG-10's unexplained Viewer process replacement.
`make test-live-full` is BLOCKED on this host by BUG-9's Accessibility blackout, as recorded in §2.

**This is not a release qualification.** `docs/RELEASE_POLICY.md` requires a green, no-skip live
run as approval evidence, and this host did not produce one.
