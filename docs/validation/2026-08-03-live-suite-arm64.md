# Live suite run — 2026-08-03, macOS 27.0 (26A5368g), arm64

Live-test evidence in the sense of `docs/RELEASE_POLICY.md` § Live-test evidence: a full,
no-skip execution of the live WindowServer suite, retained here with its environment and
commit binding. It is not an independent artifact qualification.

## Binding

- Command: `bash scripts/test.sh live --require-full` (the `make test-live-full` target)
- Commit under test: `131821d` ("Make live-test evidence an explicit approval requirement,
  not a phantom gate"), which includes the SPAO-147 lease-authorization enforcement.
- Result: **16 executed, 16 passed, 0 failed, 0 skipped**, 64.9 seconds. The script's
  `check-live-test-run.sh` gate confirmed all 16 defined live tests ran against the real
  WindowServer.

## Environment

- macOS 27.0, build 26A5368g, Apple Silicon (arm64)
- Swift 6.4 toolchain, package language mode 5.9
- Graphical login with Accessibility and Screen Recording granted
- Run in the user's active login session while the host remained in normal use

## Notable results

- `testTwoSessionsOnOneDisplayStayInTheirOwnTiles` **passed** (17.3 s). This is the test that
  failed in the 2026-07-31 full run and gated SPAO-148's live evidence; the placement-boundary
  refusal did not reproduce in this run. SPAO-148's capture-exclusion acceptance criteria remain
  open, but the run-blocking gate did not recur.
- Display lifecycle left zero SpaceO displays; teardown checks in
  `testStageCreateAndDestroyLeavesNoDisplay`, `testDisplayIsRetiredOnlyWhenTheLastTenantLeaves`,
  and `testReleaseAllClearsOwnedSpaceBookkeeping` all passed.
- DevTools-driven Chromium web content (`testChromiumWebContentIsDrivenThroughDevTools`) and
  rendered capture (`testCaptureOfAgentScreenIsActuallyRendered`) passed.

## Findings closed by this rerun

RELEASE_AUDIT findings previously marked "Fixed; live rerun pending" — RA-015, RA-023, RA-026,
RA-032, RA-035, RA-037, RA-043 — are exercised by this suite's session-lifecycle, containment,
capture, Chromium-attach, placement, and teardown coverage; the audit table now records this run.
