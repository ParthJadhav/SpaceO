# WindowServer watchdog and display-driver panic — October 4

## Evidence and timing

The operator supplied `panic-full-2026-10-04-211305.0002.panic`. The original remains private.
This record retains diagnostic categories and timing, without process inventory, addresses,
device identifiers, screenshots or application content. The report describes macOS 27.2
build `26B5091g`.

| Local time (UTC+05:30) | Observation |
| --- | --- |
| 20:22:00 | The supervised signed-source performance daemon started. |
| 20:27:32 | The workload had failed on AX window paging; cleanup and physical topology restoration were verified. |
| 20:27:47 | The workload's private daemon acknowledged normal shutdown. |
| 20:31:52 | The installed daemon log contains a successful ping. This is not a display-mutation record. |
| 20:40:08 | A WindowServer watchdog report says its main thread was unresponsive, with 40 seconds since the last successful check-in. |
| 20:40:19 | The panic's kernel Calendar field records the panic. The panicked WindowServer instance had only about 10.5 seconds of uptime. |
| 20:40:41 | The current kernel boot time follows the panic by about 22 seconds. |
| 21:13:05 | The supplied panic report's header/date. This is later than the kernel's recorded event time; using it as the crash time would misalign the test timeline. |

The watchdog and panic share the prior boot session. The watchdog's WindowServer main thread
was waiting on a spinlock with an unknown turnstile inheritor; this alone does not identify
the lock owner or the initiating operation. Its replacement WindowServer then panicked while
running Apple's display-driver path.

## Diagnostic finding

The panic assertion is `mismatched swapID's 1637560 vs 1637559` at
`UnifiedPipeline.cpp:18098`. The kernel backtrace includes
`com.apple.driver.AppleMobileDispT605X-DCP` and
`com.apple.iokit.IOMobileGraphicsFamily`; the panicked task is WindowServer.
This is a graphics/display-pipeline assertion. It is not evidence of a SpaceO Swift trap or
proof that memory swapping caused the crash. The report explicitly records memory pressure
as false and describes compressor limits and swap space as OK.

SpaceO processes occur in the snapshot, but their presence does not establish an active
display owner or a triggering call. The workload's private daemon had already shut down,
about 12.5 minutes before the kernel panic. The retained installed-daemon tail contains no
display mutation in that interval. That tail is not a complete audit of every client, every
system operation or physical display state at the panic instant.

## Relationship to the open incident

This supplies additional evidence of the unresolved WindowServer/display-system instability
tracked under RA-057. A relationship is plausible; a common initiating cause, delayed SpaceO
effect, physical-display interaction or OS defect has not been demonstrated. The watchdog
followed by a replacement-process display-driver panic is a distinct observed sequence from
the performance workload's AX provider refusal. Do not claim the target-specific screenshot
fix remediates this kernel panic, and do not close RA-057 on the basis of a later passing test.

No system preferences, color profiles, diagnostic history, SIP or TCC settings were changed
to investigate this report. The operator's testing-host authorization remains in force.
