# Qualification test follow-up — October 4, 2026

Base: public main `3021b60cb65b1fba020bedda0fa9ec1254dcb70d`.

## Changes and contributor scope

Adopt the native live postflight readiness check and missing evacuation destination regression
from Muness Castle's [PR #37](https://github.com/ParthJadhav/SpaceO/pull/37), revision
`1c910c2942ac8dfa740d90dac519943592936ccd`. After independently verified cleanup and helper
postflight, XCTest also requires a ready native lifecycle journal and runtime health circuit.
Only the exact initial `unknown/not_sampled` report is allowed with a ready journal for cases
that never start Stage. Sampled unknown/blocked reports, extra reasons and blocked/unknown
journals still refuse. Refusal latches future work and fails qualification outside the branch
that suspends an owner whose cleanup remains unverified.

An adopted window with no verified user-display destination must retain its session, ownership
and display until authoritative window absence. The injected regression checks no move or quit,
retained ownership and slot, and successful cleanup after the fixture window closes.

The recording recovery test previously imposed a 30 ms budget on both a deliberately suspended
capture and a healthy PNG capture. One original-main run failed during competing compilation;
the unchanged isolated suite and full rerun passed. The fixture now warms PNG encoding before
capture deadlines and uses the normal production two-second budget. The blocked provider still
forces timeout, retains its lease and refuses 25 subsequent captures. Recovery waits against a
bounded two-second absolute deadline instead of a 100-attempt poll, then requires exactly one
fresh capture and a quiescent lease.

The broader empty/inactive-display changes from #37 remain pending. This follow-up changes only
tests and documentation; runtime capture parameters, display admission and host gates retain
their existing behavior. No release version or tag was changed.

## Deterministic evidence

- Final `make verify-release` passed: 1,747 Swift tests, supporting Python/shell/Node checks and
  the 35-tool MCP smoke. Local toolchain: Xcode 27 / Swift 6.4, macOS 27.2 (26B5091g), arm64.
- The focused recording, native-readiness and stranded-window suites passed 16 tests. After the
  final edits, all suites were rebuilt by the full gate; the recording suite then passed ten
  additional five-test runs in separate test processes.
- Live-test gate fixtures and whitespace checks passed. A prior port verification passed 11
  readiness/teardown tests; deliberately ignoring the lifecycle latch failed the intended
  readiness assertions. The deliberate mutation was removed before these changes were tested.
- Two read-only Opus 5.5 review rounds found no blocking source issues. The second round confirmed
  added coverage for the unused-report boundary and the bounded retirement wait. Its outstanding
  documentation link is resolved by this record.

This is deterministic source evidence, not a completed live test. The locally available bundles
both provide Xcode 27; the pinned Xcode 26.3 / Swift 6.2 live qualification toolchain is absent.
Hosted PR CI remains a separate check against the final commit.

## Authorized host update

The owner requested replacing the mismatched installation with the latest published version.
The existing 1.1.1 daemon had no live sessions or SpaceO displays and stopped cleanly. The
supported installer authenticated the signed, notarized 1.0.6 release, replaced the user CLI,
and installed Viewer at the existing system application path without launching it. A remaining
pre-upgrade MCP process was stopped after confirming no sessions; current clients can relaunch
through the updated paths. No client configuration or TCC grant was changed.

Doctor then exited zero: CLI, daemon, Viewer and all three configured MCP client executables
reported 1.0.6 and matching binary identity. Accessibility/capture capability was available,
with zero SpaceO/orphan displays and a ready lifecycle journal. The installed CLI's 35-tool MCP
smoke also passed. The prior daemon and temporary previous-CLI copy were removed.

## Live admission refusal and remaining work

After the update, the unchanged read-only helper sampled normal memory pressure, zero swap
activity and 8.05% combined ColorSync CPU. It still refused one recent WindowServer diagnostic
and nine system-service timeout messages in the preceding five-minute interval. These counts
are conservative admission evidence, not a diagnosis or attribution of their cause. A separate
bounded log classification was unavailable and adds no evidence.

No live display/input workload, topology manipulation, host-health exemption, safety reset,
profile deletion or forced owner termination followed. Diagnostic history and gates were
preserved. The WindowServer/ColorSync failure, RA-057 and [#38](https://github.com/ParthJadhav/SpaceO/issues/38)
remain open; PR #37's headless behavior and exact-artifact runtime qualification remain unproven.
Private transcripts and numeric summaries are retained outside the public record.
