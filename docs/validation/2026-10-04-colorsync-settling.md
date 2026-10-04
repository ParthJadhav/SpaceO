# October 4 reconfiguration settling investigation

Status: source fix under verification; the RA-057 incident remains open. Issue #38
separately tracks empty/inactive-display and idle-service host qualification, which this
physical-display host does not establish.

## New observations

The owner renewed the instruction to resolve the remaining ColorSync incident and complete
live qualification. A clean worktree began at `main@5586920`. The official signed 1.0.7
release was installed through the verified installer. CLI, Viewer and the responding daemon
reported 1.0.7 with matching CLI/daemon build identity. The idle daemon was stopped normally
and any `com.spaceo.daemon` launchd job removed for the controlled no-daemon observation.
Retained doctor reports before and after installation showed no persisted LaunchAgent
configuration; its preservation had been assumed rather than established. After source
validation, the installed 1.0.7 daemon was again responding with matching CLI identity and
the same unsupervised configuration. No new supervision configuration was installed.

ColorSync sampled 30.86% with no daemon, Viewer or SpaceO displays. Closing System Settings
did not reduce it: the following sample was 31.09%. Pressure was normal and those samples
had no swap activity. A preceding two-minute profile-metadata observation saw unchanged
files and 30.53–30.95% CPU; daemon absence was not established during that observation because
launchd had restarted it. That interval is labeled as physical-only, not daemon-free evidence.
The inventory contained 667 ICC files: 541 SpaceO-only, 116 test-only, four in both categories
and six other files. No profiles, display preferences or registry caches were modified.

The system display-preference structure referenced 216 configurations and 176 unique display
UUIDs; the user structure referenced 230 configurations and 190 UUIDs. Only counts were
retained publicly. Unchanged metadata does not exclude a read/retry loop. One bounded second
of service log metadata included repeated `ColorSyncProfileCreateDeviceProfile` calls;
this does not identify the calling client or prove the cost of those calls. A later bounded
query attributed every service event to the Apple service itself, with zero activity and
parent-activity IDs and only its own binary in the single-frame log backtrace. Those records
cannot establish an external requester. Log-tool predicate echoes are excluded from counts.

The recent WindowServer report is a CPU-usage Microstackshots diagnostic from this boot,
not an established crash or hang. It continues to refuse admission. The existing cutoff
`min(boot, now − 24 hours)` keeps every post-boot report relevant throughout that boot.
New native/Python fixtures prevent interpreting passage of time as recovery.

Read-only protected-service sampling could not proceed: the unprivileged attempt was denied
and noninteractive elevated sampling required authorization unavailable to this task. A later
supported Activity Monitor Inspector sample succeeded without an authorization change; the
service-only reports were retained privately, as described below. The first numeric admission
check for a small UUID timing probe refused before any call ran.
A later guarded, non-mutating run completed ten lookups, one second apart; the maximum latency
was 1.606 ms. Combined CPU was 30.81% before and 30.59% / 30.57% during the probe, with normal
pressure and no swap. This weakens a lookup-cost hypothesis for that interval; it does not
attribute the residual load or qualify display mutation. Historical diagnostic checks were
not part of this numeric guard, and the known diagnostic remains relevant to live admission.

### Escalation and protected-service samples

A later full host check measured 71.96% combined ColorSync CPU, with normal pressure, no swap
activity, the same current-boot diagnostic and no detected service timeouts. Doctor reported
zero SpaceO and orphan displays. Stopping the idle 1.0.7 daemon normally did not relieve the
load: a numeric-only observation measured 69.94% (41.45% display services and 28.49% colorsyncd),
with the daemon stopped and no SpaceO displays. That numeric observation deliberately excluded
historical diagnostics for attribution; it is not a live-admission result.

Activity Monitor's supported Inspector → Sample control captured both root-owned ColorSync
services and WindowServer without changing permissions. Only function names and aggregate
observations are recorded here; raw reports remain private. The display-services XPC worker
enters `ColorSyncProfileCreateDeviceProfile`, device-registration lookups and
`ColorSyncDeviceRegistryCopyInfo`, then parses binary property lists or waits for synchronous
registry replies. The colorsyncd XPC worker also spends sampled time decoding binary property
lists. WindowServer's main timer pass enters `WS::Displays::CAWSManager::restore_color_preferences()`
and waits on a semaphore; eight sampled worker threads execute its restoration block through
`ColorSyncXPCAcquireDisplayInfo` and synchronous XPC waits. A separate one-second user-agent
sample was idle in its Mach-message wait.

These observations establish an active WindowServer color-restoration / ColorSync profile and
registry bottleneck. They do not establish request frequency, the responsible device or
profile, malformed data, or accumulated registry entries as the cause. Recursive property-list
frames are ordinary deserialization and cannot prove an infinite loop. The observations were
sequential samples, not a trace linking individual requests across processes. No service was
killed and no profile, preference, diagnostic or safety record was modified.

After Activity Monitor quit normally, a full five-second host check still measured 68.69%
combined ColorSync CPU. It also detected memory pressure and four swap-ins; no service timeout
was detected. Further host probes stopped at that refusal. This observation does not attribute
the pressure to sampling or to ColorSync. The existing incident is not repaired by the
settling guard, and no new live workload or release qualification is claimed.

## Decision and implementation

The [primary XREAL investigation](https://github.com/dripster82/ar_workspace_manager_for_xreal/blob/main/Docs/ColorSync-AirII-investigation.md)
reproduced runaway behavior with stable identities and a clean registry, and observed its
escalations after reconfiguration while ColorSync was already busy. This weakens the earlier
profile-accumulation hypothesis as a complete explanation. It supports a conservative
settle-before-reconfiguration guard; it does not prove an identical Apple defect on this Mac.
Randomized identities remain unchanged because stable reuse previously restored an inactive
display without a managed Space.

The existing native monitor now distinguishes ongoing health from reconfiguration readiness.
Two distinct, consecutive assessed CPU intervals must be strictly below 25%. A graph change
resets readiness; both endpoints of subsequent qualifying intervals must follow that change.
Repeated report reads and late pre-change observations cannot satisfy it. The existing 50%
hard limit, diagnostic detection, swap/pressure checks, sampling deadlines and sticky faults
remain unchanged. Waiting on the existing sampler adds no service or display queries.

Creation waits outside the lifecycle worker within its existing 15-second health budget,
then rechecks readiness before admitting mutation. Retirement checks readiness before marking
the Stage invalid, within a default 30-second total budget, reserving ten seconds for removal.
Shorter explicit deadlines require already-settled evidence rather than waiting. A bulk retirement shares one
25-second deadline and stops after its first deferral, reporting every remaining owner. A settling
refusal retains a valid backing; a pool can reuse that live display without reconfiguration.
Deinitialization transfers its backing to the coordinator before scheduling cleanup; pending
or deferred owner IDs remain visible in safety and shutdown reports and refuse new creation.
Verified retirement clears that record. It retains its backing if readiness cannot be established. Settling-only refusals
remain transient even when detected in the lifecycle worker; hard health faults remain sticky.
A failed publication, or another post-attachment creation failure, retains and reports its
unpublished backing and ID while preserving the hard failure reason, rather
than automatically reconfiguring a graph whose post-attachment settling is unknown.
Health JSON exposes readiness and its threshold separately from ongoing-use health.
Admission is rechecked after the acknowledged pending-marker write, including retirement's
remaining removal budget. A transient refusal at that point clears the no-mutation marker
only after a successful durable acknowledgment; failed acknowledgment remains sticky. Final
creation admission shares the deferred-owner registration lock and runs immediately before
attachment, without holding that lock across filesystem work or private display IPC. Doctor
includes the daemon's deferred owners even when its pool is empty, reports them explicitly,
and does not offer orphan-display recovery for those owned displays. Settling waits now use
one absolute monotonic DispatchTime deadline and separate semaphores for concurrent callers,
so wall-clock changes cannot extend their deadline or lose a wakeup.
Creation attempts remain conservatively counted in the pool, including failed factories: a
factory may already have attached a display before throwing. Refused cleanup can still appear
as incomplete teardown even when the safety circuit has not tripped. Forced process exit is
outside the cleanup gate; multi-display normal stop may require retries.

## Verification and remaining work

Two independent review rounds identified and corrected removal-budget, transient-refusal,
single-display lease-budget and fallback-owner visibility problems. The integrated focused
run passed 99 tests, including completed asynchronous fallback branches, visibility during a
blocked readiness wait, owner release after verified cleanup, codec compatibility, and repeated
retirement without another graph change. The preceding full gate passed 1,789 deterministic
Swift tests and MCP smoke, and the release warnings-as-errors build passed. The integrated full gate passed 1,797 deterministic tests, script/installation checks and MCP
smoke. A third independent review found no blockers and identified one remaining retained
unpublished-owner reporting gap. That gap now uses the same attachment record, including other
post-attachment creation failures; its fixture verifies the ID does not mask the hard reason.
The final gate passed after that change: 1,797 deterministic Swift tests, installation/script
checks and MCP smoke across 35 tools. There were no skipped tests in the safe suite. The final
release warnings-as-errors build passed on the same source. Python host-health
fixtures passed 21 tests; release-security and live-gate policy scripts passed.
A subsequent automated review identified the post-marker admission races, incomplete doctor
inventory and wall-clock wait. The fixes passed independent read-only review and 124 focused
tests, including real-journal abort acknowledgment, actual fallback registration, remaining
budget exhaustion, concurrent wakeups, monotonic timeout and fake-daemon doctor JSON.
The updated full deterministic gate passed 1,809 Swift tests, script checks and MCP smoke
across 35 tools. The updated release warnings-as-errors build, release-security policy tests
and live-test gate policy tests also passed.
No display mutation or input workload has run in this follow-up. The installed release remains
1.0.7; these source changes have not been installed or published. Full live/matrix and exact
signed-artifact behavior qualification remain required. This host still has a current-boot
diagnostic and an elevated physical-only baseline; no report was deleted or acknowledged,
and no latch, creation budget, system service or security setting was reset.

The pinned Xcode 26.3/Swift 6.2 toolchain is absent. Apple's official download requires an
Apple-account sign-in unavailable in the current browser session. The existing local tools
are Xcode 27.0/Swift 6.4; local checks must retain that provenance.
