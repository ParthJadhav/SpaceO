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
