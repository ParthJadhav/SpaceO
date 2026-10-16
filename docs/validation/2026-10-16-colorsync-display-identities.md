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
needs the owner's `sudo`; see [host cleanup](#host-cleanup) for the result.

## Prior art

Other virtual-display projects report the same per-identity leak and the same fix:

- stable per-slot serials, with a bumped identity for a poisoned one;
- unregistering dead ColorSync devices as root, because a non-root `ColorSyncUnregisterDevice`
  reports success without removing anything.

## Host cleanup

Later on October 16 the owner granted administrator access and asked for the cleanup without
logging out. Every SpaceO process was stopped (four MCP servers and the installed 1.0.7 daemon,
with no session or display open), and the `20c507d` build was installed.

`sudo spaceo safety clean-display-identities --apply --operator --json` ran from the logged-in
session at 14:07:35 and finished at 14:08:19:

| Field | Result |
| --- | --- |
| `ok` / `verificationFailed` | true / false |
| Unregistered / remaining registrations | 525 / 0 |
| Removed / failed profiles | 763 / 0 |
| Backup | 764 files, 4.1 MB, readable only by root |

The registry shrank from 1,211,227 to 4,975 bytes, and the profile directory from 767 to 4
profiles: two for the external monitor, the built-in display's and Sidecar's, all untouched. A
second read-only listing found nothing and took 0.02 seconds instead of 24. Doctor reports
"0 of 4 display profiles are SpaceO's; ColorSync registry 4 KB; bounded".

ColorSync load over five-minute windows, from the unified log and process CPU time:

| Window | Requests | Units | displayservices | colorsyncd |
| --- | --- | --- | --- | --- |
| 14:01:59–14:06:59, before cleanup | 595 | 5.01 | 10.7% CPU, 54 ms/request | 8.0% CPU, 41 ms/request |
| 14:08:32–14:13:32, after cleanup | 0 | 0 | 0.0% | 0.0% |

The last requests came in a burst at 14:08:19 as the cleanup finished. The trains then stopped
entirely, including the one attributed to the built-in display, without a logout. So the polls
that persisted until logout depend on the stale registrations, and removing them ended the
polls in this session; logging out remains the fallback if ColorSync stays busy.

Normal admission then refused display creation with `recent_windowserver_diagnostic`: the 01:13
watchdog report was written during the current boot, which blocks normal admission until the
Mac restarts. The refusal latched the safety journal without creating a display; it was archived
through the documented operator procedure once no SpaceO process or display remained.

## Status

The cleanup is applied and verified on this Mac. RA-057 remains open until a normal-admission
live run on the cleaned host is retained, which needs the Mac to restart first.
