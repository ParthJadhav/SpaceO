# Display lifecycle safeguards

SpaceO creates and retires virtual displays through private macOS APIs whose calls cannot be
cancelled once they enter the system. These safeguards bound how often SpaceO changes the display
graph, how long a caller waits, and what happens when a change cannot be verified.

## Current behavior

- The private shim checks runtime class/symbol availability on every supported OS version; the
  OS version alone never refuses creation.
- Creation refuses missing, inactive, or unreadable user displays and online SpaceO displays not
  owned by this process. Mirrored displays and any refresh rate are admitted.
- A per-user file lock admits one SpaceO display-owning process for that process's lifetime.
  Daemon, XCTest, and library users of Stage share the same journal. It does not coordinate old
  binaries, other users, third-party virtual-display software, or direct users of private APIs.
- A persistent budget allows at most **4 creation attempts per minute, 12 per ten minutes,
  and 32 per rolling day**. Budget refusals report the actual remaining wait across all windows.
  CLI/MCP limits report the effective `maximumCreationsPerMinute` and the persistent
  `maximumCreationsPerTenMinutes` and `maximumCreationsPerDay`; stricter pool limits still apply.
  Attempts, including failures, count before creation; changing pools or restarting the process
  cannot reset the window. `SPACEO_UNRESTRICTED_RESOURCES` does not lift this safety budget.
- Before a mutation, the journal records it as pending. Success clears pending only after
  verification. Interrupted mutation, unknown removal, configuration drift, or a service timeout
  leaves a latch that prevents subsequent work and survives process restarts.
  Live cases separately persist a pending marker before their baseline or test body, including
  cases that create no display; only a successful teardown clears it.
  An assertion stops admission to later cases immediately, while the failing case can still
  retire its displays. Its failure is latched after cleanup verification. Unverified cleanup
  suspends the owner for inspection instead of allowing process exit to detach retained displays.
  `spaceo doctor` reports blocked or unknown lifecycle state in text and JSON, exits nonzero,
  and includes recovery guidance. Daemon health also reports an in-memory circuit failure even
  if its journal write has not completed. Ordinary daemon replies use a separately locked memory
  snapshot and never reopen the journal or wait for its I/O mutex. Before that process acquires
  a lifecycle lease the field is absent. Doctor inspects the journal on one dedicated worker,
  with a one-second read deadline (plus at most 100 ms of failure bookkeeping). A busy or
  timed-out inspection reports unknown; no replacement reader or late healthy result is accepted.
  Diagnostics never reset or acquire the lifecycle lease.
- Lifecycle callers wait on a bounded worker completion, rather than a deadline checked only
  after IPC returns. The underlying OS call **cannot be cancelled**. A timed-out worker and its
  display references are retained; no replacement worker or automatic mutation retry runs.
  Late results cannot publish success or trigger ARC teardown. Queries returning errors are
  unknown, never proof of removal. Cleanup uses cached Space IDs before the bounded path.
  Retirement uses one absolute total deadline, including queueing, preflight and verification.
  Allocation claims the Space IDs verified at publication and refuses a circuit-failed Stage.
  Geometry/Space queries use their last verified snapshot while another lifecycle operation
  owns the worker, avoiding short query deadlines expiring behind healthy mutations; idle queries
  refresh the snapshot. Cleanup preflight failure retains the backing even when no invalidation
  has started, including the deinitialization fallback.
  Failure persistence/logging runs separately with at most 100 ms of caller wait, so a worker
  stalled while holding the journal lock cannot also trap the timeout caller. If storage stalls,
  the failure write may remain outstanding; the already-persisted pending markers protect
  interrupted mutations and live cases.
- Display identities remain randomized. Persistent identity churn is a plausible contributor
  to ColorSync work, but blindly restoring stable IDs reintroduces a documented stale-display
  failure. The creation budget and existing pool reuse reduce exposure without that regression.
- The daemon keeps at most one idle display after a 15-second grace, reusing it for later tasks.
  Exact width and height must match an exclusive request. Idle displays still consume framebuffer
  memory and appear in macOS display settings. Explicit `spaceo pool trim --operator` (or MCP
  `spaceo_pool_trim` with `operator: true`) retires only idle displays under the allocation lock;
  full shutdown retires every display when health and cleanup can be verified.
- Production Stage use starts a native read-only health monitor before its first display creation.
  It requires two observations about five seconds apart, normal memory pressure, no new swap,
  combined ColorSync CPU below 50%, and no recent WindowServer diagnostic reports (this boot or
  at least 24 hours). These are conservative admission thresholds, not macOS diagnostic criteria.
  On-demand ColorSync services contribute zero CPU only with verified launchd idle/never-started
  state and unchanged launch counts, reconciled with the process list. A single verified new
  launch contributes its whole lifetime CPU; hidden relaunches, exits, restarts and malformed
  or unavailable evidence remain unknown. All sampler work shares a bounded deadline.
  Unknown reports expose the unavailable input in `hostHealth.unavailableInput`.
  Initial admission waits up to 15 seconds for the two bounded observations.
  Observations continue every five seconds; a separate watchdog trips on a sampler exceeding
  three seconds or a passing result older than ten seconds. There is one sampler, no replacement
  worker, no automatic reset, and no acceptance of a late result after refusal.
  Active commands, reuse, janitor work, and retirement refuse after failure. The daemon retains
  display owners instead of exiting or attempting more graph changes. Cached diagnostics remain
  available; daemon replies and doctor JSON include `hostHealth` without report contents.
  This does not stop input or OS calls already in flight. A process killed externally still loses
  its displays. An older daemon must be replaced through the normal verified upgrade procedure
  before it gains these protections; building the source does not change the running host.

These bounds are application containment. They cannot cancel a call already inside Apple code, guarantee display preservation when an owner exits, or measure ColorSync's
internal backlog. Process exit still releases its virtual displays. General diagnostic queries
outside Stage's lifecycle are not all covered by its worker deadline.

## Live testing

Use a reserved host and follow [LIVE_TESTS.md](LIVE_TESTS.md). `SPACEO_LIVE_TESTS=1` is required
both by the shell wrapper and XCTest setup, before setup makes any display queries. The wrapper
rejects parallel workers; XCTest stops admitting cases after its first recorded failure and opens the persistent lifecycle
latch to refuse focused reruns. Cases
are paced by 90 seconds to avoid exhausting the shared creation budget. Pacing is not a health
certificate; lifecycle failures still stop the run.

The external supervisor retains an owner-only log. A case exceeding 180 seconds, a run exceeding
40 minutes, interruption (including terminal SIGHUP), or excessive output suspends the owned
process group and exits nonzero. A focused `--case` run requires exactly one passing result for
the named method; empty filters, skips, different cases, and extra results cannot pass.
It does **not** kill a display owner automatically: killing can itself reconfigure the display
graph. The log reports the suspended process-group ID. Stop the qualification attempt and inspect
it during a reserved recovery window; do not automatically rerun or resume it. A failed, stopped,
or skipped run is never release evidence. Direct `swift test` invocations do not have its external deadline.

## Recovery and requalification

The per-user journal is `~/Library/Application Support/SpaceO/display-safety.json`. A corrupt or
non-private journal fails closed. There is intentionally no automatic reset, expiry of failures,
or retry loop. Do not unlink it while any SpaceO owner is running or suspended: replacing a locked
file would defeat cross-process exclusion.

For the false `host health: host_health_unknown` latch produced by 1.0.5 when on-demand
ColorSync services were absent, upgrade the CLI, stop **all** SpaceO owners (including Viewer
and the supervised LaunchAgent), then run:

```sh
spaceo safety clear-host-health --operator
```

This local operator command locks the existing journal, refuses a pending mutation/live case
or any other failure class, requires no online SpaceO display and two healthy host observations,
and archives the old journal before clearing only its failure. It preserves creation budgets
and the locked file's identity. An owner that relaunches or still holds the file lock prevents
recovery; stop its supervision first. Doctor remains read-only. Memory pressure, incidents and
unknown/stale health still refuse; this command neither qualifies the host nor clears RA-057.

The LaunchAgent uses `KeepAlive`, and Viewer or MCP clients can start a daemon on demand.
Stopping one daemon PID does not stop those launchers. Quit Viewer and disconnect MCP clients,
and stop LaunchAgent supervision during the reserved recovery window. Repeated "already
listening" messages mean another daemon owns the socket; they do not authorize killing it or
removing its socket/journal. Restore the intended single daemon launcher after recovery.

After a trip, stop further display work, retain the log and journal, and plan recovery on a
reserved host. Establish that all display-owning SpaceO processes have exited, no orphan display
remains, and physical-only display operation is stable. Owner termination may itself trigger
teardown; it is an operator recovery decision, not a watchdog action. Only then may an operator
archive/remove the journal to permit a fresh admission. That does not make the host qualified or clear any release blocker. Do not erase WindowServer/ColorSync preferences as a
routine reset.

Release qualification requires the complete live and computer-use gates in
[RELEASE_POLICY.md](RELEASE_POLICY.md) for the candidate source.

## Verification without display mutation

`DisplayLifecycleContainmentTests` inject blocked queries, blocked backing invalidation, late
creation completion, inventory errors, lease contention, restart persistence, rolling budgets,
clock rollback, and bad journal files. `DisplaySafetyTests` tests display-graph admission.
`LiveTestSupervisorTests.py` exercises deadlines using disposable Python processes only.
`LiveTestGateTests.sh` checks opt-in, serial execution, retained logs, and complete-run evidence.
No live display creation is needed to run these tests.
