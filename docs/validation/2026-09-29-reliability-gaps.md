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
Live results will be recorded separately after the immutable source checkpoint.

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
- Full source live tests and the exact signed candidate's computer-use matrix must run on an
  eligible, idle graphical host under `docs/LIVE_TESTS.md`. Existing owner release GO records do
  not qualify these new source changes.

The older product backlog contains stale per-ticket “Open” labels for work its later status
sections report implemented. This audit uses current source and newer validation records;
historical descriptions alone are not evidence of missing features.
