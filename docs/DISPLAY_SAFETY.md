# Display lifecycle containment after the September 25 panic

## Finding and limits

The investigation found a likely two-stage failure: rapid SpaceO virtual-display changes
contributed to ColorSync/WindowServer starvation; WindowServer's restart then hit Apple's
`AppleMobileDispT605X-DCP` display-pipeline assertion. Subsequent boots reproduced the assertion
without SpaceO or user processes running. The initiating private call and Apple's internal
driver defect remain unproven. This change is containment, not a fix to Apple's kernel driver.

The confirmed SpaceO defects were an ineffective cleanup deadline around synchronous IPC,
creation limits local to individual pools, continuing the live suite after failures, and
admitting a previously hazardous mirrored display configuration. A serial dispatch queue alone
neither serializes other processes nor proves that ColorSync has finished asynchronous work.

The original investigation remains a local diagnostic artifact, not committed user data. Retain
the original sysdiagnose, panic reports, and symbolicated watchdog evidence for Apple Feedback.
Do not reproduce this incident on a daily-use desktop.

## Current behavior

- The temporary macOS 27+ blanket quarantine was removed at the owner's explicit request.
  The private shim checks runtime class/symbol availability on every supported OS version.
  Version alone does not refuse creation. This restores runtime admission, not release
  qualification; the September 25 incident remains relevant and the driver defect unresolved.
- Stage also refuses missing/inactive/unreadable user displays, mirroring, refresh rates above
  120 Hz or unknown refresh, and online SpaceO displays not owned by its process. These are precautions, not claims
  that extended desktop or a lower refresh rate fixes the Apple defect.
- A per-user file lock admits one SpaceO display-owning process for that process's lifetime.
  Daemon, XCTest, and library users of Stage share the same journal. It does not coordinate old
  binaries, other users, third-party virtual-display software, or direct users of private APIs.
- A persistent budget allows at most **4 creation attempts per minute and 12 per ten minutes**.
  Budget refusals report the actual remaining wait across both windows.
  Attempts, including failures, count before creation; changing pools or restarting the process
  cannot reset the window. `SPACEO_UNRESTRICTED_RESOURCES` does not lift this safety budget.
- Before a mutation, the journal records it as pending. Success clears pending only after
  verification. Interrupted mutation, unknown removal, configuration drift, or a service timeout
  leaves a latch that prevents subsequent work and survives process restarts.
  Live cases separately persist a pending marker before their baseline or test body, including
  cases that create no display; only a successful teardown clears it.
  `spaceo doctor` reports blocked or unknown lifecycle state in text and JSON, exits nonzero,
  and includes recovery guidance. Daemon health also reports an in-memory circuit failure even
  if its journal write has not completed. Diagnostics never reset or acquire the lifecycle lease.
- Lifecycle callers wait on a bounded worker completion, rather than a deadline checked only
  after IPC returns. The underlying OS call **cannot be cancelled**. A timed-out worker and its
  display references are retained; no replacement worker or automatic mutation retry runs.
  Late results cannot publish success or trigger ARC teardown. Queries returning errors are
  unknown, never proof of removal. Cleanup uses cached Space IDs before the bounded path.
  Retirement uses one absolute total deadline, including queueing, preflight and verification.
  Allocation claims the Space IDs verified at publication and refuses a circuit-failed Stage.
  Failure persistence/logging runs separately with at most 100 ms of caller wait, so a worker
  stalled while holding the journal lock cannot also trap the timeout caller. If storage stalls,
  the failure write may remain outstanding; the already-persisted pending markers protect
  interrupted mutations and live cases.
- Display identities remain randomized. Persistent identity churn is a plausible contributor
  to ColorSync work, but blindly restoring stable IDs reintroduces a documented stale-display
  failure. The creation budget and existing pool reuse reduce exposure without that regression.

These bounds are application containment. They cannot stop a kernel panic, cancel a call already
inside Apple code, guarantee display preservation when an owner exits, or measure ColorSync's
internal backlog. Process exit still releases its virtual displays. General diagnostic queries
outside Stage's lifecycle are not all covered by its worker deadline.

## Live testing

Use a reserved host and follow [LIVE_TESTS.md](LIVE_TESTS.md). `SPACEO_LIVE_TESTS=1` is required
both by the shell wrapper and XCTest setup, before setup makes any display queries. The wrapper
rejects parallel workers; XCTest stops admitting cases after its first recorded failure and opens the persistent lifecycle
latch to refuse focused reruns. Cases
are paced by 90 seconds to avoid exhausting the shared creation budget. Pacing is not a health
certificate; lifecycle failures still stop the run.

### Deliberate testing of the incident monitor setup

On September 25 the owner reserved this Mac and explicitly requested testing with the original
mirrored Alienware 240 Hz setup. Ordinary builds still refuse that setup. A separately compiled
qualification build can waive only the mirroring/refresh admission checks (including an inactive
mirror follower). It still requires an active readable user display, rejects foreign SpaceO
displays, and keeps the journal, budget, deadlines, publication checks and failure latch.
Both environment flags and the compiler definition are required:

```sh
SPACEO_LIVE_TESTS=1 SPACEO_QUALIFY_PANIC_CONFIGURATION=1 \
  bash scripts/test.sh live --case=testStageCreateAndDestroyLeavesNoDisplay \
  -Xswiftc -DSPACEO_DISPLAY_QUALIFICATION
```

Run one lifecycle first and inspect the retained results before attempting the full suite.
This can reproduce a kernel panic; supervision cannot prevent it. Never compile a distributable
with `SPACEO_DISPLAY_QUALIFICATION`. A pass from this build records an incident experiment, not
proof that a normal release supports a configuration it refuses. Do not remove the other
protections or automatically clear the journal to continue a failed experiment.

The external supervisor retains an owner-only log. A case exceeding 180 seconds, a run exceeding
40 minutes, interruption, or excessive output suspends the owned process group and exits nonzero.
It does **not** kill a display owner automatically: killing can itself reconfigure the display
graph. The log reports the suspended process-group ID. Stop the qualification attempt and inspect
it during a reserved recovery window; do not automatically rerun or resume it. A failed, stopped,
or skipped run is never release evidence. The supervisor cannot contain a WindowServer or kernel
failure and direct `swift test` invocations do not have its external deadline.

## Recovery and requalification

The per-user journal is `~/Library/Application Support/SpaceO/display-safety.json`. A corrupt or
non-private journal fails closed. There is intentionally no automatic reset, expiry of failures,
or retry loop. Do not unlink it while any SpaceO owner is running or suspended: replacing a locked
file would defeat cross-process exclusion.

After a trip, stop further display work, retain the log and journal, and plan recovery on a
reserved host. Establish that all display-owning SpaceO processes have exited, no orphan display
remains, and physical-only display operation is stable. Owner termination may itself trigger
teardown; it is an operator recovery decision, not a watchdog action. Only then may an operator
archive/remove the journal to permit a fresh admission. That does not make the host qualified or clear any release blocker. Do not erase WindowServer/ColorSync preferences as a
routine reset.

Release qualification still requires retained evidence on a reserved machine: physical-only stability, minimal single-display lifecycle, staged topology and
refresh experiments, no service stalls or configuration drift, and then the complete live and
computer-use gates in [RELEASE_POLICY.md](RELEASE_POLICY.md). A second login still shares the
kernel and hardware. Neither deterministic tests nor an older green live run qualify this patch.

## Verification without display mutation

`DisplayLifecycleContainmentTests` inject blocked queries, blocked backing invalidation, late
creation completion, inventory errors, lease contention, restart persistence, rolling budgets,
clock rollback, and bad journal files. `DisplaySafetyTests` tests topology admission.
`LiveTestSupervisorTests.py` exercises deadlines using disposable Python processes only.
`LiveTestGateTests.sh` checks opt-in, serial execution, retained logs, and complete-run evidence.
No live display creation is needed to run these tests.
