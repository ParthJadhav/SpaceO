# SpaceO 1.0.5 — Host-health safeguards and display reuse

**Known limitation:** the WindowServer/ColorSync freeze reported during sustained testing is
still unresolved. This release adds safeguards to reduce exposure; it is not a verified fix for
the macOS stall. Version 1.0.5 is published by release-owner direction with an explicit exception
for missing new live qualification. Do not treat passing source tests or notarization as proof
that sustained display use is safe on your Mac.

## What changes

- **Watch host health during display use.** SpaceO checks memory pressure, swap activity,
  combined ColorSync CPU use and recent WindowServer incident reports before creating a display,
  then continues monitoring. Unhealthy, unavailable or stale observations stop admission to
  further work. The failure persists across daemon restarts.
- **Retain display owners after a health failure.** Active commands, automatic cleanup and
  background window placement stop admitting work. SpaceO keeps the owner alive rather than
  triggering more display changes. Diagnostic inventory remains available without refreshing
  window Spaces or claiming live geometry. Calls already inside macOS cannot be canceled.
- **Reuse a display between tasks.** The daemon keeps one idle display and retires excess idle
  displays after a short grace. Exclusive reuse now requires matching width and height, fixing
  reuse of differently shaped displays with the same pixel count.
- **Make idle cleanup explicit.** `spaceo pool trim --operator`, or MCP `spaceo_pool_trim` with
  `operator: true`, retires idle displays while preserving active sessions. An idle display still
  consumes framebuffer memory and appears in macOS display settings until it is retired.
- **Bound display creation across restarts.** The existing limits of four attempts per minute
  and twelve per ten minutes now include a limit of **32 attempts per rolling day**. Reusing an
  existing display does not consume another creation attempt. Failure responses report the
  remaining wait; unrestricted resource mode does not bypass these limits.
- **Reject misleading qualification results.** XCTest, MCP and performance runs require final
  host-health evidence and check for WindowServer/ColorSync timeouts over the entire workload.
  A functional pass with unhealthy or unavailable system evidence fails qualification.

## Also included since the last public release

Version 1.0.4 was not published. Its source improvements are included here: corrected window-owner
lookup, stricter single-window capture ownership, fresh application visibility checks for
background Chromium, Viewer capture/timer cleanup, bounded daemon startup and diagnostic reads,
and more careful MCP configuration updates. These changes do not establish a leak-free or
freeze-free application.

## Validation and scope

The safeguard source passed **1,701 deterministic Swift tests**, the **35-tool MCP smoke test**,
release-security and live-gate fixtures, public-file privacy checks, and a warnings-as-errors
release build using Xcode 26.3 / Swift 6.2.4. Release packaging independently checks Developer ID
signatures, notarization, staples, checksums, publisher identity and Gatekeeper for the exact
artifact. The protected publication workflow publishes those same verified bytes.

**There is no new live qualification of 1.0.5.** Earlier 1.0.4 functional passes and point-in-time
zero-leak scans were followed by system-service failures and do not qualify this version.
RA-057 remains open. Dedicated-Mac investigation and qualification are still needed, and the
affected daily-use Mac remains excluded from live stress testing.

Distribution remains Apple Silicon only, targeting macOS 14 or later subject to runtime checks.
The supported application scope remains native apps and Chromium. Use Viewer on a physical
display; managed Electron launches and Viewer hosted inside a SpaceO display remain unsupported.
Private-API availability does not guarantee compatibility with a particular macOS build.

If SpaceO refuses work or the Mac slows down, stop the workload and inspect the health evidence.
Do not repeatedly restart to clear the refusal, delete color profiles, or kill WindowServer.
See [display-safety and recovery guidance](https://github.com/ParthJadhav/SpaceO/blob/main/docs/DISPLAY_SAFETY.md),
the [freeze investigation](https://github.com/ParthJadhav/SpaceO/blob/main/docs/validation/2026-09-29-freeze-investigation.md),
and the [release decision](https://github.com/ParthJadhav/SpaceO/blob/main/docs/RELEASE_POLICY.md#current-status).
