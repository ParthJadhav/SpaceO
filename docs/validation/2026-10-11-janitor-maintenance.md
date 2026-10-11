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
maintenance continues. Full deterministic verification is pending completion on a compatible
Xcode environment. No live qualification or underlying WindowServer/ColorSync defect fix is
claimed. Diagnostic lookback policy, lifecycle budgets, and ownership rules are unchanged.
