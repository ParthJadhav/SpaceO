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
