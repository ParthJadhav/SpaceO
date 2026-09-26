# September 26 containment regression results

Initial source commit: `79da94e1740ce70112d16000ca9a3664a672ac57`.
Review follow-up: `2e0782821f89232eef19ccca4077fce1fa46f264` (results below).

**Latest status: the review follow-up is not fully live-qualified.** Its deterministic checks
and CI passed, but its full live run stopped on the intermittent TextEdit Accessibility blackout:
13 cases passed, one failed and two were skipped after the failure. No follow-up MCP matrix ran.
No WindowServer restart or kernel panic was observed. The failure journal remains latched.

## Earlier passing run (`79da94e`)

SpaceO's containment changes passed the complete live suite and MCP matrix on the original
incident topology: Mac17,9 / M5 Pro, macOS 27.2 build 26B5091g, Alienware AW3225QF at 4K/240 Hz
with the built-in display mirrored. The owner had reserved this Mac and authorized this setup.
On resumption it was already reconnected; the agent did not change display settings.

These are source regression results from a separately compiled `SPACEO_DISPLAY_QUALIFICATION`
build with both runtime opt-ins. Normal builds still enforce the mirrored/high-refresh admission
precautions. The macOS 27+ blanket version quarantine is removed. These results neither fix
Apple's kernel driver nor guarantee that a panic cannot recur; see [DISPLAY_SAFETY.md](../DISPLAY_SAFETY.md).

## Fixes verified

- Display allocation uses the Space IDs cached at publication and rejects an invalid or
  circuit-failed Stage instead of reporting a successful allocation after a failed query.
- Retirement shares one absolute deadline across queueing, preflight, invalidation, removal
  and verification. Expired preflight cannot proceed to a late invalidation.
- Daemon health and `doctor` expose pending, failed or unreadable lifecycle state. Doctor's
  readiness and exit status reflect the latch without acquiring or resetting the owner's lease.
- Creation-budget refusals report the actual remaining wait across both rolling windows.
- Reopening files in an existing Chromium process uses background DevTools targets, preserving
  the page bridge and refusing a LaunchServices fallback when its private endpoint is missing.
- Shipped agent playbooks state the managed Electron refusal, and troubleshooting includes the
  required reserved-host live-test opt-in.

## Results

All times below are IST on September 26, 2026.

| Check | Result |
|---|---|
| `make verify-release` | 1,612 deterministic Swift tests; Viewer install checks, 4 supervisor tests, 15 Node tests and 34-tool MCP smoke passed |
| Warning-strict release build | Passed |
| Release-security and live-gate fixtures | Passed |
| Viewer bundle and deep strict signature verification | Passed; local build only |
| Supervised single lifecycle, 13:47:05–13:48:35 | 1 passed, 0 failed; no remaining virtual display or topology change |
| Full live suite, 13:49:08–14:14:09 | 16 passed, 0 failed, 0 skipped; 1,501.054 seconds; wrapper and completeness checker exited 0 |
| Full MCP matrix, 14:23:39–14:24:22 | 36 passed, 0 failed/blocked/skipped; 44 tool calls; exited 0 |
| Final cleanup | Zero test sessions, displays and orphan displays; isolated test daemon stopped; pre-existing daemon preserved |
| GitHub CI | [Both checks passed](https://github.com/ParthJadhav/SpaceO/actions/runs/36229286322) |

Both previously implicated cases—two sessions staying in their tiles and containment of late
windows—passed on the mirrored setup. The added MCP regression confirmed that reopening files
reused Chromium, produced additional contained windows and preserved the covered isolation checks.
Electron's expected pre-launch refusal is tested explicitly; this does not claim Electron support.

The suite retained one physical baseline across all cases. The full-suite postflight and both
matrix inventories match it. The Alienware remained at mirrored 240 Hz. WindowServer retained
PID 425, and ColorSync returned to idle between sampled display transitions. No lifecycle timeout,
configuration drift, WindowServer restart or panic was observed. The final lifecycle journal
reports ready. This completes the source experiment that the intentionally disconnected monitor
and shell error had left incomplete on [September 25](2026-09-25-display-containment.md).

## Retained evidence

Owner-only local artifacts are in `.artifacts/panic-qualification-20260926/`: source and frozen
runner hashes, test executable and signed CLI provenance, baseline/postflight inventories,
per-case logs, service samples, structured matrix results and cleanup results. The running
runner and source were not edited during qualification. Raw diagnostics and user data are not
committed. No host installation, public artifact or release is part of this source fix.

## Review follow-up

The follow-up closes four additional edge cases:

- A short geometry query no longer waits behind a healthy long mutation and opens the global
  failure circuit. It uses the last verified geometry/Space snapshot while the worker is busy,
  then refreshes the snapshot when idle.
- Cleanup preflight failure retains the display backing before returning, including the
  deinitialization fallback, so dropping the Stage cannot trigger an uncoordinated ARC teardown.
- Ordinary daemon replies read a separately locked memory snapshot. They perform no lifecycle
  journal I/O and do not wait on the journal owner's I/O mutex. Persistence remains blocked in
  the snapshot until its write completes.
- Partial reused-browser file opens return per-file receipts for confirmed, unknown and unsent
  work. Confirmed target IDs survive wire encoding; the caller is told not to replay those opens.

`make verify-release` passed 1,618 deterministic Swift tests, the supervisor/Node fixtures and
the 34-tool MCP smoke test. The qualification CLI built with warnings as errors. The single
lifecycle passed at 14:47:02–14:48:33 IST with clean postflight. The pinned Swift 6.2 CI also
[passed both jobs](https://github.com/ParthJadhav/SpaceO/actions/runs/36232079022), after an explicit
`Double` conversion fixed a type-inference difference from local Swift 6.4.

Follow-up artifacts are retained separately in `.artifacts/panic-qualification-20260926-review2/`,
including source/binary hashes and frozen runners. The preceding full-run results remain bound
to `79da94e`; they are not silently relabeled as evidence for the follow-up.

The follow-up full suite ran at 14:49:05–15:11:10 IST. Thirteen cases passed, including capture,
Chromium interaction, the full workflow, multiple stages, pool reuse, retirement and managed
Space checks. `testTwoSessionsOnOneDisplayStayInTheirOwnTiles` then failed: a newly launched
TextEdit process did not expose an identified Accessibility window during its 15-second wait,
although WindowServer listed two document-sized windows. The last two cases were skipped by
the first-failure gate; the wrapper exited 1. This is not a passing full-suite result.

Postflight found the original mirrored physical topology, no SpaceO or orphaned displays,
and a blocked lifecycle journal (`failure` plus `liveTestPending`; no pending display mutation).
The XCTest process had exited. WindowServer retained PID 425 and ColorSync retained PID 1992,
returning to idle in the samples. The failure latch was archived as evidence and left intact;
neither another virtual-display run nor the MCP matrix was attempted.

This matches the unresolved TextEdit AX blackout documented as BUG-9 in the
[August 29 investigation](2026-08-29-claude-full-feature-regression.md). The failure occurs before
placement, and the retained log does not distinguish an empty AX list from unresolved AX window
identities. It does not establish that the new geometry cache caused the failure or that Apple's
display driver failed again. A separate bounded, public-API-only probe launched two new TextEdit
instances on the physical display, without a virtual display or synthesized input. Both recovered
from transient startup AX errors and exposed a window; both were closed afterward. That probe
did not reproduce the persistent blackout or qualify the failed live case.

Retained follow-up evidence includes `full-live.log`, `full-result.json`, `failure-journal.json`,
`failure-postflight.json`, targeted TextEdit system logs, service samples and the physical-only
AX probe source/results. The underlying intermittent AX failure remains unresolved. Further
display qualification must follow the documented recovery procedure; no automatic retry or
journal reset was used to turn this failed run into a green result.
