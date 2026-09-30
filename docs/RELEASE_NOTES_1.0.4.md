# SpaceO 1.0.4 — Background control and reliability fixes

**Publication on hold.** These are prepared notes for an unpublished candidate. The
[September 29 freeze investigation](validation/2026-09-29-freeze-investigation.md) found
system display failures during qualification; the pending publication was canceled.

SpaceO 1.0.4 improves background Chromium rendering, tightens capture ownership checks, and
cleans up Viewer capture resources more reliably. It also makes daemon startup, diagnostics,
and client configuration handling more predictable when applications or files stop responding.

## More reliable background windows

- **Reveal applications reliably after placement.** SpaceO now checks fresh Accessibility
  visibility instead of trusting cached launch state that could leave Chrome hidden and its
  captured animation frozen. New Chrome windows start inset within their tile, and launch waits
  briefly for complete window discovery after reveal.
- **Correct retained-window owner lookup.** A Core Graphics argument mismatch could make a
  known window appear to have no owner, interrupting capture and leaving cleanup pending.
  The lookup now queries the exact window directly and validates its returned identity.
- **Check ownership before single-window capture.** Missing or mismatched ownership in a
  ScreenCaptureKit snapshot refuses capture, including for direct SDK callers.
- **Handle incomplete Accessibility responses explicitly.** Window discovery preserves macOS
  error codes, checks for count changes, and keeps busy-app retries within one shared budget.
  Unknown and duplicate window identities remain failures rather than partial success.

## Better resource cleanup and bounded waits

- Stop active Viewer capture when its model is released, stop capture that finishes starting
  after its owner disappears, and invalidate the model's repeating refresh timer.
- Bound competing daemon startup-lock waits to three seconds and cancel pending startup on
  shutdown. Restart draining, polling, and shutdown share one deadline.
- Bound configuration reads, executable fingerprints, and diagnostic subprocess output.
  Pipes, oversized files, and stalled output now produce a refusal or unknown result.

## Safer configuration and clearer diagnostics

- Preserve multiline instructions, nested arrays, and quoted table keys when updating Codex
  TOML registration. Refuse ambiguous configuration and malformed JSON server collections
  without silently replacing existing settings.
- Keep `spaceo doctor` client inspection passive by default. Use
  `spaceo doctor --probe-client-versions` when you explicitly want it to execute configured
  clients to check their versions.
- Identify the launch phase in Accessibility errors. Live test tools now check host resource
  health before starting and require changing pixels as well as Viewer frame delivery in
  animated and scrolling workloads.

## Validation and supported scope

The supported scope remains native apps and Chromium on Apple Silicon, subject to runtime
capability checks. Use Viewer on a physical display with the controlled application on a SpaceO
display. Managed Electron launches and Viewer hosted inside a SpaceO display remain unsupported.

The release source passed a six-minute combined Viewer/capture workload, including animated and
scrolling content, 404 captures, and verified cleanup. Daemon and Viewer scans each reported zero
leaked bytes, and sampled memory declined during the soak. The full 36-check MCP matrix also
passed, along with all 16 live tests without skips, on Xcode 26.3 / Swift 6.2.4.

These bounded checks do **not** establish that every intermittent Accessibility failure is
resolved or that the application is leak-free. Unknown window identity and unconfirmed input
still fail explicitly. The earlier host slowdown is not attributed to a proven SpaceO leak.

See the [release record](https://github.com/ParthJadhav/SpaceO/blob/main/docs/validation/2026-09-29-release-1.0.4.md)
for verification status, artifact qualification and retained evidence.
