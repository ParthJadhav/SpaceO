# SpaceO 1.0.6

This update fixes the issues reported in #29, #30, #34 and #36.

- On-demand ColorSync services no longer make host health unknown simply because they are not
  running, provided launchd confirms a supported idle state and unchanged launch counts. A single
  verified new launch is charged its whole CPU total; hidden churn remains blocked. Startup gets
  enough time for two observations, and unknown results identify the unavailable input. Memory
  pressure, swapping, incidents and service exits/restarts still refuse work.
- `spaceo safety clear-host-health --operator` can clear the old false-unknown latch after all
  SpaceO owners are stopped. It verifies current host health, preserves creation budgets and
  archives the old journal. It cannot clear pending work or other failures. Follow
  [display-safety recovery](DISPLAY_SAFETY.md#recovery-and-requalification).
- Native `cmd+a` selects text through Accessibility when supported. `type --replace` and typing
  into that selection edit the selected text and verify the result. Unsupported native replacement
  refuses before typing; an unconfirmed edit must not be retried blindly.
- Screenshot file output creates missing parent directories and names the directory if it fails.
- `doctor --fix` names the daemon's reported permission target, including a launchd executable,
  instead of telling users to enable the terminal running doctor.

## Validation and limits

Deterministic regression tests cover verified idle/new/running ColorSync services, hidden
launch-count changes, unknown inputs,
sticky health failures, recovery owner exclusion and budget preservation, native selection and
Unicode edits, refused/ignored writes, web/wrong-window exclusion, and screenshot output paths.
The source release gates, hosted CI and signed-distribution verification are required separately.

This is an owner-directed maintenance release with a qualification exception. The owner requested
these fixes, a new release, deployment and user replies on October 3, 2026. This Mac's read-only
admission check refused `recent_windowserver_diagnostic`, so no live display/input workload was
run. The full live suite, computer-use matrix and exact-artifact Viewer/input behavior have not
been newly qualified. The WindowServer/ColorSync freeze (RA-057) remains unresolved; this update
is not a fix or safety qualification for that incident. Runtime refusal and owner retention remain
active. No failed admission check is bypassed.

The supported scope remains native applications and managed Chromium, with Viewer on a physical
display. Managed Electron remains refused before launch. Per-PID fallback delivery and physical
Viewer pointer/Chromium motion behavior retain the documented qualification limits. Versions
1.0.5 and 1.0.3 remain available for rollback. This release exception does not apply to future
versions. Signing, notarization, publisher/checksum verification and protected publication still
apply to the exact candidate.

The idle-service evidence approach builds on [PR #37](https://github.com/ParthJadhav/SpaceO/pull/37)
by Muness Castle. Its broader empty/inactive display and window-evacuation changes are not included.
[Issue #38](https://github.com/ParthJadhav/SpaceO/issues/38) remains open for live qualification;
long-session readiness across an on-demand service exit is not claimed.
