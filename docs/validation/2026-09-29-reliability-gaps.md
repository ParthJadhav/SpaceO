# Reliability gap audit — September 29, 2026

Scope: review current backlog and source boundaries, fix reproducible reliability defects,
and run deterministic checks without creating displays or interacting with desktop applications.
The user subsequently confirmed that this Mac is reserved and idle for supervised live testing.
No installation, signing identity change, or release publication is included.

## Findings implemented

| Gap | Result | Deterministic evidence |
| --- | --- | --- |
| Setup enforced configuration size only after loading the entire file; a FIFO could block its read | Read an opened, nonblocking regular-file descriptor with a limit enforced both before and during reading | `BoundedRegularFileTests`: empty/exact/multi-chunk reads, oversize refusal, FIFO/directory refusal, symlink and UTF-8 cases |
| Doctor and setup-progress reads checked a path's size and then reopened it for an unbounded read | Use the same descriptor-bound reader; advisory reads still degrade to unknown/default state | `BoundedRegularFileTests`, existing inspection and setup tests |
| Missing files and dangling configuration links could both look absent | Only a missing path becomes an empty configuration; dangling links remain errors | `testMissingAndDanglingSymlinksRemainDistinct` |
| A valid JSON object with a malformed `mcpServers` field silently lost that field on merge | Refuse non-object server collections before generating rewritten configuration | `testJSONRefusesToDiscardMalformedServerCollections` |
| Three busy Accessibility IPC attempts were charged as one call and reused one timeout | Each attempt uses the shared call budget, remaining deadline, and cancellation checks; retry pauses are bounded by the remainder | Three provider retry tests in `AXTraversalTests` |
| A window appearing or disappearing during enumeration could leave a full-sized stale prefix | Recheck the window count before publishing windows or retained handles; count failures and changes refuse the result | Growth, shrinkage, and unavailable-final-count tests in `AXTraversalTests` |
| Legacy daemon restart renewed its shutdown budget and could send stop after expiry; request and sleep timeouts exceeded the remainder | Use a monotonic production clock and one deadline through drain, polls, stop, and exit wait; refuse invalid API limits | Four added deadline/validation cases in `DaemonRestartTests` |

Configuration content and window data are never included in this report. Config files may still
use symlinks to regular files. The bounded reader checks the opened descriptor and never appends
bytes beyond the caller's limit, including when the file grows after its size was checked.

The window-count check detects cardinality changes, not an atomic OS snapshot. Same-count
replacement can still race discovery. Missing/repeated identities and uncertain capture/placement
evidence continue to be refused; no retries of user input or relaxation of identity checks were added.

## Verification

- Initial `make verify-release`: passed, including 1,628 deterministic Swift tests and the
  34-tool MCP smoke check.
- Targeted configuration/discovery tests: 82 passed before the retry changes.
- Targeted discovery/readiness tests after retry changes: 60 passed.
- Restart tests: 11 passed.
- Final `make verify-release`: passed, including 1,643 deterministic Swift tests, the supporting
  Python/shell/JavaScript checks, and the 34-tool MCP smoke check. `git diff --check` passed.

## Live diagnostic admission

The user confirmed the current Mac is reserved and idle. Read-only preflight found zero sessions,
zero SpaceO/orphan displays, one active physical display, ready display safety, and drive/capture
permissions for the source CLI. The existing idle daemon runs a different build.

This host has Xcode 27.0 and Swift 6.4; the release-pinned Xcode 26.3 is absent. Any live run here
is a source diagnostic, not pinned-toolchain or signed-candidate release qualification. The
supervised wrapper, opt-in, pacing, first-failure stop, and private evidence retention still apply.
The following diagnostics ran against source checkpoint `84f153f`.

## Live diagnostic results

- `SPACEO_LIVE_TESTS=1 make test-live-full`: **16 passed, zero skipped, zero failed** under
  the external supervisor. The mandated 90-second case pacing remained enabled.
- Full MCP matrix (`--suite=all --require-full`): **36 passed, zero failed, blocked, or skipped**;
  44 tool calls in 74.86 seconds. A separate source daemon matched the tested CLI binary.
  Native and Chromium actions passed; Electron's check proves pre-launch refusal, not support.
- Supervised daemon-only performance workload: **1,269 operations and 400 captures passed**
  in 314.72 seconds. It exercised 1/4/8-client reads, subscriber admission, four logical
  sessions, 30 logical session create/destroy cycles, 40 scale-check captures, and 360 soak captures.
- The live suite, matrix, and soak each completed cleanup. Postflight matched the initial physical
  display topology, with no SpaceO/orphan display and ready display-safety state.
- Resource-counter calibration passed. The soak retained 235 capture-phase process samples,
  with no sampler errors.

| Observation | This run |
| --- | ---: |
| Screenshot median / p95 / p99 | 133.96 / 271.41 / 320.39 ms |
| Ping median / p95 under workload | 0.46 / 0.99 ms |
| Capture-phase daemon CPU | 1.88% of one core |
| Capture-phase sampled footprint start / end / peak | 31.86 / 22.03 / 31.89 MiB |
| Post-teardown sampled footprint | 21.02 MiB |

These observations describe this bounded workload; they do not establish a general absence of
leaks, a performance improvement over another build, or Viewer/GPU behavior. This daemon-only
soak used the static Chromium fixture. Animated/scrolling Viewer scenarios were not exercised.
The earlier intermittent Chromium identity fault did not reproduce here and remains open.

Private evidence is retained under
`.artifacts/source-live-84f153f2-20260929T091252Z/`, including admission, supervisor logs,
the content-free MCP report, performance samples/summary, and postflight. Raw logs, screenshots,
Accessibility content, and controller leases are not committed.

The original idle default daemon was stopped for the diagnostics and restarted from its original
executable path afterward. That path now contains the tested 1.0.3 source build, replacing the
previously running 1.0.1 process. The restarted daemon matches the source CLI and retains drive
and capture permissions. No host installation or release publication was performed.

## Remaining qualification and product gaps

- Chromium's intermittent missing/repeated AX window identity remains undiagnosed. These changes
  correct separate enumeration and budget defects; they do not prove that the September 28 soak
  failure is fixed. A supervised live soak must retain capture and teardown evidence.
- Managed Electron applications remain outside the supported launch scope because they can
  activate themselves. Supporting them needs a proven attention-isolation mechanism.
- Viewer-on-SpaceO remains unsupported due to unresolved stream staleness. Physical-display
  Viewer input/stream evidence must be retained for the actual release candidate.
- Native background input routes and private macOS APIs require host/build-specific live
  qualification. Passing deterministic tests cannot establish universal application compatibility.
- Release qualification still needs the pinned toolchain and exact signed candidate evidence
  under `docs/LIVE_TESTS.md`. The source diagnostics above and existing owner release GO records
  do not qualify a new signed release.

The older product backlog contains stale per-ticket “Open” labels for work its later status
sections report implemented. This audit uses current source and newer validation records;
historical descriptions alone are not evidence of missing features.

## Follow-up source hardening

The next review found further startup, identity, and configuration defects:

1. The private window-ID wrapper discarded all AX error codes. A busy provider and a stale
   element were both reported as zero. The compatibility wrapper still returns zero, while
   discovery now uses a status-preserving wrapper. Only `cannotComplete` retries, using the
   shared deadline/call budget from the first pass. No unresolved or duplicate ID is accepted.
   This enables a later identity failure to retain its actual AX error without retaining window
   content. It does not establish the cause of the earlier soak failure.
2. Daemon startup used a blocking `flock`. A competing starter suspended while holding that
   lock could hang another startup indefinitely. Nonblocking acquisition now has a three-second
   monotonic deadline and returns a retryable busy error without changing the existing socket.
   FIFO/directory lock paths are refused without replacing them. Concurrent starts on one server
   are refused, and shutdown cancels a pending start before it publishes a stranded socket.
3. The Codex registration writer treated any header-looking line as a table, including text
   inside multiline instructions, and mistook nested array rows for subsequent tables. A
   bounded lexical scanner now recognizes string/array context and bare/quoted table keys,
   preserves unrelated bytes, and refuses unfinished/duplicate/ambiguous registration forms.
   It follows the [TOML 1.0 string/key/table rules](https://toml.io/en/v1.0.0), but is intentionally
   a boundary scanner rather than a complete TOML validator. Inline/dotted registrations that
   cannot be safely rewritten receive an explicit error instead of duplicate table output.
4. Doctor's command extraction could read a fake `command = ...` from multiline example text.
   It now uses only top-level assignments within the registration table.

5. Doctor waited for a version process to exit before a blocking stdout read. A descendant
   retaining the pipe could bypass its timeout. Nonblocking reads now share one monotonic
   deadline with process completion, drain output during execution, and reject output over
   4 KiB. Nonfinite or nonpositive timeouts are refused before launching.

Targeted evidence: 78 identity/discovery/readiness tests, six startup-lock tests (including
stop during startup), 40 TOML/configuration/inspection tests, and 17 inspection tests including
new inherited-pipe and excessive-output cases passed. Follow-up `make verify-release` passed:
1,665 deterministic Swift tests, supporting Python/shell/JavaScript checks, and the 34-tool
MCP smoke check. `git diff --check` passed.

### Follow-up live diagnostics (`688e4f1`)

- Supervised native workflow: one passing case, no skips/failures, 92.94 seconds including
  mandatory pacing. Input readback, covered isolation checks, and teardown passed.
- Full MCP matrix: 36 passed, zero failed/blocked/skipped, 44 calls in 75.76 seconds.
  The matrix CLI SHA-256 still matched the built CLI after Viewer packaging.
- Ad-hoc Viewer bundle: strict/deep signature verification passed.
- Focused Chromium/physical-Viewer animation diagnostic: **failed**, 93.59 seconds including
  cleanup. The animated phase produced identical in-memory capture digests; Viewer reported
  zero FPS with a running stream, a frame sink, and an unoccluded physical-display window.
  Its last-frame age reached 25.79 seconds. Chrome reported visible document state, but
  animation callbacks advanced only from 4 to 26 across 23 heartbeat samples; the preceding
  static phase advanced from 61 to 1,201 across 20 samples. Scrolling was not reached.
- All three runs restored the original physical topology with no SpaceO/orphan displays and
  ready safety. The failed Viewer run was inspected and is not passing qualification evidence.

Private evidence: `.artifacts/source-live-688e4f1c-20260929T101220Z/`. These remain source
diagnostics on the unpinned toolchain. The intermittent AX identity fault did not reproduce;
the animation failure is a separate unresolved problem. No release was published.


### Inspected occlusion hypothesis

After inspecting the failed run and verifying physical-only cleanup, a distinct source experiment
added `--disable-backgrounding-occluded-windows` only to SpaceO's private Chromium launch.
Chromium's [switch definition](https://raw.githubusercontent.com/chromium/chromium/main/content/public/common/content_switches.cc)
and [visibility implementation](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/web_contents/web_contents_impl.cc)
identify it as a test override for occluded visibility. This was a hypothesis, not a supported fix.
The experiment's base commit and exact patch digest are retained privately.

The experiment also failed: identical animated capture digests, no sustained Viewer frames,
and no scrolling coverage. Cleanup restored physical-only topology and ready safety in 95.49
seconds. **The production flag was removed.** No Chrome rendering-policy change is retained,
and neither failed animation diagnostic closes the original identity issue or qualifies a release.
The failed experiment is retained under `occlusion-experiment/` within the same private evidence
directory; it must not be retried as if it were passing validation.

One harness defect was independently corrected: animated/scrolling capture digests were recorded
but identical images did not themselves fail the test. These workloads now require changing
capture pixels in addition to sustained Viewer delivery. The experiment exercised that new
failure path. Five fixture tests and six report tests passed.


Final verification after removing the experimental flag and retaining the harness assertion:
`make verify-release` passed again (1,665 Swift tests, supporting checks, 34-tool MCP smoke),
`git diff --check` passed, and the rebuilt ad-hoc Viewer passed strict/deep signature verification.
The final CLI SHA-256 equals the binary used by the passing 36-check matrix. The default daemon
was restored from its original source path and matches that binary, with drive/capture grants,
zero sessions, ready display safety, and unchanged physical-only topology. No installation,
release publication, or security-setting change occurred. The overall hardening goal remains
active; the open animation, intermittent identity, Electron, and release-qualification gaps are
not represented as complete.


## Focused motion diagnosis

The animation-first harness prevented any scrolling evidence after an animated-phase failure.
The harness now accepts a validated `SPACEO_PERF_VIEWER_MOTION` selection (`both`, `animated`, or
`scrolling`), always retaining the static baseline. Selection is refused for incompatible
native/daemon-only workloads before live admission. Provenance, raw summary, and derived summary
carry requested Viewer modes; older evidence reports unknown coverage rather than assuming full
coverage. Seven fixture and seven report tests pass, including selection refusal and preservation
of focused coverage. This is diagnostic coverage, not a workaround for frozen pixels.

Verification: `make verify-release` passed (1,665 Swift tests and 34-tool MCP smoke). The
seven fixture and seven report tests passed after the summary-coverage addition, and
`git diff --check` passed.

### Scrolling results

On source `729ded4`, the supervised static-and-scrolling run failed in 94.28 seconds including
cleanup. The scrolling capture pair was identical; Viewer delivered no sustained motion frames.
Chrome again reported 23 motion heartbeat samples with callbacks advancing from 4 to 26.
The requested `[static, scrolling]` coverage survived the derived summary unchanged. Animation
was intentionally excluded and is not covered by this diagnostic.

After inspection and verified physical-only cleanup, a separate retained diagnostic script loaded
scrolling as the first page, deliberately omitting the static baseline. It failed in 74.02 seconds
with the same identical-capture result and 23 heartbeat samples advancing from 4 to 26. This is
not a standard full-workload result; its exact script and digest are retained privately. It rules
out a second navigation as a sufficient explanation, but does not establish the platform cause.
No production behavior was changed in either diagnostic.

Both runs restored topology and ready safety. The default daemon was restored, matches the CLI,
and has zero sessions with working drive/capture grants. Private evidence is retained at
`.artifacts/scroll-diagnostic-729ded43-20260929T103022Z/`. No automatic retry or release
qualification claim follows these failed results. The next useful boundary to investigate is
Chromium-produced frames versus WindowServer/ScreenCaptureKit-delivered pixels, rather than
adding more unproven launch flags.


## Chromium versus native pixel boundary

Using the unchanged production build at `faebb12`, a bounded diagnostic connected only to the
private Chrome process recorded in the generated session. It validated the owned temporary
profile, read its bounded DevTools endpoint marker, and selected the page by exact fixture URL
and title. Images stayed in memory; only change booleans and numeric fixture counters were kept.

The initial probe was inconclusive because its failure report omitted the command stage. It
also used a screenshot clip. Chromium's [Page handler implementation](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/devtools/protocol/page_handler.cc)
shows that clipped screenshots can temporarily resize the view and screenshot requests actively
ask the page to produce frames. Such a request is therefore not a passive observation of the
normal renderer. After inspecting the first attempt and verifying cleanup, the corrected probe
removed clipping and recorded command completion/stage separately.

In the corrected run, `Runtime.evaluate` completed and read the generated scrolling fixture:
visible document state, 27 animation callbacks, scroll offset 216, viewport 1280 × 633.
`Page.captureScreenshot` then **did not answer within its four-second command deadline**. No CDP
image comparison was possible. Native capture pairs before and after the probe remained
identical, including across the probe. This is not proof that a longer CDP deadline cannot
succeed, nor does it establish a Chromium or macOS root cause. It does show the diagnostic reached
the intended live renderer and the observed symptom is not confined to Viewer frame delivery.

Both attempts failed and cleaned up normally (102.97 and 100.95 seconds, including cleanup).
Physical topology was restored with zero virtual/orphan displays and ready safety. The matching
default daemon was restored with zero sessions and working input/capture grants. No production
change or renderer workaround was retained. Private scripts, digests, command-stage results,
and postflight are retained under `.artifacts/pixel-boundary-faebb121-20260929T103809Z/`.


## Executable fingerprint read bound

A separate diagnostic review found `RuntimeIdentity.currentExecutableSHA256` opened arbitrary
paths with `FileHandle` and read until EOF despite its bounded-I/O documentation. A pipe could
block at open/read and a growing or oversized file had no byte ceiling. Fingerprinting now uses
the existing opened-descriptor regular-file reader with a 64 MiB limit. Failures return unknown
identity; no prefix digest is accepted. Regular-file symlinks remain supported, and replacing
the target's content is observed on the next call rather than cached.

Five targeted tests passed: three new file-boundary tests (known full digests and replacement,
oversized sparse-file refusal, and pipe/directory/missing/non-file refusal) plus both existing
current-executable fingerprint checks. The shared reader's existing growth checks still apply.
Final `make verify-release` passed with 1,668 Swift tests, supporting checks, and the 34-tool
MCP smoke check. The rebuilt ad-hoc Viewer passed strict/deep signature verification, and
`git diff --check` passed. The new fingerprint bound needs no desktop mutation to test.

The idle default daemon was then restarted on verified source `3e8c809`. Doctor confirmed a
matching executable, drive/capture grants, ready safety, zero sessions, and unchanged physical-only
topology. The private `fingerprint-postflight.json` retains this final state. This startup check
does not extend the earlier live matrix results to a new release candidate.


## Passive doctor client inspection

The default read-only doctor inspection executed every resolved MCP command with a `version`
argument, even for unrelated executables and wrappers. Argument validation happened afterward.
A malformed registration could therefore cause side effects merely by inspecting host health.
The new default reports external command versions as unprobed/unknown without invoking them.
The running CLI's known version remains available without execution. An explicit
`doctor --probe-client-versions` option preserves bounded executable probing when the operator
intends to run those registrations. The injected-provider library API retains its existing
probing default for callers that explicitly supply a provider; doctor selects passive policy.

CLI flag classification, allowed flags, help, generated completion/schema inputs, and setup
instructions are aligned. Thirty-five focused inspection, scripting, and help/spec tests passed.
The scripting regression uses a harmless fixture executable that creates its own marker: the
marker stays absent for default doctor and appears for explicit probing, which still reports the
fixture's stale version. The existing doctor test was adapted rather than adding live desktop
coverage. Final `make verify-release` passed with 1,670 Swift tests, supporting checks, and
the 34-tool MCP smoke test. The built CLI help and machine-readable schema include the option,
and the rebuilt ad-hoc Viewer passed strict/deep signature verification. `git diff --check`
passed. This change does not resolve the motion-rendering gap.

The idle default daemon was restarted on verified source `9f0713c`. Doctor confirmed the
matching executable, drive/capture grants, ready safety, zero sessions, and unchanged
physical-only topology. Private passive-doctor postflight evidence retains the result.
No applications or virtual displays were created for this restoration.


## Screencast diagnostic blocked at Chrome window identity

A separate bounded diagnostic on source `ed40aaa` was designed to start an eight-second CDP
screencast against only the generated scrolling fixture and compare native captures before,
during, and afterward. It selected the exact private Chrome endpoint and fixture URL/title,
acknowledged incoming frames, retained only frame counts/digest comparisons, and did not activate
or focus the application. The helper and its caller were syntax-checked and retained with hashes
in the owner-only `.artifacts/screencast-boundary-ed40aaa/` directory. Production code was unchanged.

The supervised run failed before executing that probe. Chrome's `run` command returned
`operation_failed` after 33.813 seconds; the bounded readiness path reported incomplete window
discovery because window identity was unavailable with AX error `-25201`. Viewer creation and
fixture navigation had not occurred. This is evidence of a launch/readiness identity failure,
not evidence for or against screencasting as a rendering diagnostic. It does not establish that
the September 28 soak failure has the same cause. Inspection confirmed that readiness already
re-polls provider failures within its existing deadline, so adding an unbounded retry or accepting
unidentified windows is not justified.

The attempt ended after 76.428 seconds with no sampler errors, verified session/display cleanup,
and restored physical topology. No automatic retry followed. The default matching daemon was
restored and doctor confirmed drive/capture grants, ready safety, and zero sessions; the private
postflight retains these checks. This is source diagnostic evidence on the current toolchain,
not release qualification. Both Chromium motion and intermittent identity findings remain open.

After recording the diagnostic, `make verify-release` passed again: 1,670 Swift tests,
supporting checks, and the 34-tool MCP smoke check. `git diff --check` passed. A final doctor
check still reported a matching daemon, ready safety, and no SpaceO or orphaned displays.


## Instrumented launch and completed screencast comparison

Source `5d4a0e7` was tested with a separate read-only launch observer and the previously prepared
screencast diagnostic. The observer selected only a Chrome PID whose command line contained the
private profile prefix for this diagnostic daemon, then checked process launch identity. Its
public-API observations contained only hidden/active flags, ownership/role counts, and status
codes; no titles or AX content were retained. The helper used bounded window pages and AX
messaging timeouts and was stopped after launch completion. Source, binary, and harness hashes
are retained in owner-only `.artifacts/observed-screencast-5d4a0e7/`.

Chrome launched successfully this time. The observer's one retained startup sample reported
inactive, not hidden, no native windows yet, and AX count error `-25204`. That early sample does
not explain the previous `-25201` failure or establish persistent app visibility after launch.
No window-identity fallback or retry-policy change was made.

On the scrolling fixture, `Runtime.evaluate`, `Page.startScreencast`, a second evaluation, and
`Page.stopScreencast` all completed. The eight-second screencast interval emitted **zero frames**.
The fixture remained `visible`; its requestAnimationFrame counter advanced from 26 to 34 and
scrollY from 208 to 272. Native capture pairs were identical before, during, and after the probe,
and did not change across it. Thus a successfully requested screencast did not restore frame
production in this run. This does not identify the root cause or prove the browser never renders.
The full attempt failed its original capture assertion after 105.676 seconds, with no sampler
errors and verified cleanup/topology. The matching default daemon was restored with ready safety,
drive/capture grants, and zero sessions.

## Isolated Chrome timer-source experiment

The installed Chrome is `154.0.8037.58`. Its matching upstream
[frame-source implementation](https://raw.githubusercontent.com/chromium/chromium/154.0.8037.58/components/viz/service/frame_sinks/external_begin_frame_source_mac.cc)
provides the debugging feature `ForceMacVSyncTimerForDebugging`, which selects its timer path
instead of the display-link object. This supplied a specific frame-scheduling hypothesis after
the screencast result; it was not treated as an established fix.

A temporary one-line AppLauncher patch added only
`--enable-features=ForceMacVSyncTimerForDebugging` to the managed private Chrome launch. The exact
patch hash, optimized executable hash, admission, and ad-hoc Viewer signature verification were
retained in `.artifacts/timer-diagnostic-5d4a0e7/`. The ordinary supervised Viewer-only workload
requested static, animated, and scrolling coverage. Chrome launch and the static phase succeeded,
but animation capture pixels were identical and sustained Viewer FPS stayed zero. The harness
stopped before scrolling. Feature internals were not traced, so the negative result does not
exclude every display-link failure; it shows that this launch-switch experiment did not recover
capture. The attempt failed after 95.264 seconds with no sampler errors, verified cleanup, and
restored physical topology. The switch was removed rather than shipped, and the original source
was rebuilt. These source diagnostics do not qualify a release candidate.

After removing the experimental switch, the optimized CLI and ad-hoc Viewer were rebuilt;
the Viewer passed strict/deep signature verification. The restored default daemon matched the
CLI with ready safety, drive/capture grants, zero sessions, and the original physical topology.
`make verify-release` then passed with 1,670 Swift tests, supporting checks, and the 34-tool MCP
smoke check; `git diff --check` passed. Only audit/backlog records changed in the final worktree.


## Single-window capture snapshot ownership

Inspection of the frozen-capture path identified a separate omission: `Capture.window` awaited
ScreenCaptureKit's shareable-content snapshot, then selected the first matching numeric window
ID without checking its owning process. Window IDs can be recycled. The daemon performs later
session/geometry validation before publishing screenshots, but direct SDK calls do not have
that layer. This was a source-level finding, not an observed user-content disclosure or an
explanation of the Chromium freeze.

The capture layer now validates a nonzero requested window ID, a positive requested PID, and a
matching, known ScreenCaptureKit owner from the exact snapshot used to construct the filter.
Mismatch or unknown ownership produces a structured capture failure before native capture starts.
The check adds no extra native lookup or retry. It does not establish process incarnation from a
PID alone; existing session identity and post-capture geometry checks remain necessary.

All nine targeted CaptureIsolationTests passed, including three new cases covering accepted
matching ownership, a reused ID with a foreign/unknown owner, and invalid requested identities.
These tests use synthetic values and do not access WindowServer or capture images.

`make verify-release` passed with 1,673 Swift tests, supporting checks, and the 34-tool MCP
smoke check. The rebuilt ad-hoc Viewer passed strict/deep signature verification and
`git diff --check` passed. A focused live matrix follows separately; these deterministic
checks do not by themselves qualify the new capture behavior on a release candidate.

The supervised full MCP matrix on source `8215cf7` passed all 36 checks, with zero failed,
blocked, or skipped steps and 44 tool calls in 80.128 seconds. This includes real native and
Chromium screenshot paths with the new snapshot-owner guard, as well as the existing isolation
and display-retirement checks. The private evidence is `.artifacts/window-owner-8215cf7/`.
The wrapper verified zero sessions, original topology, and ready safety before stopping its
daemon. The matching default daemon was restored with drive/capture grants and zero sessions.
This source matrix does not establish animated Chromium rendering, process-incarnation identity
from PID alone, or pinned-toolchain/signed-candidate release qualification.


## Frame-pipeline trace: undrawn-frame throttling

Two source `f5f7b93` diagnostics used the reserved-host supervisor, a private Chrome fixture,
and the existing capture/cleanup harness. An eight-second CDP trace selected `viz,gpu,cc`
categories, capped incoming messages at 4 MiB and total events at 100,000, and required trace
completion without reported data loss. It retained only counts for allowed compositor-event
names and synthetic page numeric state. Raw trace payloads, event arguments, screenshots,
page content, and target identifiers were not retained. Exact helpers/hashes and structured
results are private in `.artifacts/frame-trace-f5f7b93/` and
`.artifacts/frame-decisions-f5f7b93/`. No production code or launch flags changed.

The first trace completed with 5,442 events, including 480 `CVDisplayLinkCallback` and 480
`ExternalBeginFrameSourceMac::OnDisplayLinkCallback` events, but only seven renderer begin-frame,
prepare-to-draw, and frame-ack events. The visible fixture's animation counter advanced from
27 to 34. Native captures stayed identical before, during, and after tracing. Counts are trace
event occurrences across the private Chrome instance, not a per-display proof or presentation
count. The result contradicts a complete absence of browser display-link callbacks in this run.

Inspection of the installed Chrome version's
[frame-sink decision code](https://raw.githubusercontent.com/chromium/chromium/154.0.8037.58/components/viz/service/frame_sinks/compositor_frame_sink_support.cc)
identified fixed reason codes that distinguish requested throttling, client unresponsiveness,
and undrawn-frame buildup. A second instrumented trace counted only these explicitly allowed
reason/boolean pairs. It completed with 5,885 events and no overflow or reported data loss:
481 display-link callbacks, eight renderer begin-frame/draw cycles, 473
`ThrottleUndrawnFrames:false` decisions, and eight `SendFrameTiming:true` decisions. The visible
fixture advanced from 27 to 35 animation callbacks and scrollY 216 to 280; native pixels still
did not change. This establishes undrawn-frame throttling for the observed interval, not its
underlying cause. Disabling that throttle would not by itself prove that pixels are presented.

Both attempts failed the unchanged-pixel assertion, after 106.977 and 108.709 seconds
respectively, and verified normal cleanup with no sampler errors and original physical topology.
After each run the matching default daemon was restored; doctor confirmed ready safety,
drive/capture grants, and zero sessions. The intermittent startup identity failure did not
recur in these attempts. These focused source diagnostics are not passing release evidence.

After recording both traces, `make verify-release` passed with 1,673 Swift tests, supporting
checks, and the 34-tool MCP smoke test. `git diff --check` passed. The final changes are audit
and backlog updates only; neither an experimental switch nor a renderer workaround was added.


## Native visibility identifies a missed reveal

The next source `df8fb07` diagnostic kept its read-only native observer alive through static
and scrolling rendering. Of 54 samples, the initial startup sample reported not hidden; the
remaining 53 reported Chrome hidden and inactive with zero on-screen windows. AX consistently
reported one owned, non-minimized window after startup. The trace again showed 472
`ThrottleUndrawnFrames` decisions versus eight frame-timing updates, and all native captures
were unchanged. Cleanup verified physical topology after 108.837 seconds. Evidence is private
in `.artifacts/visibility-trace-df8fb07/`.

A separate diagnostic permitted exactly one non-activating `NSRunningApplication.unhide()`
request after 25 seconds, gated on SpaceO's successful launch/placement result and the original
private process identity. Chrome then became not hidden with an on-screen window while remaining
inactive. Native captures changed before, during, and after the subsequent trace, and recent
Viewer samples reached 8.5, 10.5, and 12 FPS. The method's immediate Boolean return was false;
only later observations established visibility. The trace exceeded its 100,000-event cap once
rendering resumed, so the diagnostic run is not recorded as a complete passing trace or full
performance qualification. The bounded helper, hashes, and outcome are retained privately in
`.artifacts/reveal-trace-df8fb07/`; no trace payload or screenshots were saved.

The production reveal gate had used `NSRunningApplication.isHidden`, allowing a cached false
observation to skip `unhide()` and report readiness. Apple's
[NSRunningApplication documentation](https://developer.apple.com/documentation/appkit/nsrunningapplication?language=objc)
explains that changing properties retain their values until a main-run-loop turn. The native
observer and explicit-reveal experiment identify hidden application state as a concrete cause
of the observed motion failure; they do not explain every intermittent window-identity failure.

The fix reads the application's `AXHidden` attribute through the existing bounded AX provider.
Reveal's one-second deadline is passed into each read; unknown or failed observations cannot
confirm success, cancellation/identity are checked before unhide, and an expired read cannot
trigger a late unhide or claim readiness. The unhide return value is not treated as confirmation.
Existing post-reveal placement and containment checks remain in place. Fourteen targeted launch
polling tests pass, including new unknown/error and late-hidden/late-visible observations.

The explicit-reveal diagnostic cleaned up normally after 111.074 seconds, with no sampler
errors or topology changes; no observer sample reported Chrome active. Full deterministic
verification of the production fix passed: 1,675 Swift tests, supporting checks, and the
34-tool MCP smoke test. The rebuilt ad-hoc Viewer passed strict/deep signature verification,
and `git diff --check` passed. Standard production-path live checks follow separately.


The first standard workload on source `793cf25` failed safely during launch: after reveal,
Chrome placed the full-height requested window 30 points below the tile's top, overflowing its
bottom. The placement guard refused it. This exposed a geometry issue previously masked by
hidden application state; it is not recorded as a passing motion test. Cleanup/topology were
verified in `.artifacts/fresh-reveal-793cf25/`.

Browser background-window creation now requests the existing inset `defaultFrame` instead of
the entire tile. The subsequent placement checks remain authoritative. Both the input region
and computed frame must be valid and fit protocol integer limits before endpoint discovery;
sub-point dimensions cannot become zero-sized CDP requests. Sixty focused Chromium/launch tests
passed, including exact inset bounds, unchanged background-only creation and tab parameters,
and rejection of an unusably small inset before connecting.

Full verification of the combined reveal/inset changes passed: 1,676 Swift tests, supporting
checks, and the 34-tool MCP smoke check. The rebuilt Viewer passed strict/deep signature
verification, and `git diff --check` passed. The rejected full-height launch cleaned up after
52.094 seconds with no sampler errors. No containment tolerance was relaxed.


The standard production-path workload on source `3e85de4` did not reach Viewer creation or
motion coverage. The `run` command failed after 5.028 seconds with a bounded AX provider error:
window count unavailable, AX error `-25204`. The evidence does not identify which placement
pass failed, so this is not assigned to post-reveal placement without further instrumentation.
The attempt ended after 51.033 seconds with verified cleanup, no sampler errors, and the original
physical topology. It is not a passing motion result, and no unchanged-source retry followed.
Private evidence is `.artifacts/reveal-inset-3e85de4/`.

The matching source daemon was restored with ready safety, drive/capture grants, and zero
sessions. The current production fix has passed deterministic verification, but the standard
animated/scrolling workload and post-fix isolation matrix remain outstanding. The explicit
helper experiment demonstrates a recoverable hidden-window cause; it does not substitute for
these production-path acceptance checks. Both open Chromium findings remain tracked.


## Launch-phase attribution for AX failures

The `3e85de4` window-count failure lacked enough context to identify the failed placement pass.
The launcher now retains a fixed phase label through materialization, containment, browser and
window readiness, initial/settled placement, reveal, and post-reveal placement. When an AX
traversal error escapes, its existing reason and detail are preserved with that phase prefix.
Cancellation errors and unrelated error types retain their existing mapping. No extra retries,
application content, window titles, or user-supplied phase labels are introduced. Regression
coverage checks every phase across provider, deadline, and cancellation stop reasons.

Fifteen focused launch tests passed. Full `make verify-release` passed with 1,677 Swift tests,
supporting checks, and the 34-tool MCP smoke check. The rebuilt ad-hoc Viewer passed strict/deep
signature verification and `git diff --check` passed before the next instrumented source run.
