# Native AX identity follow-up — October 4–5

## Retained source fix

Launch readiness asks whether any window has a resolved identity. Previously, a stale first
member prevented examining a valid later member. Readiness now continues past only
`invalidUIElement` under the existing shared node, allocation, IPC, deadline and cancellation
budgets. It preserves a provider failure if no identity resolves. Complete discovery before
placement remains strict; a partial set does not escape.

This readiness checkpoint passed **58 focused traversal tests**. Regressions cover invalid first members and
later pages, no resolved identity, each continuation budget, strict complete discovery in both
orders, and refusal of `illegalArgument`, API-disabled and unimplemented identity errors.

## Independent native observations

Private signed, display-free observation helpers watched only newly launched test applications.
The daemon owned each application and its cleanup. Helpers retained fixed AX roles, counts,
status codes and boolean identity comparisons; no titles, text, leases or process inventory
are reproduced here. These diagnostics used the explicit authorized testing-host overrides.

Fresh TextEdit instances consistently returned one AX window entry with role `AXApplication`,
equal to the application root. The paged list, direct CFArray entries, whole `AXWindows` read,
`AXMainWindow` and `AXFocusedWindow` agreed. WindowServer separately reported two layer-zero
windows for the process. The private identity getter returned **`illegalArgument` (-25201)**,
not **`invalidUIElement` (-25202)**. Thus the ordering fix does not repair this observation.

| Owned-process diagnostic | Result |
| --- | --- |
| Wait for finished launching | Finished launching; root alias persisted. |
| Read supported AX initialization flags | Enhanced UI reported readable/settable; manual accessibility was unsupported. |
| Write enhanced UI once, after exact ledger/process-start ownership verification | `notImplemented` (-25208); no repair. No production flag write was added. |
| Register window/focus notifications and read bounded children | Registration succeeded; children contained the root and a menu bar; window alias persisted. |
| PID-addressed second-document event | Permission preflight reported consent required (-1744); the event was not sent. No grant was changed. |
| Launch TextEdit without a file | Same root alias and identity refusal. |
| Launch fresh Calculator | Same root alias and identity refusal. |

Each native attempt stopped on the failure. Sessions were destroyed, idle displays trimmed,
and private daemons exited normally. Postflight lifecycle reports were ready, with no retained
SpaceO/orphan/deferred display owners. The signed CLI used for these observations predates the
readiness ordering change; these runs are diagnosis, not live qualification of that change.

## Console state and remaining check

A subsequent read-only console observation reported `IOConsoleLocked=true` and
`CGSSessionScreenIsLocked=true` for the logged-in console session. These are undocumented diagnostic keys; missing values
would be unknown, and on-console/login-complete alone does not imply unlocked. This is a concrete candidate
for the cross-application behavior, and a subsequent same-signed-CLI native run after operator unlock passed **16/16 checks**
with 12 tool calls, zero failures/blocks/skips, topology/cleanup checks passed and normal daemon
shutdown. This establishes recovery after unlock for that binary and workload; the internal
reason for the root aliases is not proven. Native probes did not retain contemporaneous lock state, so earlier failed or passing
runs must not be retrospectively labeled locked or unlocked.

The operator unlocked the testing Mac without sharing a password; a follow-up observation
reported `IOConsoleLocked=false`. No reservation was requested again, and the authorized
testing-host overrides remained enabled. The updated signed-source full live suite and MCP
matrix are being verified serially with a bounded awake assertion. No window identity is guessed and
no failed native workflow is counted as passed. RA-057 and healthy-host release qualification
remain separate and open; this AX observation does not establish the supplied panic's cause.


## Independent source review

A separate read-only review of the retained production and reporting diff found no actionable
high/medium regression in ownership, capture publication checks, recovery timing, bounded
histories, MCP error handling or readiness semantics. This review is source evidence, not a
passing native workflow or confirmation of the lock-state hypothesis.


## Report context fix

The live host helper now retains timestamped `consoleSessionDiagnostic` metadata. Its bounded
helper reads at most 1 MiB, retains at most 32 session records, and exposes only boolean or unknown
on-console, login-complete and lock values. Raw IORegistry contents and user identities are
omitted. Helper/parser failures produce an unavailable diagnostic without changing admission,
health reasons, or the explicit testing override. This improves future failure evidence; it
is not an unlock operation or a new gate. Focused regressions cover privacy, strict boolean
handling, saturation, helper failure and admission independence.


## Strict snapshot-root and web evidence fixes

Snapshot-root lookup now uses checked window counts, exact-sized pages and checked identities.
The same traversal budget and three-attempt transient retry policy apply; deadlines, per-call
limits and cancellation are unchanged. A successful empty or complete missing list still reports
a missing window. Provider failure, malformed pages/identities or changed counts report an
incomplete observation. Only a matching requested handle is returned; no title/geometry walk or
invented window identity is added. Root lookup now charges the shared node/allocation budget.
Eight new regressions bring the focused AX traversal suite to **66 passing tests**.

Web fixture-state parsing now refuses a failed window observation before checking its events.
The harness distinguishes missing fixture state from an observed absence of an event, and stops
on a failed screen read. Its hover target is exposed as a page element; hover and input controls
use exact labels, current `wN` references and reported viewport coordinates. Guessed hover
offsets and the fixed text-input index were removed. **11 web-evidence tests pass**, including
failed reads containing plausible fixture text and shifted references. An independent Fast
source review found no actionable high/medium regression. These changes improve observation
and error handling; they do not establish that every Chrome provider stall is repaired.

## Retained-source verification

`make verify-release` passed **1,833 Swift tests, 27 Node tests and 35-tool MCP smoke** after the
console-reporting change. The host-helper suite passed **28 tests**. The warnings-as-errors
release build, release-security and live-gate fixtures, workflow privacy checks, and strict
signed Viewer verification passed. Both independent source review rounds found no actionable
high/medium regression.

The full live run preserves the repository's 90-second spacing. Its initial outer coordinator
had a shorter timeout than this pacing permits; only that waiting coordinator was stopped and
replaced. The existing Make/XCTest workload and its original case/whole-run supervisor continued.
No test case was restarted, no spacing or clock was changed, and no native owner was killed.
The retained logs span midnight into October 5. All **15/15 live tests passed**, with no
failures or skips; the workflow gate and an independent retained-log check passed. Exact
physical topology was preserved and no virtual display remained.

The subsequent full signed MCP matrix stopped at **23 passes / one failure**, with no
blocks/skips. The web hover action succeeded, but its window-title verification failed when
Chrome's AX window-count query returned `cannotComplete` (-25204) after three bounded retries.
Thus the hover effect was unverified, not disproven. The concurrent owned TextEdit probe retained
15 window observations: all had `AXWindow` role, successful identity, matching PID/WindowServer
owner and no equality to the application root. Console diagnostics remained unlocked.

An isolated web follow-up stopped at **12 passes / one failure**, again with no blocks/skips.
The screen read reported `window_not_ready` after complete discovery had succeeded. Source
inspection found that snapshot-root lookup used best-effort AX count/page/identity reads, which
can turn a provider failure into a missing-window claim. Strict error propagation was subsequently
repaired under the existing budgets. Both failed attempts cleaned up normally, retained exact
physical topology, ended ready with zero virtual displays, and stopped their private daemons.
No failed read or incomplete suite is being converted to a qualification pass.


## Final strict-root source and signed matrix

The final retained source passed `make verify-release`: **1,841 Swift tests, 29 Node tests and
35-tool MCP smoke**, with no failures. The 28 host-helper fixtures, warnings-as-errors release
build and strict signed CLI/Viewer verification passed. An independent review of the last root
and harness changes found no actionable high/medium regression.

The rebuilt signed CLI (SHA-256
`b37d5c8f9ca7e8a480010dd3f4198adda75a67ab8765406889cdc78c5e5fc018`)
passed the full native/web/Electron-refusal MCP matrix: **41/41 checks**, 44 calls, zero
failures/blocks/skips. This includes confirmed hover, drag, input, slider and modifier-click
results. Its three additional checks verify exposed hover coordinates, the input reference and
accepted input-field click. This passing attempt does not erase the two earlier failed attempts
or prove that all intermittent native/provider faults are eliminated.

Exact physical topology was preserved, no virtual display remained, postflight lifecycle was
ready and the private daemon stopped normally. The console remained observed unlocked. Testing
host-health/rate overrides were explicit; this is functional diagnostic evidence, not normal
healthy-host release qualification or proof that the supplied kernel panic is remediated. The
15-test full live result above predates the last strict snapshot-root change; final-source native
AX verification is recorded separately below.


## Final-source native AX workflow

The updated-source `IntegrationTests/testFullWorkflowHasNoCoveredIsolationBreach` passed
through the supported live wrapper, with no failure or skip. Its 115.7-second duration includes
the unchanged 90-second pacing. Launch, placement, typed-text readback, window-scoped AX snapshot,
covered isolation and owned application/display cleanup passed. The wrapper and an independent
retained-log check both exited zero. Pre/post physical topology matched exactly, no virtual
display remained and postflight lifecycle was ready.

This focused run verifies the last root-lookup change alongside the final 41/41 signed MCP
matrix. The earlier full 15/15 live run is preserved at its prior revision; it is not silently
re-labeled as a full live run of the final root change. Final `git diff --check` passed. All task
owners have stopped normally; no failed case was resumed or automatic matrix retry added.
At the close of this validation phase, the changes were reviewable on
`fix/report-driven-reliability`. No installation, publication, push, merge or external reply
had occurred during that phase.
