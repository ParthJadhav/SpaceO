# Live WindowServer tests

Read [DISPLAY_SAFETY.md](DISPLAY_SAFETY.md) for the lifecycle safeguards before scheduling a
run. Do not run this suite on an actively used desktop.

`Tests/SpaceOKitTests/IntegrationTests.swift` is the only coverage SpaceO has for the claims that
define the product: Stage create/destroy, tile isolation, capture, input routing, the DevTools
bridge, and late-window containment. None of it can run on a GitHub-hosted runner — there is no
graphical login, no Accessibility or Screen Recording grant, and no support for the private
virtual-display API. The deterministic CI suite explicitly excludes it (`scripts/test.sh safe`).

That leaves a gap worth naming plainly: if `Stage.invalidate()` regressed so virtual displays were
never retired, CI would stay green, `release.sh candidate` would stay green, and the DMG would be
signed, notarized, and published. `testStageCreateAndDestroyLeavesNoDisplay` would have caught it.

## The two failure modes this setup closes

**A skipped run is not a passing run.** `swift test` exits 0 when `--filter` matches nothing, and
XCTest exits 0 when every test skips itself. Both are indistinguishable from success at the exit
code. `scripts/check-live-test-run.sh` reads the run log and fails when no test produced a result,
when any test skipped, or when fewer tests executed than the suite defines. The expected count is
derived from the suite source, so adding a live test raises the bar automatically.

**The leak assertion must be armed after admission and before a runtime prerequisite skip.** `setUpWithError` first checks opt-in, suite failure, and capabilities without display inventory.
Once admitted, it takes the display baseline *before* `XCTSkipUnless`, because that call throws. With the baseline taken after
it, `tearDownWithError`'s `guard hasDisplayBaseline else { return }` returned immediately and the
leaked-virtual-display assertion never ran — on exactly the runs where it was skipping.
`Tests/LiveTestGateTests.sh` asserts that ordering so it cannot silently regress.

## Running locally

```sh
SPACEO_LIVE_TESTS=1 make test-live        # reserved host only
SPACEO_LIVE_TESTS=1 make test-live-full   # a skip is a failure
```

Without `SPACEO_LIVE_TESTS=1`, the shell wrapper refuses and XCTest skips before querying the
display server. With opt-in, missing prerequisites still skip; `--require-full` treats these as
failure. Parallel workers are refused, cases are paced, and the first failure stops further
cases. Always use the wrapper for the external deadline and retained log described in
[DISPLAY_SAFETY.md](DISPLAY_SAFETY.md).
The wrapper builds the bundle, then supervises XCTest directly. SwiftPM's buffered output and
separate XCTest process group would otherwise hide case deadlines and evade group suspension.
The suite retains one physical-display baseline across all cases and checks it before and after
each pacing interval. A monitor change between cases invalidates the run before further display
creation; it must not silently become a passing test of a different setup.
The computer-use matrix also requires this opt-in and stops after its first failure or blocked
result, after attempting the current session's cleanup; it does not start another suite.

Both create virtual displays, launch applications, and synthesise input into the **current
graphical login**. Do not run them on a desktop you are using: synthesised keystrokes go to
whatever holds focus. Use a reserved machine and a dedicated login. Preserve unrelated state and record pre/post
display topology. Do not switch users or change displays during a run. Stop and inspect failed
or interrupted runs; do not automatically repeat them.

Check the host first:

```sh
swift run spaceo doctor
```

`can drive sessions: yes` is required, and `can capture: yes` for the capture tests. Anything less
and `--require-full` will fail, which is the intended behaviour — the run proved nothing.

For the end-to-end MCP action matrix, retain a privacy-safe structured result beside the live log:

```sh
SPACEO_LIVE_TESTS=1 SPACEO_RUN_ID=claude-round-1 \
SPACEO_LOG_METRICS=1 \
node scripts/computer-use-check.mjs .build/release/spaceo \
  --suite=all --require-full --report=.artifacts/claude-round-1/actions.json

node scripts/metrics-report.mjs ~/Library/Logs/SpaceO/daemon.log \
  --run=claude-round-1 --json > .artifacts/claude-round-1/daemon-metrics.json
```

The action report contains stable labels, outcomes, timings, and binary provenance only. Raw
failure diagnostics remain in the console log, which must be reviewed before sharing. The matrix
rejects missing tool results and failed/missing screenshot pairs; partial isolation is blocked,
not passed. Its temporary fixtures are unique to the run and removed at exit.

The structured report omits typed payloads, tool response text, screenshots, accessibility content, and controller
leases. Always confirm `spaceo doctor` reports that the running daemon matches the CLI before
interpreting a run; an installed file can be newer than the executable image already serving the
socket. A signed Viewer helper and the standalone CLI can have different SHA-256 values while still
matching by Mach-O build UUID. With `--require-full`, the matrix additionally waits through the
idle grace and fails unless every virtual display retires, no orphan remains, and the user's
online/active/mirrored topology is unchanged. Native and Chromium suites also fail
if any published app window lies outside its SpaceO tile. The preview's Electron suite verifies
pre-launch refusal and absence of published windows, not renderer support. The daemon log and action report are
created owner-only (`0600`).

## No CI job

Live runs are local only. No workflow runs this suite, and no self-hosted runner is registered
with the repository: CI and signing use disposable GitHub-hosted runners, which have no
graphical login, TCC grants, or private virtual-display support. Never register a personal
workstation for public repository jobs.

Admit only an Apple Silicon host on the pinned toolchain, and retain both checks with the run.
Run them in the same shell as the qualification commands so the exported toolchain stays active
for every build and test:

```bash
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
export SPACEO_REQUIRED_XCODE_VERSION=26.3 SPACEO_REQUIRED_SWIFT_VERSION=6.2
test "$(uname -m)" = arm64
bash scripts/check-swift-toolchain.sh
```

A successful no-skip local run on that host (`make test-live-full` and
`make computer-use-check-full`, retained privately) is still required *approval evidence* under
`docs/RELEASE_POLICY.md` — the release owner reviews it at go/no-go rather than automation
enforcing it.
