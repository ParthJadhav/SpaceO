# ColorSync display identities (RA-057) — 2026-10-16

Development Mac, macOS 27.2 (26B5091g), arm64. The owner had designated it for testing. Times are
IST. Counts and rates come from the local unified log, the ColorSync profile directory and
WindowServer's display preferences. No screenshots, Accessibility content, leases or personal
data are retained here.

## Incident

During 1.0.8 qualification, live suites ran under the testing-host override, which then waived
ColorSync load. At 01:13 WindowServer's watchdog (`OS_REASON_WATCHDOG`) ended the login session:
75 WindowServer dispatch threads were blocked in `restore_color_preferences` →
`ColorSyncXPCAcquireDisplayInfo`, behind a `colorsync.displayservices` queue with up to 23 minutes of
backlog. The September 29 freeze (RA-057) had the same signature. This forced logout was caused by
the testing, not by normal use.

## Mechanism

Two factors multiply.

1. **Per-request cost grows with every identity ever seen.** For each display-info request,
   `colorsync.displayservices` parses its whole any-user device registry
   (`ColorSyncDeviceRegistryCopyInfo` → `CFPropertyListCreateWithData`), about 85 ms per parse at
   the current size, several times per request. The registry
   (`/Library/Caches/ColorSync/com.apple.colorsync.devices`) was 1,208,854 bytes with 527
   display devices, 524 of them SpaceO's. The profile directory held 766 profiles, 763 of them
   SpaceO's by their `mmod` make-and-model tag. WindowServer's display preferences held 1,051
   display UUIDs. macOS removes none of these. SpaceO gave every attachment a new random serial,
   so each attachment added a permanent entry.
2. **Each attachment adds a poll that lasts until logout.** WindowServer sends ColorSync two
   requests every 5.05 seconds for every display attached since login, including displays that
   are already gone. One such train is a *unit* of 0.396 requests per second.

## Controlled experiment

A throwaway daemon built from this change ran under the testing override with nobody at the
Mac. Each lifecycle created one 1920x1080 HiDPI display, destroyed the session, trimmed the pool,
confirmed that only the built-in display remained, and stopped the daemon.

| Interval (after login at about 01:17) | Requests per second | Units |
| --- | --- | --- |
| 01:20–02:12, no SpaceO display created since login | 0.395–0.397 | 1.00 (built-in display) |
| 02:13:30–02:18:22, after lifecycle 1 | 0.795 | 2.01 |
| 02:19:00–02:24:05, after lifecycle 2 | 1.184 | 2.99 |

- Lifecycle 1 used slot 0's deterministic serial, 2787227682. It added one profile (766 → 767),
  2,373 registry bytes and 2 WindowServer UUID entries. A new train started at 02:12:49.8, the
  moment of attachment.
- Lifecycle 2 got the **same serial** from a new daemon process. The profile count (767),
  registry size and modification time (02:12:49) and WindowServer UUID count were unchanged. A
  new train still started, at 02:18:42.1.

Conclusions:

- Bounded identities stop the permanent registry, profile and mapping growth, so the cost of each
  request stops rising.
- The poll leak is **per attachment**, not per identity, and macOS ends it only at logout. SpaceO
  cannot remove it. SpaceO can bound how often it attaches (daily creation budget, idle display
  reuse) and refuse to attach while ColorSync is measurably busy. The testing override no longer
  waives that refusal.
- On this Mac, at the current registry size, one unit costs about 3% of a core, so about seven
  attachments since login reach the 25% settling threshold. Cleaning the registry cuts the cost
  per request roughly in proportion to its size.

The read-only `spaceo safety clean-display-identities --operator` listed 525 SpaceO registrations
(the earlier 524 plus this experiment's one) and 763 SpaceO profiles in 24 seconds. Applying it
needs the owner's `sudo`. It was not run here, so the effect of removal on this Mac is not yet
measured.

## Prior art

Other virtual-display projects report the same per-identity leak and the same fix:

- stable per-slot serials, with a bumped identity for a poisoned one;
- unregistering dead ColorSync devices as root, because a non-root `ColorSyncUnregisterDevice`
  reports success without removing anything.

## Status

RA-057 remains open until the owner applies the cleanup, logs back in, and a normal-admission live
run on the cleaned host is retained.
