# Authenticated Claude + signed Viewer qualification — 2026-08-29

This record covers authenticated Claude Desktop, the SpaceO MCP server, the signed Viewer,
native AppKit, Chromium, and Cursor/Electron on macOS 27.0 (26A5406e), arm64. It binds the
observed behavior to exact artifacts and states the remaining limits; it is not a claim that a
partial macOS isolation audit proves every input route.

## Artifact and host binding

- Repository base HEAD: `2f20de3a5fa3788aaf1f5ac409017e109e3c758a`; the qualified changes
  were uncommitted, so the executable identities below bind the exact tested build.
- macOS 27.0 build 26A5406e on arm64; Swift 6.3.3; Node 24.15.0; Claude Desktop
  1.40609.0.
- Release CLI and installed CLI SHA-256:
  `7982c315b031f3e86816f9527f74459d334737ad78c83fe6d7c689e0445e380c`.
- Signed Viewer helper SHA-256:
  `32e783516a720b2e5dc8c6eef2ad9191cb9adec9f062236b7a5eee46cbe1cbe4`.
  Its hash differs because the embedded helper is code signed; both executables carry Mach-O
  build UUID `C93F202D-7B58-3246-ACC6-8C74B150BB4A`. The signed Viewer executable SHA-256 is
  `78442d185bbf7ebba30167277aac78c131e35676218892db10e029fee1a421bb`, with build UUID
  `2572E96A-C799-3A3F-B947-9CB1A7D233AD`.
- Viewer signature: Developer ID Application, team `75LRT8TRQY`, hardened runtime, bundle id
  `dev.spaceo.viewer`. Deep/strict code-sign validation and the designated requirement passed.
- Final `spaceo doctor --json`: healthy, daemon matches the CLI build UUID, daemon Accessibility
  and Screen Recording are both granted, the pool has zero sessions and zero SpaceO displays,
  and no orphaned SpaceO displays exist.

## Constraints established before testing

- Accessibility and Screen Recording belong to the process hosting the daemon. The signed Viewer
  owns the qualified daemon because a terminal-hosted daemon does not inherit the Viewer's TCC
  grants. Responses and Viewer health now report the daemon's own grants and executable identity.
- The two user displays were online and mirrored (`[2,1]`, active `[2]`) throughout final
  qualification. SpaceO's virtual display occupied a separate, non-overlapping global rectangle
  and had its own managed Space.
- Empty SpaceO displays remain reusable for a 15-second debounce after the last session, then all
  are retired. The Viewer clears its Stage selection, live stream, and input controls when that
  final display disappears.
- `verify_isolation` is intentionally partial: menu-bar owner, cursor location, and active Space
  are observed; front-process status is inferred; macOS exposes no safe getter for the complete
  key-input and text-input routes. “No covered breach” is not a full security proof.
- Same-user controller ownership is coordination, not a hostile-code boundary. The current
  resource policy is unlimited; qualification therefore measures actual memory and CPU behavior
  instead of claiming an unconfigured hard ceiling.

## Failures reproduced and fixed

1. Reusing a deterministic virtual-display serial let macOS restore a stale online-but-inactive
   display identity. Apps launched on it but stopped compositing, and raw Chrome DevTools pointer
   commands took about five seconds. Each attachment now receives a fresh nonzero hardware serial.
   The resulting display is active, non-overlapping, and owns a managed Space; Chrome click fell to
   9–20 ms and wheel actions to 48–69 ms.
2. The DevTools WebSocket inherited a 15-second discovery-session resource lifetime, and the
   structured-concurrency timeout could still wait indefinitely for Foundation's late receive.
   Discovery and long-lived WebSocket sessions are now separate. A one-shot continuation makes
   the first reply/deadline authoritative, runs socket cleanup before resuming, and retires a
   broken transport before reattachment. Focused bridge tests cover late callbacks, cleanup
   ordering, bounded deadlines, and session lifetimes.
3. Cursor could launch into its authenticated Agents/home surface while ignoring the requested
   file. SpaceO now supplies explicit private extension-development and positional-file arguments,
   then asks the authenticated per-process extension to open the file and verifies the exact
   resolved path returned by the editor. It does not install the adapter into the user's profile.
4. Calculator's accessible description hid its distinct value. AX output now composes the
   accessible name and value within one UTF-8-safe bound while continuing to suppress secure-field
   values. Claude can read the visible result semantically instead of relying only on pixels.
5. VS Code-family non-editor surfaces previously risked false-success scrolling. The semantic
   path now refuses those surfaces honestly; editor scroll and selection are read back and
   confirmed through the private adapter.
6. Shared-display capture now resolves and excludes overlapping windows belonging to neighboring
   sessions against the same ScreenCaptureKit snapshot. Unknown or recycled overlapping window
   identities fail closed. Cursor-location evidence is marked unknown when display rectangles
   overlap and therefore cannot identify one display unambiguously.
7. Per-request metrics now record bounded, payload-free latency, request CPU, RSS, physical
   footprint, warning/truncation state, isolation verdict, run id, and random trace id. MCP forwards
   correlation per request even when the Viewer owns the shared daemon. Logs and reports are
   owner-only (`0600`) and the NDJSON log rotates at 5 MB with one predecessor.
8. Display publication now refuses inactive, overlapping, spaceless, same-active-Space, or
   physical-configuration-changing attachments. Detach waits for the virtual ID to disappear and
   the user's display configuration to match its pre-detach baseline. Deterministic tests cover
   inactive mirrored followers, mode drift, last-display retirement, and the reuse-vs-old-timer
   race. Live mirrored-monitor qualification preserved display 1 at 1920 × 1080 @ 120 Hz and
   active/main display 2 at 1920 × 1080 @ 240 Hz exactly.
9. App launch now requests a hidden, non-activating start and performs the first containment sweep
   as soon as the first Accessibility window materializes, before Chromium DevTools discovery or
   startup settling. Temporary and long-lived watchers catch later windows. The strict matrix
   independently rejects any published native, Chromium, or Electron window outside its tile.
10. Viewer Control is now policy-limited to an active agent session on a SpaceO display. Physical
    displays remain view-only, and an empty display retained during the debounce cannot capture
    input through either the toolbar or its keyboard shortcut.

## Authenticated Claude Desktop qualification

Claude Desktop remained logged in and used its Local SpaceO project on `main`, with worktree mode
off and the configured bypass/Opus 5/extra-effort settings. It discovered all 17 SpaceO tools.

- Native Calculator: Claude created a SpaceO session, opened Calculator on the separate display,
  cleared persisted calculator state, entered `11 + 12 =`, and read exact semantic text
  `StaticText — Edit field · value: 23`. An independent screenshot also showed `23`. It destroyed
  the session and quit Calculator; total interactive task time was about 69 seconds.
- Concurrent-app behavior: Claude exercised Chrome and Cursor while the Viewer remained live. Web
  actions progressed through the private DevTools target, Cursor editor actions used the semantic
  adapter, and an attempted scroll on Cursor's non-editor Agents surface was correctly refused
  instead of reported as successful.
- Viewer behavior: the authenticated tasks appeared automatically, the appropriate active session
  was selected without manual repair, and the streamed tile remained scoped to SpaceO's display.
  Cleanup returned the Viewer to zero active sessions.

No Claude task edited the repository. Login survived the Viewer/daemon restarts used during
qualification.

## Final strict behavior matrix and performance

The final signed-Viewer-hosted correlated run was `release-display-safety-metrics-20260829`, using
`scripts/computer-use-check.mjs --suite=all --require-full` against the exact release CLI. Its
structured report is `/tmp/spaceo-release-20260829/release-display-safety-metrics.json`.

- **30/30 passed**, 0 failed, 0 blocked, 0 skipped; 40 MCP calls in 54.372 seconds, including the
  full idle-retirement wait and before/after display-topology gate.
- Native TextEdit: launch, exact window identity, rendered capture, scroll pixel change, disclosed
  AX clipping, honest unconfirmed coordinate click, confirmed typing, all published windows
  contained, and cleanup.
- Chromium: private DevTools attachment, DOM click, two-direction scrolling, element coordinates,
  hover, drag selection, page input, all published windows contained, and cleanup.
- Cursor/Electron: requested file opened in the actual editor, AX and capture rendered, confirmed
  editor scroll changed pixels, every published window contained, no covered isolation breach,
  and cleanup. The final pool reached zero virtual displays and the user's topology was unchanged.
- Request latency: p50 48 ms, p95 2,026 ms, max 5,466 ms; the tail is application launch.
  Click p50 was 32 ms, scroll p50 59 ms, screenshot p50 91 ms, and drag 220 ms.
- The cold correlated run grew from 25,575,424 to 40,255,488 bytes RSS while loading all three app
  control paths; max RSS was 42,188,800 bytes (40.2 MiB). Physical footprint maxed at 19,235,512
  bytes (18.3 MiB). A second complete warm run, `release-display-safety-warm2-20260829`, also
  passed 30/30 and grew only 557,056 bytes RSS and 540,672 bytes physical footprint, with max RSS
  43,565,056 bytes (41.5 MiB). Request CPU p95 was 18 ms user / 10 ms system on the warm run.
- The separate signed Viewer measured 71.7 MiB physical footprint at idle, 80.9 MiB while
  streaming a real TextEdit session, and 58.3 MiB after session destruction plus display
  retirement; its observed peak was 94.8 MiB. The framebuffer and stream allocations were
  released rather than accumulating after the display disappeared.
- Telemetry: 40 request records, 0 failed, one deliberate native-click warning, one disclosed AX
  truncation, zero covered isolation breaches, and zero invalid NDJSON lines.

The daemon log was 909,678 bytes; the final and warm reports were 8,659 and 8,650 bytes. All were
mode `0600`. A count-only
privacy scan found zero fixture strings, authorization/bearer/password/secret/token terms, or
standalone lease fields. Log keys contain operational metadata only; no typed text, screenshots,
AX content, or controller lease values are retained.

## Deterministic and release gates

- `make verify-release`: **529 safe tests passed**, 0 failed; release build and MCP smoke passed.
- The complete local XCTest run executed **545 tests**, with 16 live-environment skips and 0
  failures. The new display and Viewer policy tests were included.
- MCP smoke: protocol negotiation, all **17 tools**, argument validation, mutation safety, and
  clean exit passed.
- Focused Chromium and Electron suites passed, and the full web behavior suite passed twice
  consecutively before the final all-surface matrix.
- `git diff --check` and `make release-check` passed. The version is consistently `1.0.0` and the
  configured artifact path is `.release/1.0.0/SpaceO-1.0.0-macOS-arm64.dmg`.
- Publication was not attempted. `make release-preflight` fails closed in this shell because
  `SPACEO_CODESIGN_IDENTITY` and deliberate notarization inputs are not exported. Packaging,
  notarization, stapling, and Gatekeeper verification remain the release operator's final gate.

## Final state and verdict

The signed Viewer is connected and idle. The matching permissioned daemon has zero sessions and
zero SpaceO displays; no TextEdit, Chrome, or Cursor qualification process or temporary SpaceO
profile remains. Claude Desktop remains authenticated. The user's two-display mirrored topology
and exact modes match the pre-test baseline.

The tested product goal succeeds on this host: Claude can drive native, Chromium, and Electron
apps on a separate virtual display, the Viewer reflects and streams those sessions, the covered
foreground checks remain clean, failures are reported honestly, and the measured run does not show
excessive daemon memory or CPU use. Residual risk remains explicit: private display APIs are being
qualified on a macOS 27 preview build, physical-display mirroring is present, complete key/text
route proof is unavailable, macOS applications may briefly publish a launch window before the
first Accessibility placement callback, and release publication still needs an authenticated
notarization preflight.
