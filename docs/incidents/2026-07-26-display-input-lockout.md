# 2026-07-26 display and input lockout

## Status

Resolved. Ownerless displays were removed without deleting data or terminating the user's
application sessions. The unconditional virtual-display and focus capability blocks were removed
on 2026-07-27 after the lifecycle and input-route fixes were accepted. Bounded resource admission
and fail-closed display-graph checks were briefly reinstated and then removed again on 2026-07-30
by owner decision; the input-route and teardown fixes below remain in production.

## User-visible impact

After repeated live MCP and integration workflows, the physical screen stopped displaying usable
content and local keyboard, mouse, and trackpad input appeared unavailable. Background sessions,
audio, networking, `WindowServer`, `loginwindow`, Finder, Dock, and SystemUIServer remained alive.

## Evidence

- No live SpaceO daemon, XCTest process, or diagnostic probe owned the remaining displays.
- CoreGraphics listed only SpaceO vendor `0x1AF2` display IDs 291, 292, and 293 as active.
- The built-in and external displays were still online but inactive.
- `spaceo doctor` identified the three SpaceO displays as ownerless.
- A standalone query of the private key/typing-focus getters crashed.
- The `spaceo-2026-07-26-155746.ips` report shows malloc corruption in `GetProcessPID`, reached
  from `PIDForFocusGetter` in `SpaceOPrivate.m`.
- The `probe2-2026-07-26-155528.ips` report shows the private focus query writing outside the
  presumed `ProcessSerialNumber` output storage.
- After containment and final non-GUI verification, `doctor` reported no daemon and no online
  SpaceO displays, but physical display IDs 4 and 1 were still online and both inactive, with
  mirroring still flagged unsafe.

## Recovery

The least disruptive attempts—restoring the permanent display configuration and reactivating the
frontmost application—did not repair the graph.

A display-only sleep/wake rebuilt it:

```bash
pmset displaysleepnow
caffeinate -u -t 3
```

After the wake, display IDs 291–293 were gone and a fresh remote screenshot showed the normal
macOS lock screen. A later CoreGraphics check still reported both real displays inactive (with
the external panel asleep), so this is not recorded as full recovery until the user confirms
local display and input or the graphical login session is reset. Credentials were neither
requested nor automated.

If this happens again, stop the current run, save reachable work, and use a display sleep/wake.
If that fails, log out/in or restart the graphical session. Normal use and testing can resume
after the display graph has recovered.

## Root defects

1. Repeated virtual-display lifecycle testing left three displays registered after their owner
   exited, then the physical displays became inactive.
2. `SLPSPostEventRecordTo` can change the global WindowServer input route even though it does not
   raise the target window.
3. The project guessed the ABI of two undocumented focus getter symbols. They resolved on macOS
   27 but the declarations were incompatible and corrupted memory.
4. A capability check based only on `dlsym` presence could not detect that incompatibility.
5. Earlier verification incorrectly treated a successful private record post and focus read-back
   as proof of safety.
6. Cursor-fence and teardown fallbacks trusted `CGMainDisplayID()`. During the incident the main
   display could itself be a SpaceO virtual display, so the fallback could move the pointer or
   surviving windows deeper into the damaged graph.
7. A research probe still called the corrupting getters, and previously compiled mutating probe
   binaries could bypass Makefile-level warnings.
8. Production still resolved a separate private front-process getter with an undocumented output
   ABI, and exposed the already-proven display-poisoning origin mutation through a public method.
9. Teardown and ownerless-display checks used only the active display list. An attached phantom
   that WindowServer merely deactivated could be mistaken for a successfully removed display.

## Containment

- Removed all resolution and calls of the unsafe focus getters.
- Removed those getters from `doctor`, runtime snapshots, teardown, and input routing.
- Temporarily made both `virtual-display` and `focus-without-raise` unavailable at the lowest
  private-API boundary. Virtual-display support was subsequently restored through runtime
  discovery; the incompatible focus-record path remains removed.
- Cursor recovery and window evacuation now select an active, non-SpaceO display only. If none
  exists, they fail without warping the cursor or relocating windows.
- Removed getter calls from the capability probe and removed generated probe binaries.
- Removed the remaining private front-process lookup/call in favor of AppKit. Retained its old C
  entry point and `parkDiagonally()` only as non-mutating compatibility stubs.
- Teardown, diagnostics, and live-test baselines inventory online displays so
  inactive-but-attached SpaceO displays still fail teardown visibly.
- The temporary live-test opt-in was subsequently removed; live tests run normally.
- Updated release documentation to say stop-ship rather than advertise install readiness.

## Conditions for reopening release

> **Superseded 2026-07-30:** The owner directed removal of the product restrictions around display
> creation and live testing. The safeguards below remain the historical incident response, not
> current runtime policy. Current code reports display-graph anomalies without blocking creation,
> imposes no resource ceilings, does not install a cursor fence, and permits control of physical
> and virtual displays.

The release was reopened with these changes:

- The corrupting focus getters remain removed; route restoration is verified through public
  AppKit frontmost-application state.
- Display lifecycle changes are serialized and display-graph observations are diagnostic.
- Teardown is verified against the online display inventory.
- Cursor and window recovery only target active, non-SpaceO displays.
- Live lifecycle and input suites run in the current graphical login without a policy gate.
