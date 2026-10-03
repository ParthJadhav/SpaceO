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

This is source-level, deterministic verification on Apple Silicon, macOS 27.0, Swift 6.4. The release qualification toolchain is separately pinned upstream. No virtual display, daemon, browser or app was launched, and no live suite was counted as passed. The independent health admission helper refused this execution host because required ColorSync service counters were unavailable; the contribution preserves that refusal. Therefore it does not establish headless rendering/input, locked-host use, or freeze prevention. Live headless qualification requires a separately eligible host and retained independent task/capture/topology evidence under docs/LIVE_TESTS.md. The unresolved WindowServer/ColorSync incident and existing release limits remain open.
