# macOS 27.0 build 26A5368g arm64 qualification

## Scope

This artifact qualifies only these private surfaces on the exact tuple below:

- `virtual-display`
- `space-query`
- `per-pid-events`
- `ax-window-id`

It does **not** qualify `focus-without-raise`. SpaceO uses direct per-PID delivery without the
private focus-record transaction on this host.

## Host and source

- macOS: 27.0.0
- Darwin build: 26A5368g
- Architecture: arm64
- Hardware: Apple Silicon development Mac
- SpaceO source evidence: `TICKETS.md` SPAO-102, SPAO-103, SPAO-110
- Historical regression record: `RELEASE_AUDIT.md` rounds 6 and 7

The earlier one-display regression on this tuple created one 1,600×1,000 virtual display,
published its bounds and Space, placed Calculator and TextEdit on the display, delivered CLI and
Viewer input, captured the display, and removed the session, daemon, apps, and display. The pool
never exceeded one virtual display.

## Current verification

Verified locally on 2026-07-29 with the release build:

1. `spaceo doctor` reported all four scoped private surfaces available, Screen Recording and
   Accessibility granted, one online/active physical display, mirroring off, and no SpaceO
   displays.
2. A one-display daemon created session `qa-agent-display` on display 13 at 1,600×1,000. The
   display published bounds `(1512,0)`, Space 461, and `ownSpace=yes`.
3. Calculator launched as pid 58961 and its window 8591 moved to `(1552,40)` on the Agent display.
4. Accessibility enumerated 25 actionable Calculator controls. Pressing `7` through AX and
   delivering key `9` through the direct per-PID route changed the rendered value to `79`.
5. Window capture produced a rendered 460×816 RGBA PNG containing the expected Calculator state.
6. Isolation reported no covered breach and correctly retained unknown coverage for the key and
   text routes; it did not claim fully verified isolation.
7. Session destruction released Calculator. Daemon shutdown removed display 13. The final
   `spaceo doctor` reported no daemon, no SpaceO displays, and the physical display still
   online/active with mirroring off.

Only one virtual display was created during this verification.

## Limitations

This is an exact development-build qualification, not a compatibility claim for another macOS
version or Darwin build. The hard-coded `SLPSPostEventRecordTo` focus records remain unavailable.
An OS update fails closed until a new exact tuple is recorded.
