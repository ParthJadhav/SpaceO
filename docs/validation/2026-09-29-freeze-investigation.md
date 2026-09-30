# September 29 forced restart and display-service investigation

Status: **Live display work and 1.0.4 publication held. The underlying system failure remains unresolved.**

The owner reported a stuck laptop during release testing and confirmed forcing the restart.
They do not know when the final freeze began or whether the pointer still moved. The boot
record places the restart at 23:03:03 IST on September 29. All times below are local IST.
The evidence establishes display-service stalls, but not the precise trigger or onset of the
final freeze. This finding supersedes the earlier source-qualification claim in the
[1.0.4 record](2026-09-29-release-1.0.4.md).

## Timeline and confirmed evidence

| Time | Evidence | What it establishes |
|---|---|---|
| 18:00 | Read-only health check: 99.95% combined ColorSync CPU, normal pressure, no sampled swap | The earlier slowdown persisted after the idle SpaceO daemon was stopped. |
| 20:26–20:28 | WindowServer fence/synchronization timeouts and a WATCHDOG diagnostic | WindowServer missed its main-thread check-in for 40 seconds, before the later release qualification. This is a watchdog diagnostic, not proof of a process crash or automatic restart. |
| 20:28 | Retained 5.52-second system spin report | 75 of 98 sampled WindowServer threads had ColorSync frames and waits on `colorsync.displayservices`. Its dispatch soft limit of 75 was exceeded throughout the 12 samples. The main thread was waiting synchronously; footprint was about 1.06 GB. |
| 21:58–22:05 | Combined daemon/Viewer workload passed its assertions and cleanup | Bounded application memory evidence exists, but simultaneous system errors prevent treating it as a clean host qualification. |
| 21:59–22:30 | Complete bounded unified-log query | 34 display-reconfiguration synchronization timeouts and six additional `synchronize timed out` messages occurred in this interval, including during the performance, MCP and live XCTest work. |
| 22:06:38–22:31:09 | Supervised XCTest transcript | All 16 case assertions passed, without skips. The harness did not check OS health between cases. |
| 22:31:07–22:31:29 | WindowServer logs | Display reconfiguration clients missed synchronization deadlines around final teardown; repeated synchronization timeouts continued afterward. The unresponsive client is not identified. |
| After 22:31 | Doctor and health samples | Original physical-only topology, no daemon, lifecycle `ready`; ColorSync still at 69.71%, then 68.87% in a longer sample. Further live work stopped at this point. |
| 23:03:03 | New boot record and owner's account | Forced restart. The retained logs do not identify the final freeze's onset. |
| After restart | Passive process/memory snapshot and health sample | No SpaceO processes, normal pressure, zero allocated swap; combined ColorSync CPU sampled at 4.16%. This is an observation after restart, not permission to resume. |

The spin report shows the ColorSync display-service queue busy and waiting through
`colorsyncd`. The WindowServer footprint alone does not establish a memory leak. Its very low
CPU consumption in that sample is consistent with blocked threads. This resembles the earlier
[RA-055 incident](../../RELEASE_AUDIT.md#ra-055--september-25-colorsyncwindowserver-stall-and-display-driver-panic),
but does not prove the same initiating call or the same failure at 23:03.

## Memory, disk activity and persistent display state

The 367.875-second combined workload retained 365 daemon and 317 Viewer resource samples.
Daemon footprint peaked at 30.344 MiB and ended at 13.438 MiB. Viewer peaked at 83.657 MiB and
ended at 59.782 MiB before exit. Separate exercised-process scans each reported zero leaks
and zero leaked bytes. These bounded observations do not support a growing daemon/Viewer leak
as the demonstrated cause, and do not rule out longer-lived leaks or system-service problems.

Other resource diagnostics recorded approximately 8.59 GB of file-backed memory dirtied by
the coding client over 1,986 seconds, and 2.15 GB by Chrome over 2,771 seconds, before the final
live suite. They describe write activity, not SpaceO heap leaks; no resource action was taken.
This is additional workload, not an established explanation for the freeze.

The read-only profile inventory found 664 ICC files, including 521 named for SpaceO displays
and 115 with test names. Nineteen profile files were modified during the final suite. The
SpaceO-named files accumulated over weeks, not just this run. The system WindowServer
preferences also contained a mapping collection with 893 entries. Roughly 993 display-info
requests were logged in the first 100 seconds of the 22:30 query, largely continuing with
physical-only replies after cleanup. Persistent identity/profile churn is a plausible
contributor to repeated ColorSync work, not a proven cause. No profiles or preferences were
deleted or changed, and random display identities were not replaced with previously unsafe
fixed identities.

An upstream virtual-display maintainer reports a similar ColorSync failure involving random
serial numbers and accumulated profiles, alongside mirroring-specific color conversion and
callback/configuration issues. This is supporting precedent, not proof that the same cause
applies here. SpaceO already uses a dedicated callback queue and does not call
`CGDisplayScreenSize`; its prior stale-identity failure also makes blindly adopting a fixed
serial unsafe. See [HiDPIVirtualDisplay 1.1.2](https://github.com/knightynite/HiDPIVirtualDisplay/releases/tag/v1.1.2).
The local system ColorSync device cache was unreadable at current privileges, so its contents
and entry count remain unknown. No cache cleanup or service-disabling workaround was attempted.

## Coverage and limits

Reviewed evidence includes system and user diagnostic inventories, the retained WindowServer
watchdog/spin, relevant resource reports, boot history, WindowServer/ColorSync/watchdog/kernel
unified logs, SpaceO daemon journals, supervised XCTest logs, performance and MCP reports,
resource samplers, leak results, and display/profile metadata. The default daemon journal ended
before the later isolated test daemons; their separate journals were inspected as well.

Raw evidence stays private under `.artifacts/release-1.0.4/freeze-investigation/`. Six relevant
diagnostics were copied there with a SHA-256 manifest. Raw reports, process paths, application
content, and diagnostic identities are excluded from this public record.

The initial broad 22:30–23:05 query reached its 8 MiB cap after about 100 seconds of log time;
it is partial. Narrower error and watchdog queries completed. The 21:55–22:30 and 20:20–20:35
queries also completed. Watchdog records continue through 23:02, but their messages are
privacy-redacted; they cannot establish WindowServer responsiveness. No corresponding kernel
panic or GPU reset was identified in the retained pre-restart evidence. Absence of a report
after a forced restart is not proof that no other system failure occurred.

## Containment and gate correction

The original preflight sampled only current CPU, memory pressure and swap. It missed the
20:28 watchdog because counters later looked quiet. XCTest then admitted the entire long run
after that single check; successful display retirement and assertions were insufficient to
detect system-service degradation. The earlier watchdog history should have been inspected
before testing resumed.

The follow-up changes the read-only gate to inspect bounded WindowServer diagnostic metadata
from the current boot or the last 24 hours, whichever is longer, including retained reports.
Recent reports refuse admission even after reboot; unavailable metadata also refuses. This
is a conservative warning, not a diagnosis or an automatic clearance after 24 hours.

Live XCTest now requires the health helper after each pacing interval, before display work,
and after verified cleanup. A health failure stops later cases and fails qualification.
Unverified cleanup still retains/suspends its owner; a health failure after verified cleanup
does not. The wrapper supplies the helper and requires a final passing health check even when
all XCTest assertions pass. Deterministic fixtures exercise these paths without live displays.
These changes prevent the identified admission gap; they do not fix Apple's display services.

Offline verification passed `make verify-release`: 1,686 Swift tests, the supporting
Python/shell/JavaScript checks, and all 34 MCP smoke tools. The new health tests use metadata and
process fixtures. Release security tests, live-gate fixtures, the warnings-as-errors release
build, public-file privacy checks and `git diff --check` also passed. Swift builds used two jobs.
A read-only run on this Mac then refused admission for two recent diagnostic
reports despite normal pressure, zero swap deltas and 4.15% ColorSync CPU. No live display or
input test was run after the restart.

The pending 1.0.4 publication workflow was canceled. Its signed candidate and immutable tag
are not altered or described as qualified. No further live display work is authorized by a
quiet sample alone: investigate the system failure and review host recovery and workload scope
before a new reserved-host qualification. Do not reset ColorSync, delete profiles, kill
WindowServer, or clear safety state as a substitute for that investigation.

## September 30 source prevention changes

The native production path now establishes host health before Stage creation and continuously
samples content-free memory, swap, ColorSync CPU and WindowServer diagnostic metadata. One
sampler and a separate watchdog refuse unhealthy, unknown or stale observations. Refusal trips
the existing persistent lifecycle circuit and retains display owners. Commands, automatic
cleanup, window-watcher sweeps and wake revalidation stop admitting further work. Inventory
remains available without refreshing window Spaces or claiming live geometry while blocked.
Calls already inside macOS remain outside the guard's ability to cancel.

The daemon now keeps one idle display for reuse, trims excess idle displays after the existing
grace, and requires exact dimensions when reusing an exclusive display. CLI/MCP idle-only trim
provides explicit cleanup without ending active sessions. A 32-attempt rolling daily creation
budget persists across restarts, alongside the shorter budgets. Fresh randomized identities
remain in place; stale fixed identities are not restored and existing profiles are untouched.
The daily limit bounds churn, not cumulative lifetime profile count or Apple's internal work.

All live harnesses now require final system-health evidence. A bounded unified-log query counts
WindowServer/ColorSync timeout messages during the entire workload; a matching timeout or
unavailable evidence fails qualification. The query emits no log content. A two-second read-only
format check on this Mac returned valid evidence with zero matching messages; it is not live
qualification or evidence of recovery.

No display creation, app launch, synthesized input, host installation, safety-state reset or
publication was performed for these changes. The affected Mac stays excluded from live stress
testing. Root-cause resolution and qualification of a newly built candidate on a separately
reserved test Mac remain required. Neither the immutable 1.0.4 tag nor its signed artifact
contains this follow-up.

Final offline verification passed `make verify-release`: **1,701 Swift tests**, supporting
Python/shell/JavaScript checks, and the **35-tool MCP smoke test**. Release-security and live-gate
fixtures, the warnings-as-errors release build, public-file privacy checks, and `git diff --check`
also passed. Swift compilation used two jobs with the retained Xcode 26.3/Swift 6.2.4 toolchain.
Private logs are retained under `.artifacts/freeze-prevention-2026-09-30/`. These results cover
the guard's refusal, stale/stuck sampler and late-result behavior, bounded helper/metadata reads,
idle reuse and trim, blocked inventory, and daily-budget restart persistence. They contain no
new claim of system recovery, live compatibility, or leak-free operation on the affected host.
