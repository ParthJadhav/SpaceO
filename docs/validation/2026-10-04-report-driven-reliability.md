# October 4 report-driven reliability review

Scope: compare recent and older local improvement-loop records, retained validation, and all
four open GitHub reports against current source `c727fe1`. Work is on the isolated
`fix/report-driven-reliability` branch. The original checkout and its local commits are preserved.
Initial review used read-only host evidence. The operator subsequently designated this Mac as
the testing Mac and explicitly requested removal of testing blockers. This supersedes the
initial no-recovery/no-live-work scope. No host installation, external reply or publication occurred.

## Evidence and disposition

| Report | Current evidence | Disposition |
| --- | --- | --- |
| Recent local journals, October 3–4 | Seven tool calls: four refused creates, two missing-lease calls and one unknown-session destroy | Persistent safety refusals are preserved. Failed calls no longer imply owned sessions or missing cleanup. |
| Retained journals, September 23–October 4 | 538 calls, including 12 unsupported-target, 10 isolation, four teardown and three general-operation errors | Historical counts are not current regressions. Preserve Electron refusal, isolation and identity guards; later fixes and qualification boundaries remain in the active ledger. |
| [#36 follow-up](https://github.com/ParthJadhav/SpaceO/issues/36#issuecomment-5979309054) | Reporter reproduced a swap latch with no pending mutation and a misleading recovery refusal | Add bounded explicit recovery for an idle pressure/swap latch after owner exclusion and fresh settled health. Live-owner recovery and strict intermittent swap refusal remain limitations. |
| [#36 reboot retest](https://github.com/ParthJadhav/SpaceO/issues/36#issuecomment-5979949864) | Reporter confirmed ColorSync admission on 27.0 and a complete native workflow on 27.0.1 after reboot | Retain as reporter evidence, not local or exact-candidate qualification of this changed source. |
| [#34](https://github.com/ParthJadhav/SpaceO/issues/34), [#30](https://github.com/ParthJadhav/SpaceO/issues/30) | Later source fixes address idle ColorSync admission, permission attribution and native replacement; no new reporter confirmation | Avoid repeating superseded fixes. Reporter-host confirmation remains pending. |
| [#38](https://github.com/ParthJadhav/SpaceO/issues/38) and RA-057 | Specified empty/inactive host-state qualification is incomplete; retained trial timed out | Keep open. This task does not change headless admission, system diagnostic history or release gates. |

The read-only installed doctor exited nonzero with
`host health: recent_windowserver_diagnostic`, zero SpaceO displays and zero orphan displays.
This incident latch remains ineligible for normal idle resource recovery. The explicit testing
mode now permits archived idle host-health recovery without erasing diagnostic history. The
actual initiating ColorSync/system fault remains unresolved.

## Implemented fixes

1. **Cleanup evidence.** Track observed acquisition and confirmed release by connection and
   lifetime, retain earlier context across `--since`, handle successful all/implicit destroys,
   and separate open connections from ended connections. Failed create/observer calls do not
   prove ownership; failed destroys do not prove cleanup. Recreated names begin new lifetimes.
   The candidate says cleanup was not observed, rather than asserting janitor abandonment.
2. **Ownership telemetry and guidance.** New journal lifecycle fields prove acquired ownership
   from the returned lease without logging that credential, including a failed create-and-open.
   Bulk destroy records its confirmed successful subset. Missing leases report `lease_required`
   with failed-creation guidance; ambiguous ownership reports `ambiguous_session`. Both use
   `controller_error`, separate from schema validation. Historical other-validation errors no
   longer suggest an argument alias, and guard failures are labeled protected refusals.
3. **Bounded report input.** Read nonblocking regular-file descriptors, enforce byte limits
   throughout reading, and bound line size, record count, traversal depth and total entries.
   Refuse pipes without waiting, deduplicate file aliases, skip directory links and validate
   dates/required path arguments. Drop full result text before retaining parsed records. Error
   messages and first lines can still contain private app content; raw reports remain local.
4. **Idle resource recovery.** Allow exact pressure/swap reasons, including their combination,
   under the existing exclusive lifecycle lock. Preserve journal identity, rolling budgets,
   archives and the commit/abort decision protocol. Pending mutations/live cases and mixed
   incident, timeout, stale or unknown reasons remain refused. Require two fresh assessed
   ColorSync intervals below 25%, normal pressure, zero new swap and passing diagnostic checks.
   Retain the health monitor and recheck it after journal persistence and immediately before
   the commit syscall. A health change detected before that syscall refuses recovery. Once
   the filesystem syscall starts it cannot be revoked; an exclusive abort receipt still
   prevents a late commit when the abort wins. Unsupported recovery now explains
   its eligibility instead of misreporting a pending mutation.

The report replay now shows zero ended-connection cleanup candidates for the seven recent
calls, where the original analyzer reported two. The full historical replay shows zero ended
cleanup candidates and one open connection with observed acquisition. Neither result proves
physical cleanup or absence of leaks. Older journals lack ownership facts for a failed partial
create or the successful subset of a failed bulk destroy; those cases remain uncertain.

Synthetic replay against the original analyzer reproduced three defects: a refused create
counted as one abandoned session, an invalid destroy incorrectly cleared ownership, and a
recreated name was incorrectly treated as already destroyed. New regression cases distinguish
all three and retain conclusive bulk success when a released-ID array reaches its cap. FIFO refusal and bounded malformed/oversized input use isolated local fixtures.

## Verification

- Focused Swift run: **86 tests passed**, covering recovery, settled-health behavior, doctor,
  controller ownership and journal records.
- Report tests: **14 passed**, including lifetime/filter/connection cases, partial ownership,
  special-file/alias/depth/byte/record/line boundaries, and refusal classification.
- Final `make verify-release`: **passed** with **1,818 deterministic Swift tests**, supporting
  script/installer fixtures, **26 Node tests** and MCP smoke across **35 tools**. The smoke
  checks that opening an unowned synthetic session is refused before any application launch.
- Release-security and live-test gate policy scripts: **passed**.
- Release warnings-as-errors build: **passed**.
- `git diff --check`: passed.

The first full check rejected a new test fixture's nonexistent daemon-state enum case. The
fixture was corrected; the subsequent focused and full runs passed. Tests use temporary journals,
fake providers and synthetic sockets; the safe suite creates no test display or user input.
Private verification logs are retained in `.artifacts/report-driven-reliability-20261004/`.
Compiler: local Swift 6.4 on arm64. These checks do not constitute live host, pinned-toolchain,
physical Viewer or exact signed-artifact qualification.

## Remaining qualification boundaries

- Qualify the changed recovery and normal lifecycle paths on an eligible, reserved host with
  retained pre/post topology, health, capture/input and cleanup evidence. This Mac was explicitly
  reserved for testing by the operator. The complete live suite and MCP matrix passed here in
  override mode; normal host-health and exact released-artifact qualification are separate.
- Normal runs retain the conservative any-new-swap rule. Explicit testing runs bypass it,
  along with host-health/settling admission; the helper retains observed reasons and counters.
  No diagnostic history is erased.
- Recovery still excludes a live owner and cannot turn unhealthy-host teardown into success.
  The idle installed daemon and the private test daemon exited normally in this reserved test run.
- RA-057, intermittent native AX discovery, #38's specified host-state runs and signed-candidate
  behavior qualification remain open. No new release is qualified by this review.

## Completion-audit follow-up

Read-only doctor and GitHub report timestamps remained unchanged. A new deterministic commit
boundary fixture changed health between the preceding check and the commit call. Before the
follow-up fix, recovery returned success, the status was ready and a commit receipt existed:
three assertions failed. The commit body now rechecks the shared deadline and current health
immediately before invoking the exclusive rename. This does not make an already-entered
filesystem call cancellable or establish live qualification.

The commit-boundary regressions and testing override passed 40 focused Swift tests. Python
host-health tests passed, including both-flag opt-in and retained observed refusal. The existing
idle daemon exited normally. The signed source build passed. Explicit testing-mode recovery
succeeded, archiving the diagnostic latch while retaining creation history and the original
journal identity. The source doctor confirmed Accessibility and Screen Recording grants,
zero SpaceO displays and zero orphans before recovery. Supervised full live XCTest completed on this operator-designated host: **15/15 passed**, with
zero failures or skips in 1,748.8 seconds. This includes Chrome DevTools, rendering, native isolation,
app-exit auditing, janitor cleanup and shared-display retirement. Cleanup verification passed
for every case, and the wrapper and overridden postflight both exited successfully. The final deterministic `make verify-release` passed with 1,818
Swift tests, 26 Node tests and 35-tool MCP smoke; the release warnings-as-errors build,
release-security/live-gate scripts, public privacy checks and signed Viewer verification passed.

## Operator-designated testing mode

Both `SPACEO_LIVE_TESTS=1` and `SPACEO_TESTING_HOST=1` are required. This bypasses admission
and sampler faults/CPU settling for diagnostic work and permits explicit archived recovery of
an idle host-health latch. It does not bypass pending mutation/live-case markers, journal
exclusion, controller leases, topology, operation deadlines, pool resource limits or cleanup verification.
Native reports expose `testingOverride: true`, do not invent CPU values, and the matrix report
records the override in configuration. The independent helper retains `observedAdmitted` and
actual reasons even if its measurements are unavailable. One flag alone has no effect.


## Completed reserved-host verification

- **Full live XCTest: 15/15 passed**, no failures or skips. The supported external supervisor,
  full-suite coverage checker and overridden postflight all exited successfully. Display and
  physical-configuration cleanup verification ran after every case.
- **Full MCP matrix: 38/38 checks passed**, no failures, coverage blocks or skips, with 44 tool
  calls. Native capture, scrolling, clipping disclosure, typing and isolation passed. Chrome
  reference/coordinate input, hover, drag, selection, typing, reused background targets and
  isolation passed. Managed Electron refusal happened before application startup.
- Pool trim retired every virtual display. Final doctor passed with ready lifecycle, available
  drive/capture permissions, zero SpaceO/orphan/deferred-retirement displays and the same
  physical display inventory as the pre-recovery snapshot. The test daemon exited normally.
- The matrix used the locally signed changed source CLI on a private socket, with both testing
  flags. Its structured configuration records `testingOverride: true`; the helper retained
  observed unavailable-health reasons rather than inventing a healthy measurement. These
  results establish the exercised behavior in diagnostic mode, not normal health admission,
  #38's distinct empty/inactive host-state cases, or qualification of a released binary.

Final source gates: `make verify-release` passed (1,818 deterministic Swift tests, 26 Node tests,
35-tool MCP smoke), release warnings-as-errors passed, release-security and live-gate scripts
passed, public privacy checks passed, signed Viewer verification passed, and `git diff --check`
passed. No install, external reply, push, release or publication occurred. Changes remain
reviewable in this isolated worktree. Private logs and the sanitized matrix/provenance records
are retained under `.artifacts/report-driven-reliability-20261004/`.

## Extended signed workload and reproduced capture failure

The first combined signed-source workload passed load/subscriber handshakes, static/animated/
scrolling physical-display Viewer phases, scaled captures and 30 logical-session churn cycles.
Repeated capture then failed at about 322.6 seconds: the screenshot's full-app AX window-page
validation returned `-25204` (`cannotComplete`). The run remained failed; normal teardown and
independent physical-topology restoration passed. Its total runtime including cleanup was
356.7 seconds. Private evidence is retained in `continued-signed-soak`.

Known-window screenshot validation now checks only that discovered target's current owner,
precise process incarnation and bounds before native capture, after capture and immediately
before publication. ScreenCaptureKit checks the owner and frame in the snapshot used for its
independent-window filter. Topology/backing-scale checks and the shared capture deadline remain.
Unknown explicit windows still require bounded AX discovery; region captures retain complete
foreign-window privacy planning, and annotations still require their own bounded AX snapshot.
This does not manufacture a current global window list or fix unavailable native AX providers.

The signed capture-fix checkpoint's complete rerun passed in 356.5 seconds: **1,263 operations,
404 screenshots including 360 soak captures**, no failed daemon requests or sampler errors,
both Viewer motion phases and verified cleanup/topology restoration. The Viewer retained 312
live frame-sink samples and a maximum observed 29 FPS. This is workload-specific functional
evidence, not a performance comparison or a pixel-freshness guarantee. Evidence and executable
hashes are retained in `capture-target-signed-soak`. Later strengthening explicitly rejects
imprecise/currently unreadable process incarnation and is subject to final-source revalidation.

The helper's observed admission was false before and after that successful workload: pressure
level 2, new swap-ins and one recent WindowServer diagnostic remained. The explicit testing
override admitted the diagnostic workload. These results do not establish healthy-host release
qualification. Unknown helper observations now retain only a fixed `unavailableInput` stage,
without arbitrary exception or command output; normal runs still refuse them.

An independently timed display-sleep inventory probe ran after all workload owners exited.
Before, three requested-asleep samples and after showed the same readable inventory: two online
displays, one active display, zero reported asleep displays. The independent wake-up completed.
The probe did not obtain issue #38's empty/inactive starting state and is not its qualification.
No headless admission change or physical-disconnection claim is made.

The separately supplied kernel panic is analyzed in the
[WindowServer watchdog/display-driver timeline](2026-10-04-windowserver-panic.md).
Its internal event time is about 12.5 minutes after the failed workload's daemon stopped;
the report's later processing timestamp must not be used to claim an in-workload panic.

## Final-candidate follow-up

The final capture candidate's first matrix attempt stopped at a Chromium slider drag after
the isolation guard refused input. It retained **27 passed / one failed check**, then verified
cleanup and physical topology. Its refusal did not identify the failed isolation dimension;
the owner was already cleaned up, so the historical cause cannot be reconstructed from a new
observation. The harness now takes a read-only isolation follow-up after that error, retaining
only fixed check/status/coverage codes. It never resumes input or changes the failed result.
Parser fixtures cover private-data exclusion, unknown evidence and duplicate observations.

With this additional diagnostic recording, the complete final capture matrix passed **38/38**,
zero failures, blocks or skips and 44 tool calls. The native rendering XCTest passed **1/1**
without skips in 110.6 seconds through the supported supervisor and postflight checker. Its
source covers the changed ScreenCaptureKit snapshot-frame validation; the earlier 15/15 full
suite remains evidence for its recorded pre-capture-fix checkpoint, not a fresh full-suite run.
The matrix's postflight doctor was ready with zero SpaceO/orphan/deferred displays and unchanged
physical inventory; its private daemon exited normally.

A subsequent supervised combined soak stopped on the persistent daily creation budget before
Viewer startup: `resource_limit`, with verified normal cleanup and topology restoration. This
was not another AX failure. The explicitly authorized testing mode now bypasses persistent
rolling creation-rate admission, while keeping the latest 12 ten-minute and 32 daily timestamps.
Those entries completely determine normal admission after the override is removed. No journal
reset, clock change or default threshold reduction is used. Native safety and limits reports
expose `creationRateTestingOverride`; inactive persistent caps are omitted from limits, and
the effective pool minute cap remains. Normal admission, pending mutation/live-case checks,
ownership, operation deadlines, pool resource limits and failure cleanup remain enforced.

The budget follow-up passed **88 focused Swift tests**, including 100 diagnostic creations in
a private fake-time fixture, bounded journal size/history, normal restart refusal and eventual
age-out, pending mutation refusal, clock rollback and round-tripped diagnostic limits/status.
The source is subject to the final gates and rebuilt signed workload recorded below.


## Diagnostic-budget candidate and extended inactive investigation

The rebuilt budget candidate passed **1,827 Swift tests**, **27 Node tests** and the **35-tool
MCP smoke** under `make verify-release`. Release warnings-as-errors, release security/live gates,
private-data checks, and strict signed Viewer verification passed. On the exhausted rolling-day
history, its final signed MCP matrix passed **38/38**, zero failures/blocks/skips, 44 tool calls.
The supervised combined workload passed in **437.6 seconds**: **1,263 operations**, **404 captures**
including **360 soak captures**, zero failed daemon requests and zero sampler errors. Static,
animated and scrolling Viewer workloads and 30 session churn operations ran. Normal cleanup and
physical topology restoration were verified; the private owner exited. The matrix and soak
used the same signed CLI digest. Raw reports, metrics and application content remain private.

Both health preflight and postflight used the explicit testing override. The observed host
still had pressure/swap activity, a recent WindowServer diagnostic and busy ColorSync CPU;
therefore these results do not establish healthy-host or release qualification and do not close
RA-057. The budget history remained bounded and populated after the run.

An extended display-sleep probe supersedes the earlier short probe: five observations over
20 seconds returned a readable two-online, **zero-active** user inventory. The independently
armed wake restored the original graph. This Mac can produce an all-inactive starting state.

A private experimental admission candidate distinguished successful zero-count inventories,
admitted readable inactive graphs, and scoped global-Space/main-role checks to that state.
Its first attempt refused before mutation because an idle installed daemon had restarted and
held the lifecycle lock. That owner was stopped normally, and supported idle health recovery
archived its latch without deleting diagnostics or attempt history.

The subsequent controlled inactive attempt **failed publication**: attaching an agent display
changed a sleeping physical display's reported mode. No application launch or input followed.
The safety circuit retained the virtual-display owner; normal daemon shutdown correctly refused
unconfirmed teardown. This is a failed result, not headless qualification. Under the operator's
explicit testing-Mac recovery authorization, the private test owner was terminated after waking
and verifying an active physical display. Three subsequent inventory observations confirmed no
remaining virtual display and exact restoration of the original physical graph, including modes,
mirroring and main role. The failed journal was privately archived. An exclusive-lock operator
recovery cleared only that resolved failure/pending state after physical-only verification,
preserving both attempt histories and the original journal inode. No WindowServer process,
preferences, SIP, TCC or physical-display settings were reset.

The broader inactive admission changes were withdrawn. The retained fix distinguishes a
successful zero-count inventory from API failure, then refuses unqualified empty/all-inactive
graphs **before mutation**, avoiding the old false persistent inventory-failure latch. Query
errors, capacity saturation, zero/duplicate identifiers and malformed metadata still fail closed.
Issue #38 remains open on observed display-mode drift and its separate exited-ColorSync
qualification requirement; this investigation supplies concrete host evidence instead of a
reservation or unsupported-host assumption.


## Retained-source checkpoint before the AX follow-up

The final retained source passed `make verify-release`: **1,828 Swift tests**, **27 Node tests**,
zero failures, and the **35-tool MCP smoke**. Release warnings-as-errors, release security and
live-test gate fixtures, public-privacy scanning, computer-use evidence fixtures and strict signed
Viewer verification also passed. `git diff --check` passed. The signed artifacts were rebuilt from
this retained source; no installation, publication, push or merge was performed.

A supervised final signed inactive-inventory check **passed**: readable zero-active starting
state, the expected pre-mutation refusal, unchanged inactive physical graph, ready lifecycle,
no virtual display, normal daemon shutdown and exact physical graph restoration after wake.
The journal retained its populated attempt histories with no pending/live marker or failure.

The final signed full computer-use attempt **failed at TextEdit launch**: **seven checks passed,
one failed**, zero blocks/skips, three tool calls. The AX provider could not resolve a window
identity (`AXError -25201`, illegal argument) within launch readiness. This attempt stopped
before the web/Electron suites; their absence is not a pass. Its cleanup and physical topology
checks passed, postflight lifecycle was ready with zero SpaceO/orphan/deferred displays, and
its private daemon exited normally. Earlier complete 38/38 matrices and the 404-capture soak
remain evidence for their recorded candidates, not a claimed final full-matrix pass.

The native launch path already refreshes application/window observations under the absolute
readiness deadline and propagates persistent provider failure. This failed run establishes a
remaining native-provider symptom; it does not identify the historical invalid handle or justify
accepting an unidentified window, guessing a WindowServer identity, extending deadlines or
retrying the live matrix without a new diagnostic/fix. The general AX discovery finding stays
open, alongside #38, RA-057 and healthy-host release qualification. The supplied kernel panic's
causal relationship remains unproven. These unresolved OS/provider findings are retained rather
than suppressed to turn failed diagnostics into success.


## Later native AX follow-up

A bounded readiness ordering fix and independent native observations are recorded in the
[native identity follow-up](2026-10-04-ax-window-identity.md). The observed provider status is
`illegalArgument`, distinct from the stale-element condition handled by the retained fix.
Fresh Calculator reproduced the symptom. A later console check reported the testing Mac locked.
After operator unlock, the unchanged signed CLI passed 16/16 native checks. The following
updated-source full live run passed 15/15 tests, and owned native observations recovered actual
`AXWindow` identities. The lock association is established; the internal mechanism is unproven.

Two subsequent web verification failures exposed misleading snapshot-root and harness error
classification. Strict bounded root lookup now preserves provider errors; fixture observations
fail distinctly, and hover/input controls use current page references and coordinates. Final
source verification passed **1,841 Swift tests, 29 Node tests and 35-tool MCP smoke**. The rebuilt
signed full matrix passed **41/41 checks** with 44 calls, zero failures/blocks/skips, exact physical
topology, zero remaining virtual displays, ready lifecycle and normal private-daemon shutdown.
The earlier 15-test run predates the last snapshot-root change; a focused final native workflow
subsequently passed with its retained-log gate, ready lifecycle, zero virtual displays and
exact physical topology. The final native run covers the last root-lookup change. The additional matrix checks account for its increase from 38 to 41.

All live results use the explicitly authorized diagnostic testing overrides. Normal healthy-host
qualification, exact released-artifact behavior, #38 and RA-057 remain open. The WindowServer/
display-driver panic is related by subsystem; a SpaceO trigger or shared initiating cause has
not been established. No host install, publication, push, merge or external reply was performed.
