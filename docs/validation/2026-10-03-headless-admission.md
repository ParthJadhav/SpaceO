# User-display-independent admission — 2026-10-03

Base: a858236cc3ca57653b49a244a3876f20a766bd71. This contribution removes an existing active-user-monitor prerequisite from display inventory decoding, creation admission, and global active-Space validation. It does not remove virtual-display activation, readable inventory, host-health admission, lifecycle budgets, ownership, topology preservation, or overlap checks.

## Behavior

A successful CoreGraphics inventory with zero entries is a readable empty baseline. An API error remains unknown even if its count is zero; saturated/overfull inventories, zero IDs and duplicate IDs refuse. An empty user-display graph or a readable inactive monitor can pass creation admission. An inactive monitor may report no current mode; active monitors and inconsistent/negative mode evidence still refuse. Mirroring must reference a distinct display in the captured graph.

With no active user monitor in the before snapshot, the new virtual display can be the only active display and legitimately own the global active Space. With an active user monitor, sharing its active Space still refuses. The virtual display itself still must be active, have a managed Space, avoid other online display bounds, and preserve the before/after user display graph.

Headless recovery does not invent a user-display destination. If an adopted window cannot be evacuated, the existing teardown keeps the session and display attached until authoritative window absence is observed. The added regression tests closing that window through a fake provider; no real application is closed or terminated.

## Deterministic verification

The selected display safety, lifecycle containment, host health, ownership and teardown suites passed 80 tests before the additional headless recovery regression. The final focused DisplaySafetyTests and StrandedWindowTeardownTests run passed 23 tests with no failures.

Six deliberate wrong patches were each applied in the temporary source checkout, tested separately, and restored. Every patch failed its named XCTest assertion, not a compiler error:

| Wrong patch | Named check |
| --- | --- |
| Treat successful zero-count inventory as an error | testSuccessfulEmptyInventoryIsDistinctFromErrorOverflowAndInvalidIdentity |
| Treat a provider API error as readable emptiness | testSuccessfulEmptyInventoryIsDistinctFromErrorOverflowAndInvalidIdentity |
| Ignore a foreign display owner | testCreationAdmissionAcceptsReadableHeadlessBaselines |
| Publish an inactive agent display | testHeadlessPublicationStillRequiresAnActiveOwnedDisplayAndUnchangedUserGraph |
| Ignore user topology changes | testHeadlessPublicationStillRequiresAnActiveOwnedDisplayAndUnchangedUserGraph |
| Always call the headless global Space a user Space | testHeadlessPublicationStillRequiresAnActiveOwnedDisplayAndUnchangedUserGraph |

The relevant commands are `swift test --filter 'DisplaySafetyTests|DisplayLifecycleContainmentTests|TeardownFailureTests|DisplayHostHealthTests|OwnershipAndBudgetTests'`, `swift test --filter 'DisplaySafetyTests|StrandedWindowTeardownTests'`, `git diff --check`, and `make verify-release`. `make verify-release` passed: 1,704 deterministic Swift tests with zero failures, the safe script checks, 15 Node tests with zero failures, and MCP smoke coverage of protocol, 35 tools, validation, mutation safety and clean exit. `git diff --check` passed.

## Qualification limit

This is source-level, deterministic verification on Apple Silicon, macOS 27.0, Swift 6.4. The release qualification toolchain is separately pinned upstream. No virtual display, daemon, browser or app was launched, and no live suite was counted as passed. The initial health admission helper refused this execution host because ColorSync process counters were absent. The idle-service follow-up below resolves that specific ambiguity while preserving refusal for unknown status and the independent pressure, swap and diagnostic checks. Therefore it does not establish headless rendering/input, locked-host use, or freeze prevention. Live headless qualification requires a separately eligible host and retained independent task/capture/topology evidence under docs/LIVE_TESTS.md. The unresolved WindowServer/ColorSync incident and existing release limits remain open.

## Follow-up: idle ColorSync service admission

The initial missing-counter diagnosis was incomplete: bounded launchd inspection showed both registered services were not running with `JETSAM_REASON_MEMORY_IDLE_EXIT`, zero active count, and support for pressured exit. The helper now accepts only that exact idle evidence, reconciles process visibility after the launchd reads, and requires unchanged idle launch counts across its two samples. Running peers retain CPU sampling; transitions, failure signals, ambiguous/unreadable status, memory pressure, interval swap and diagnostic history still refuse. The report explicitly counts idle services instead of fabricating their CPU counters.

The first revised read-only admission attempt recognized two idle services but refused memory pressure level 2, four swap-ins during the five-second interval, and two recent WindowServer diagnostic reports. No live workload was launched. These are point-in-time admission results, not a diagnosis of the user's Mac, and no raw service records or diagnostic filenames are retained here.

Follow-up verification passed `make verify-release`: 16 host-health unit tests, 1,704 deterministic Swift tests with zero failures, safe script checks, 15 Node tests and the 35-tool MCP smoke check. `git diff --check` passed. Live admission remains refused for the reasons recorded above.

## Native idle-state parity and attended research observations

The Swift runtime now applies the same exact idle-state evidence as the Python helper. Running services retain PID/start-time identity and monotonic CPU checks. Stable idle samples retain equal launch counts; idle/running transitions, changed launch counts, failures and unreadable/reconciliation races refuse. Four additional native tests cover these cases. No diagnostic-history exemption is included in this contribution.

A separate, temporary research patch admitted only two exact operator-reviewed historical diagnostic metadata records under a private, boot-bound, expiring manifest, while retaining current pressure/swap/new-report checks. On a normal-monitor baseline, one supervised app-free create/destroy case passed with verified display/topology restoration and passing helper postflight. A subsequent browser case refused before launch because the persisted journal recorded `host health: host_health_unknown`. The precise runtime sample causing that latch is not established; service transitions are a plausible hypothesis, not a diagnosis. The first case is lifecycle smoke evidence, not continued readiness, headless qualification or proof that the watchdog incident recovered. No journal was reset and no further SpaceO creation was attempted. Research allowance and opt-in experiments are excluded from the production patch.

Production-only final verification passed `make verify-release`: 1,708 deterministic Swift tests, 16 Python host-health tests, safe script checks, 15 Node tests and the 35-tool MCP smoke. `git diff --check` passed. The temporary research patch and tests were removed before this verification.
