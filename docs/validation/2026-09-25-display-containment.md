# September 25 display containment experiments

This is source-level incident evidence, **not completed qualification of the incident monitor
setup or a signed distribution**. The temporary macOS 27+ version quarantine is removed;
normal builds retain the display-configuration and lifecycle checks in
[DISPLAY_SAFETY.md](../DISPLAY_SAFETY.md). Apple's driver defect remains unresolved.
The complete follow-up source experiment passed on [September 26](2026-09-26-display-containment.md).

## Host and authorization

The owner reserved the existing desktop and expressly requested the original panic setup:
Mac17,9 / M5 Pro, macOS 27.2 build 26B5091g, Alienware AW3225QF at 240 Hz with the built-in
display mirrored. The local toolchain was Xcode 26.6 / Swift 6.4. Tests used a separately
compiled `SPACEO_DISPLAY_QUALIFICATION` build with both explicit runtime opt-ins, retaining
the deadlines, journal, creation budget, publication checks and failure stop.

Times below are IST on September 25, 2026.

## Results and limits

| Experiment | Result | Limit |
|---|---|---|
| Single display lifecycle, 01:55–01:56 | Passed; no virtual display remained and the mirrored topology was preserved | One cycle cannot establish kernel-panic prevention |
| Full XCTest suite, 01:58:54–02:23:34 | 16 passed, 0 failed, 0 skipped; 1,480 seconds | Physical configuration changed before the final case's display work; not a complete pass on the requested topology |
| Two TextEdit sessions in their own tiles | Passed on the mirrored external setup | This had failed before the original incident; a pass supports containment, not a definitive Apple root cause |
| Late-window containment | Passed on built-in display only | External monitor was already disconnected, so the earlier failure is not requalified on its original topology |
| Full MCP matrix, 02:25–02:26 | 34/34 steps, no failed/blocked/skipped result; 42 tool calls; isolated daemon stopped after zero sessions/displays and no orphan | Its preflight and postflight both show built-in display only |

The full XCTest experiment used the display/input source of `bb246e2`. The subsequent matrix
used `cc70b07`, including the persistence/timeout follow-up. Local artifacts retain source-file
hashes, binary provenance, per-case output, service samples and pre/post inventories. They are
owner-only under `.artifacts/panic-qualification-20260925/`; raw diagnostics and user data are
not committed here.

WindowServer retained PID 425 throughout these observations. No lifecycle timeout or persistent
failure was recorded, and the matrix ended with no SpaceO display or owned daemon. ColorSync
returned to idle between the paced changes. These observations do not prove that another load,
driver state or physical connection cannot reproduce the kernel assertion.

Two harness problems were identified rather than hidden by the passing case count:

- SwiftPM buffered output and launched XCTest in a different process group. The wrapper now
  supervises the discovered XCTest product directly, with unbuffered output.
- Editing the running shell wrapper shifted its input offset. XCTest and the completeness check
  returned success, but the shell subsequently exited 127. The wrapper now exits inside its
  already-parsed dispatch branch. The earlier command is not recorded as a green qualification
  command; a final run should use stable runner files.

## Physical-display change

WindowServer recorded `Display 2 hot plug 0` at **02:22:49**, then removed the mirror relationship
and disabled the external display. At that moment the final case was in its pacing interval;
the previous virtual display had retired at 02:20:32, and the final case did not create its
display until 02:23:32. The owner subsequently confirmed that they disconnected the monitor or
changed its setup. This event is therefore accounted for as an intentional setup change, not
evidence of an unexpected display-driver failure. It still invalidates qualification of the
original topology for the final case and subsequent MCP matrix.

The old suite captured a fresh physical baseline after every pacing interval, allowing this
change to go unnoticed by the per-case assertions. The follow-up preserves one physical baseline
for the entire suite and checks before and after each pacing interval. A change now invalidates
the run before another display is created. Live-case admission is also persisted before any
baseline or test work, so a failure in a case that creates no display still blocks a restart.

## Follow-up qualification

The intended mirrored Alienware 240 Hz setup was present on September 26. The follow-up source
passed the complete suite and MCP matrix without topology changes or harness errors; see the
[separate result record](2026-09-26-display-containment.md).
Do not describe the requested mirrored 240 Hz setup, the final source, or a DMG as fully qualified
from these mixed-topology experiments. Distribution additionally requires the exact signed,
notarized, stapled candidate and owner GO under [RELEASE_POLICY.md](../RELEASE_POLICY.md).
