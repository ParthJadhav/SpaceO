# Blocked-host janitor maintenance

The timed session janitor previously retried a sticky host-health refusal every three seconds.
Repeated refusal cannot recover host health and produces recurring maintenance error messages.
The runtime loop now checks host-health admission before each pass and stops its timer after a
refusal, while retaining display owners and passive diagnostics.

The regression exercises the real runtime timer with an inert display backing. It waits for
the first refused health check, then spans a second timer interval and requires no second check,
no display invalidation, and a retained idle allocation. It does not create a virtual display,
launch an application, synthesize input, or access the clipboard.

Focused native linked regression evidence confirms refusal stops timed retries and healthy
maintenance continues. All 15 `DisplaySafetyTests` also pass using Xcode 27.0 / Swift 6.4.

The isolated patch at `ab809d86ae1b95d1f7e656851d96cacb98d54bef` passed
[CI on Xcode 26.3 / Swift 6.2](https://github.com/jimmyxu-code/SpaceO/actions/runs/38113120974),
including 1811 deterministic Swift tests, 15 Node tests, supporting Python/shell checks,
release build, Viewer bundle/signature verification, MCP smoke, and privacy checks.

The independent atomic-expiry fix was combined with this patch at
`a4e3c3e076eba121aa25a75cb9f90690c5547e43`. That revision passed local `make verify-release`
on Xcode 27.0 / Swift 6.4: 1812 deterministic Swift tests, 15 Node tests, supporting Python/shell
checks, and the 35-tool MCP smoke check. Its
[combined CI](https://github.com/jimmyxu-code/SpaceO/actions/runs/38114677652) also passed.
`git diff --check` passed. The combined run includes the fix for a pre-existing expiry race
exposed by the first Xcode 27 full run; it is not evidence that the janitor patch fixes that race.

No live qualification or underlying WindowServer/ColorSync defect fix is claimed.
Diagnostic lookback policy, lifecycle budgets, and ownership rules are unchanged.
