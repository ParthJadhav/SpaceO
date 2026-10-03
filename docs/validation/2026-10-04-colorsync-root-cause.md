# October 4 ColorSync investigation

## Evidence and causal limits

The owner requested multiple independent investigations after an experimental live run stopped
on `colorsync_busy`. That run used a temporary local build with explicit historical diagnostic,
system-timeout and swap-in admission waivers. It is modified-build evidence, not qualification
of the signed release. The temporary source changes and executables were removed afterward.

A focused create/destroy case passed, followed by four full-suite cases: adopted-browser
refusal, ambiguous-session refusal, exited-app audit, and rendered window/tile capture. Helper
CPU rose through earlier cases, from about 11% to 25%, before Chromium admission. Seven display
creation attempts occurred. The Chromium exception/launch phase did not reach XCTest output
because cleanup suspended the owner first. Independent five-second observations subsequently
measured 54.50% and 54.45% combined CPU. This does not establish Chromium as the initiating cause.

Operator recovery normally terminated only the identified suspended test owner. No forced
termination or system-service reset occurred. Its display disappeared; physical online/active
IDs and mirror membership matched the baseline, with no SpaceO/orphan displays or sessions.
The signed 1.0.6 CLI/daemon/Viewer and configured client helpers were restored. The production
failure latch and creation budgets remain retained. CPU later sampled 27.53%.

A read-only follow-up observed 27.55% CPU (16.14% display services and 11.42% colorsyncd), with
approximately 10 ms and 9 ms between counter observation and the old completion timestamp.
Another metadata-only inventory found 666 ICC files, including overlapping SpaceO/test-name
categories and seven files modified in the preceding hour. No profile contents or preferences
were changed. These observations support further investigation of accumulated display work;
they do not prove the cause of Apple's service load or the historical freeze.

## Confirmed defects and fixes

1. **CPU timestamp mismatch.** Native and Python samplers read CPU counters before final launchd
   reconciliation but timestamped after it. An asymmetric two-second delay, within the existing
   capture budget, makes true 40% CPU over 7.1 seconds appear as 55.69% over 5.1 seconds. Both
   now retain the final process-read timestamp while still requiring all subsequent identity,
   launch-count and deadline checks. Capture pacing and ten-second freshness also follow the
   observation timestamp; slow reconciliation cannot extend freshness or create an overlong
   sampling interval. The historical 54.5% event is not proven to be this defect.
2. **Idle geometry churn.** Keeping the first-created empty display discarded the geometry most
   recently used. After 1080p then 1440p tasks, recurring 1440p tasks repeatedly attached a fresh
   identity while unused 1080p remained warm. Retain the most recently emptied valid display;
   active reservations and failed retirement owners remain tracked. Duplicate releases do not
   update recency, and explicit trim still retains zero idle displays.
3. **Redundant window mutation.** Initial, settled and revealed placement could repeat the same
   position/size writes. Skip setters only after authoritative exact live bounds, matching
   window/process identity and deadline checks. Different, unreadable or late observations
   cannot become a successful no-op.
4. **Unnecessary test attachment and missing attribution.** Move the fabricated-PID browser
   lookup from the live suite to injected deterministic coverage. The live suite now contains
   15 cases, and its completeness gate still derives the count from source. Live failed-launch
   diagnostics retain only phase, structured error category and cached health state before
   cleanup; application names, document paths and provider text are excluded.

The [upstream HiDPIVirtualDisplay investigation](https://github.com/knightynite/HiDPIVirtualDisplay/releases/tag/v1.1.2)
reports profile accumulation and mirroring-specific color conversion. SpaceO already uses a
private callback queue and does not call `CGDisplayScreenSize` or permanently configure a
physical display. Its randomized serials protect against a documented stale-display failure;
no fixed serial, color-primary change, profile deletion or system reset is adopted here.

## Verification

`make verify-release` passed with 1,762 deterministic Swift tests, 20 Python host-health tests,
the remaining safe harness checks and the 35-tool MCP smoke check. Release-security and live-test
gate checks passed, as did the optimized warnings-as-errors build. Opus 5.5's second review found
no blocking issues after observation-based pacing and freshness were corrected. A new test's
one-second predicate wait initially raced XCTest's polling cadence; the test-only wait now allows
three seconds, and its runtime assertions remain driven by the injected clock. The full rerun passed.

Regression mutations reproduced the old measurement and pacing errors. Reverting idle retention
to the old policy made the repeated-geometry case create six displays instead of two; restoring
the fix passed all six pool tests. No new live run has been performed on these production fixes.
The 50% CPU threshold, current-health checks,
creation budgets, randomized identities, sticky refusal and owner retention remain enforced.
RA-057 and [#38](https://github.com/ParthJadhav/SpaceO/issues/38) remain open. Full live input and
candidate qualification remain incomplete.
