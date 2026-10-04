# SpaceO 1.0.7

This update fixes ColorSync measurement timing and reduces unnecessary display work.

- CPU counters now use their actual process observation time. Slow follow-up launchd queries
  cannot shorten the measured interval and inflate CPU usage. Sampling pace and freshness also
  follow that observation, while service identity, launch-count and deadline checks remain required.
- Keep the most recently used valid idle display when task sizes change, reducing repeated display
  creation. Skip repeated window-position/size writes only when exact live geometry already matches
  and identity/deadline checks pass.
- Retain content-free launch failure phase and error category before live cleanup can suspend a
  test. Move an app-free browser refusal check to deterministic coverage, avoiding a live display cycle.
- Strengthen native live-test postflight and regression coverage for window cleanup and recording recovery.

## Validation and limits

The fixes passed 1,762 deterministic Swift tests, supporting Python/shell/Node checks, 35-tool MCP
smoke and an optimized warnings-as-errors build. Opus 5.5's final review found no blocking issues.
One focused native TextEdit workflow passed typed-text readback, covered isolation checks,
application ownership and display retirement. ColorSync measured 28–31%, with no new diagnostic,
timeout or swap activity. That run used private owner-authorized historical-admission/page-in
waivers and is modified-build evidence, not qualification of this signed artifact.

This is an owner-directed maintenance release with a qualification exception. On October 4,
2026, after reviewing the open ColorSync incident and the merged fixes, the owner instructed:
"Create a new release". The full live suite, Chromium/MCP action matrix and new signed-artifact
Viewer/input behavior remain incompletely qualified. The earlier 54.5% ColorSync spike and the
WindowServer freeze (RA-057) remain unresolved; this update does not claim to fix Apple's service
load or qualify the affected Mac for stress testing. Runtime health refusal, the 50% CPU limit,
creation budgets and owner retention remain enforced. No experimental waiver ships in this release.

Supported scope remains native applications and managed Chromium, with Viewer on a physical
display. Managed Electron is refused before launch. Per-PID fallback delivery and physical Viewer
pointer/Chromium motion retain the documented qualification limits. Version 1.0.6 remains available
for rollback. The exception applies only to 1.0.7; signing, notarization, publisher/checksum
verification and protected publication still apply to the exact candidate.

See the [ColorSync investigation](https://github.com/ParthJadhav/SpaceO/blob/v1.0.7/docs/validation/2026-10-04-colorsync-root-cause.md).
[Issue #38](https://github.com/ParthJadhav/SpaceO/issues/38) remains open for full live qualification.
