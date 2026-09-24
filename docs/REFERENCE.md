# SpaceO reference

Detailed agent configuration, CLI usage, Viewer controls, and implementation status.
See the [project README](../README.md) for an introduction.

## MCP configuration

SpaceO speaks MCP and starts its shared daemon on demand. Every client for the same macOS user
shares that daemon and its privileges; session names are routing identifiers, not authorization
tokens.

**Claude Code**
```bash
claude mcp add -s user spaceo -- "$HOME/.local/bin/spaceo" mcp
```

**Codex** (`~/.codex/config.toml`)
```toml
[mcp_servers.spaceo]
command = "/Users/you/.local/bin/spaceo"
args = ["mcp"]
```

**Cursor / Claude Desktop** (`mcp.json` / `claude_desktop_config.json`)
```json
{ "mcpServers": { "spaceo": {
  "command": "/Users/you/.local/bin/spaceo", "args": ["mcp"]
} } }
```

Replace `you` with the macOS account name in file-based configurations; these clients do not all
expand `~`.

To pack several agents onto one display, set the density in the MCP config's environment —
the auto-started daemon reads it:

```json
{ "mcpServers": { "spaceo": {
    "command": "/Users/you/.local/bin/spaceo", "args": ["mcp"],
    "env": { "SPACEO_SESSIONS_PER_DISPLAY": "4", "SPACEO_DISPLAY_SIZE": "2560x1440" }
} } }
```

The MCP server starts the shared daemon on demand, so every agent on the machine pools the same
agent displays instead of each spinning up its own.

`spaceo doctor` and `spaceo pool` report current display and session usage. SpaceO accepts any
positive, technically representable display geometry and packing density; allocation failures
from CoreGraphics or WindowServer are returned to the caller.

The daemon appends every failed request, janitor reclamation, and lifecycle event as one JSON
line to `~/Library/Logs/SpaceO/daemon.log` (path shown by `spaceo doctor`; override with
`SPACEO_LOG_FILE`; log every request with `SPACEO_LOG_METRICS=1` or
`SPACEO_LOG_DEBUG=1`). Request records include wall time, request-local CPU time, current/peak RSS,
physical footprint, warning/truncation state, and a per-tool trace id that matches the MCP stderr
line. Set `SPACEO_RUN_ID` to group one test or soak run, then summarize it with
`node scripts/metrics-report.mjs ~/Library/Logs/SpaceO/daemon.log --run=RUN_ID`. Controller lease
credentials and direct typed-text, screenshot, and accessibility payloads are omitted from request
summaries. Error details can contain local paths, window titles, or app-provided text; review and
redact logs before sharing. Free-text diagnostic fields are bounded. MCP clients forward their run id and metrics preference
on each request, so traces remain attributable even when the signed Viewer owns the shared daemon.
The owner-only file rotates at 5 MB, keeping one predecessor (`daemon.log.1`).

`spaceo doctor` also compares the current CLI with the executable image the running daemon reported
at startup. It compares the Mach-O build UUID first because signing the Viewer's embedded helper
changes its SHA-256 without changing the compiled code; the exact SHA-256 remains available for
artifact identification and is the fallback for older daemons. Restart the daemon after every
install or upgrade when doctor says `daemon matches CLI: NO` or `unknown`; replacing the file on
disk cannot replace code already loaded in a long-lived process. Doctor reports client and daemon
permission state separately because TCC grants belong to the process that hosts the daemon.

Tools the agent sees: `spaceo_session_create`, `spaceo_session_list`,
`spaceo_session_heartbeat`, `spaceo_session_pause`, `spaceo_session_resume`,
`spaceo_session_set_title`, `spaceo_open_app`, `spaceo_open_url`, `spaceo_adopt_app`,
`spaceo_place_window`, `spaceo_read_screen`, `spaceo_find`, `spaceo_read_text`,
`spaceo_wait_for`, `spaceo_list_targets`, `spaceo_attach_target`, `spaceo_click`,
`spaceo_scroll`, `spaceo_move`, `spaceo_drag`, `spaceo_select_text`, `spaceo_type`,
`spaceo_press_key`, `spaceo_run_steps`, `spaceo_clipboard_set`, `spaceo_clipboard_get`,
`spaceo_screenshot`, `spaceo_list_windows`, `spaceo_verify_isolation`, `spaceo_pool_status`,
`spaceo_events`, `spaceo_session_destroy`. The server also publishes the agent playbook as MCP
prompts (`drive-app`, `drive-web`, `hand-off-to-human`) and resources (`spaceo://docs/…`,
`spaceo://schema`, `spaceo://doctor`); `spaceo skill` prints the same playbook as a `SKILL.md`.

`spaceo_read_screen` is the one that matters. It returns an indexed outline —

```
  [3] Button — Save
  [5] TextField — Address and search bar

page content (click these with --element wN):
  [w0] button — CLICK ME  at (920,419)
```

— and `spaceo_click` takes those references. Clicking `3` presses an app control through
accessibility; clicking `w0` dispatches a real DOM event through the browser. Neither needs
coordinates. References can become stale and apps can reject actions; check the result and read
the screen again before relying on a change.

Every read ends with a footer such as `elements: 143 shown, truncated: false`. A truncated read is
not the whole screen: `spaceo_find "Save"` searches the tree (and the page) and returns fresh
indices, and `spaceo_read_screen since=<snapshot id>` returns only what was added, removed or
changed since the last read. `spaceo_read_text` reads a document, terminal pane or article in
reading order without a screenshot. `spaceo_wait_for` waits, bounded, for a label, a title, a CSS
selector or for the pixels to stop changing instead of polling screenshots. `spaceo_open_url`
navigates the session's managed browser in one call. `spaceo_run_steps` sends up to sixteen
actions in one round trip. `spaceo_scroll`, `spaceo_move` and `spaceo_drag` take an `element`
reference wherever they take a point, and report the `resolved_point` they used.

⌘C, ⌘X and ⌘V go through a per-session clipboard broker (`spaceo_clipboard_set` /
`spaceo_clipboard_get`); the user's own pasteboard is never read or written on any agent route.
Every error carries a structured `recovery` object naming the tool to call next, and when the
human took Control and handed it back, the agent's next response starts with a `HUMAN HANDOFF:`
line describing what happened.

An element reference is an accessibility press, so it carries no button, click count, or
modifiers. For a right-click, a double-click, a shift-click, a drag, or a point with no
accessibility element, use coordinates — and coordinates are safe to read straight off a
screenshot, because `spaceo_screenshot` returns one pixel per point at its default scale and
reports its geometry either way. `spaceo_scroll` reaches anything below the fold and
`spaceo_move` reveals hover-only menus and tooltips; both take a point, because an app with two
scrollable or hoverable regions routes by what is under the pointer.

## Session ownership and recovery

Creating a session returns a controller lease. Successful owner-scoped mutations renew its
bounded TTL, and `spaceo session heartbeat --lease UUID` keeps it alive while a controller is
otherwise idle. Lease values are returned only by create and heartbeat, never by session lists;
MCP connections retain and supply their own leases automatically.

The lease also fences what other clients of the same daemon can see and break: session-scoped
reads (`windows`, `ax`, `screenshot`, `verify`) need the session's lease, `session.list` redacts
other controllers' app/window detail, and `session.destroy --all`, `daemon.stop`, `pool set`
and `pool remove` need the explicit `--operator` flag when they would cross controller boundaries.
This is coordination between cooperating agents, not a security boundary — everything on the
socket shares one uid.

An expired or disappeared controller leaves an abandoned session. After a short grace interval,
SpaceO can reclaim its resources; “reclaimable” means safe to clean up, not safe for another
controller to take over. Session lists and SpaceO Viewer expose the owner, age, last activity,
reclaimability, and cleanup blockers.

The daemon also keeps a private, per-socket recovery ledger. A new daemon fences every old lease
before accepting work and treats prior display and window ids as diagnostic only. Detached
recovery terminates only exact, currently matching processes that SpaceO launched; adopted apps
are released without termination. See [Session ownership and recovery](SESSION_RECOVERY.md)
for lease handling, restart behavior, and operator retry steps.

## Sessions share displays

A virtual display is a whole framebuffer for the WindowServer to composite, so SpaceO packs
several agents onto one and only creates another when they are full:

```bash
spaceo daemon --sessions-per-display 4
```

```bash
spaceo pool
```
```
display 35  2560x1600 at (1920,0)  3/4 tiles used  spaces=118
```

Each session gets a non-overlapping tile and can only see and screenshot its own. `spaceo pool
set N` changes the density for displays created afterwards — existing ones keep their layout,
because re-tiling under a running agent would move its windows out from under it. Any positive
density is accepted. If you do not pin `--display-size`, the daemon grows the framebuffer for the
requested density; if you do pin it, SpaceO honors the requested size even when the resulting
tiles are very small.

## Requirements and support status

- The package deployment target is macOS 14 or later.
- Public-release support and release packaging are currently Apple Silicon (`arm64`) only. Intel
  remains unqualified and unsupported until equivalent implementation and independent evidence
  exist.
- **SIP stays on.** Nothing here needs it disabled.
- Accessibility and Screen Recording granted to whatever runs `spaceo`

Private focus records remain disabled. Other private surfaces are enabled when their required
runtime class or symbol is present. Run `spaceo doctor` for per-capability availability and see
[private API runtime support](PRIVATE_API_SUPPORT.md) for the checks and known limitations.
Runtime discovery is not a compatibility guarantee. See the [support policy](../SUPPORT.md) and
[release policy](RELEASE_POLICY.md) for the supported-host and qualification rules.

## Install a release

The supported public distribution model is a versioned Developer ID DMG—not the Mac App Store—
containing both the `spaceo` CLI and `SpaceO Viewer.app`, plus a SHA-256 sidecar and its detached
SpaceO publisher signature. Authenticate Team ID `75LRT8TRQY` before trusting the checksum or
executing the payload; then verify the stapled ticket and Gatekeeper assessment.

No signed, notarized, qualified public release is currently recorded in this
repository. `VERSION` is the planned release number, not proof that an installable release exists.
Do not treat a local build or ad-hoc-signed artifact as a public release.

See [Installing a SpaceO release](INSTALL.md) for exact installation, upgrade, rollback,
uninstall, artifact-verification, and maintainer publication procedures.

## Keeping it up to date

```bash
spaceo version      # installed CLI
spaceo doctor       # look for: daemon matches CLI: yes
```

After every upgrade, restart the daemon (`spaceo daemon stop`, then start it again) and restart
your MCP clients — a running daemon keeps the old code loaded. For source builds, `git fetch
origin && git log --oneline HEAD..origin/main` shows whether you are behind. Details, including
Viewer and toolchain checks: [Keeping SpaceO up to date](UPDATING.md).

## Local development build

Build locally without installing an MCP:

```bash
make verify-release
```

```bash
./.build/release/spaceo doctor
```

`doctor` reports virtual-display, input-routing, capture, permission, and display-graph state. It
never calls the incompatible private key/typing-focus getters.

If `doctor` reports **orphaned displays**, creation is still allowed. Treat the report as evidence
that the current graphical login session may need a reset rather than as a software lockout.

## Viewer app

`SpaceO Viewer` is a VM-style console for every online display: pick one in the sidebar, watch it
live, and flip the **Control** toggle to drive it with your own mouse and keyboard — like sitting
at a VM's console window.

```bash
make viewer
open ".build/SpaceO Viewer.app"
```

To build, sign, install, verify, and open the Viewer from `/Applications` in one step:

```bash
make install-viewer
```

The viewer uses the same delivery path as the rest of SpaceO:

- A pressable Accessibility element receives `AXPress`; all other points fall back to **per-PID**
  events stamped with the window under your click. Private focus-record priming is disabled;
  delivery does not depend on it. Pointer events use the same pacing as the CLI.
- The sidebar lists agent sessions and, folded underneath, the SpaceO virtual displays they run
  on; your physical displays are not listed. Control is offered only for a SpaceO display that
  currently holds a session. Arming Control on the monitor in front of you would send the
  Viewer's own input back to the desk it came from, which is the one thing this tool exists to
  avoid. An empty SpaceO display still inside its reuse grace is
  refused for the same reason — there is nothing there to drive. The toggle also becomes
  available only after the selected display has a live stream; if capture stops or fails, the
  viewer turns Control off, releases held remote keys, and reports the failure in text and
  through VoiceOver. The footer under the canvas distinguishes idle, starting, live, stalled and failed
  streams. **Retry** starts a failed selection again, while **Reload** (⌘R) re-scans display
  geometry and restarts the selected stream.
- While Control is on, keyboard shortcuts are forwarded to the selected display except
  **Control-Command-Escape**, which always exits Control locally and is never sent remotely.
  Reserving that uncommon chord keeps ordinary Escape available to remote apps and avoids
  VoiceOver's Control-Option modifier; the tradeoff is that a remote app cannot receive this one
  chord. The surface help and status bar expose the shortcut while Control is active.
- Drags stay with the window they started on; the keyboard follows the last window you clicked.
- Session tiles are outlined with their session ids when a daemon is running (`session.list`
  over the daemon socket); without a daemon you get the plain display.
- Viewer attempts delivery for every target process. It does not maintain a canvas/game denylist.
  An application may still ignore a synthetic event, but SpaceO attempts delivery instead of
  blocking control based on the application's identity.

It needs Screen Recording (to stream) and Accessibility (to send input); the in-app banner
links to the right System Settings panes. `make viewer` wraps the binary in a bundle and
automatically uses an available Developer ID or Apple Development certificate so its identity
and privacy grants survive rebuilds. Set `SPACEO_CODESIGN_IDENTITY` to choose a certificate
explicitly, or to `-` to force ad-hoc signing. When no certificate is available, the build falls
back to ad-hoc signing and macOS may require the grants to be refreshed after a rebuild.
Certificate-backed local builds request a secure timestamp. Public distribution never permits
ad-hoc or Apple Development signing; the release pipeline requires an explicit Developer ID
identity, notarizes and staples the artifacts, and fails closed if any trust check fails. The
viewer creates no displays itself; agent displays appear when the daemon owns one or more sessions.

## Use

Sessions outlive a single command, so they live in a daemon:

```bash
spaceo daemon &
```

```bash
spaceo session create --session research
# Save the UUID printed as "controller lease" and use it below.
spaceo run TextEdit ~/notes.txt --session research --lease UUID
spaceo ax --session research --lease UUID
spaceo click --session research --lease UUID --element 3
spaceo type "hello from an agent" --session research --lease UUID
spaceo screenshot --session research --lease UUID -o /tmp/agent.png
spaceo verify --session research --lease UUID
spaceo session destroy --session research --lease UUID
spaceo daemon stop
```

The lease is the session's coordination credential. The MCP server stores and supplies it
automatically; CLI scripts must retain the value returned by `session create` (or a later
`session heartbeat`).

Launch and input commands, plus `spaceo verify`, report isolation coverage and failures:

```
  isolation: partial (no covered breach; required checks remain unknown)
    - menu_bar_owner: passed [observed] — NSWorkspace frontmost application
    - window_server_front_process: passed [inferred] — inferred from AppKit; no safe WindowServer front-process getter is available
    - key_input_route: unknown [unknown] — no safe public input-route getter is available
    - text_input_route: unknown [unknown] — no safe public input-route getter is available
    - cursor_location: passed [observed] — CoreGraphics event location
    - active_space: passed [observed] — WindowServer active Space
```

The check knows which processes and Spaces belong to agents, so it blames SpaceO only for
changes that land on agent territory. You switching apps mid-command is reported as a note, not
a violation — a safety check that cries wolf is one nobody reads. The removed private focus
getters have no safe replacement, so current live checks cannot observe the key-event or
text-input routes. `partial` means that no covered check found a breach; it does **not** mean the
user was fully verified as undisturbed.

`--json` exposes the same result under `isolation`: `verdict` is `intact`, `breached`, or
`partial`; every entry in `checks` includes its `dimension`, `required`, `coverage`, `status`,
`evidence`, and per-check `failures`. The top-level `failures` array contains the same failures
for consumers that do not need to group them by check. The legacy `drift` field is omitted for a
partial report, so an empty array cannot be mistaken for a fully covered clean result.

### Addressing elements

Prefer `--element N` from `spaceo ax` over pixel coordinates. It is coordinate-free, needs no
focus and survives the window moving. A stale reference or rejected action is reported explicitly:

```
$ spaceo ax
5 actionable element(s) in window 15115
    [0] TextArea — agenda
    [1] Button
    [2] Button — this button also has an action to zoom the window
```

## Troubleshooting

Run `spaceo doctor` first; it names the missing permission, API, or daemon mismatch. Common cases:

| Symptom | Fix |
|---|---|
| clicks and typing fail; `MISS accessibility` | grant Accessibility to the app that runs `spaceo`, not the binary |
| screenshots fail; `MISS screen-recording` | grant Screen Recording to that same app |
| `daemon matches CLI: NO` | `spaceo daemon stop`, then start it again |
| `controller lease is required` | pass the `--lease UUID` from `session create` |
| `web clicking requires a ... DevTools bridge` | launch the browser with `spaceo run` so it gets a DevTools port |
| `session ... is paused by the human operator` | turn off Control in the Viewer |
| `doctor` reports orphaned displays | `pmset displaysleepnow` then `caffeinate -u -t 3` |

The daemon log is at `~/Library/Logs/SpaceO/daemon.log`. The full symptom → cause → fix list is
in [Troubleshooting](TROUBLESHOOTING.md).

## Tests

```bash
make test
```

The default suite includes deterministic unit, recovery, persistence, concurrency, and
host-compatibility coverage. It explicitly excludes `IntegrationTests`: ordinary local and CI
tests never create virtual displays, launch GUI applications, or send input.

The live target creates real virtual displays and drives installed applications. It runs in the
current graphical login and needs Accessibility and Screen Recording granted, with no opt-in
environment variables:

```bash
make test-live
```

The live suite asserts the isolation invariant end-to-end, proves DOM clicks actually reach a
Chromium page, exercises simultaneous displays, and fails if a test leaks a virtual display.
Tests report a skip only when an unavoidable technical prerequisite such as a required runtime
API, TCC grant, or installed application is unavailable.

## Project policies

SpaceO is open source under the permissive [MIT License](../LICENSE). Changes and releases are
tracked in the [changelog](../CHANGELOG.md). See the [security policy](../SECURITY.md) for private
vulnerability reporting and boundary guidance, and the [support policy](../SUPPORT.md) for supported
versions and issue-reporting expectations.

The release MCP transport has its own black-box test:

```bash
node scripts/mcp-smoke.mjs .build/release/spaceo
```

`probes/` holds standalone C/ObjC research experiments. Only `spaces`, `caps`, and
`vdisplay-classes` are read-only. Mutating probes have no runtime interlock.

## Current status

| | |
|---|---|
| headless displays | enabled without a pool count cap or display-graph preflight refusal |
| tiling | any positive density, non-overlapping tiles, per-tile capture, spill when full |
| Spaces | each display owns its own; windows placed there stay composited |
| launch | isolated new application instances placed into the session tile |
| late windows | watched and re-parked into the owning tile |
| input, native apps | click, scroll, hover, drag, type, keys; left/right/middle buttons, click counts, and held modifiers |
| input, Chromium pages | DevTools with explicit target selection; web-content actions fail closed when no bridge is available |
| vision | AX outlines plus per-window, per-tile, and sub-region capture, all reporting their scale and origin |
| session hygiene | shared clipboard shortcuts refused, audit, clean shutdown; no pointer fencing |
| the invariant | checked after every agent action and by the live suite |

App classes actually exercised, by `scripts/computer-use-check.mjs` driving the real MCP server:

| | native AppKit | Chromium web content | Electron |
|---|---|---|---|
| read screen | yes, values clipped at 480 bytes and disclosed | yes, page elements under `wN` | yes |
| screenshot | yes | yes | yes |
| click | accessibility press; a coordinate click with no element under it is reported unconfirmed | yes, via DevTools | accessibility press only |
| type / keys | yes | yes | posted through AX/per-PID paths, then checked against the editor's document version and selection; an unobserved keystroke is reported, not assumed |
| scroll | yes, via the accessibility scroll bar | yes, via DevTools | yes for VS Code-family editors, via a private semantic adapter, including split panes; horizontal is reported unconfirmed |
| hover / drag | posted, unconfirmed | yes, via DevTools, including sliders, multi-select modifier clicks, and context actions | no confirmed renderer channel |

The native + Chromium preview matrix also verifies that managed Electron launches are
refused before startup. It does not claim Electron renderer qualification.

```bash
make computer-use-check
```

The harness exits `0` only when every capability was exercised and passed, `1` for a regression,
and `2` when the run is otherwise healthy but a documented product blocker remains — or when a
suite was skipped. A suite whose host application is missing (Chrome for web)
is reported as `SKIP`, counts toward no pass total, and keeps the run out of exit `0`: an
unexercised capability is unknown, not working. Pass `--require-full` for release-time runs to
turn any skip into an exit `1`. The harness reports `passed / exercised` and a computer-use parity
percentage, writes the same percentage into its structured JSON report, and the live workflow
publishes that report as an artifact. The [2026-09-05 expanded matrix](validation/2026-09-05-signed-matrix-clean-actions.json)
passed 36/36 (100%) on the authorized development login, including slider, multi-select, and
context actions, with zero failures, blocks, or skips. This is development-host evidence;
qualification of the exact public distribution remains required.

Known boundaries:

- **Application event handling varies.** SpaceO attempts per-PID delivery for every target rather
  than maintaining a bundle denylist. Some canvas, game, or browser renderers may ignore synthetic
  events even though the operation was not blocked.
- **Chromium web content requires DevTools.** Launched browsers get their own profile and DevTools
  port for reliable page actions. Multiple page targets are listed explicitly and remain
  fail-closed until one is attached; when no bridge exists, web-content input is refused rather
  than silently sent through an ineffective native route.
- **Managed Electron launches are refused in this preview.** Cursor, VS Code, and other
  Electron bundles can activate themselves during startup despite background-launch options.
  SpaceO returns `unsupported_target` before starting them. Electron renderer implementation
  remains experimental and is not part of this preview's support promise. Cursor and VS Code
  may still act as MCP clients controlling native apps and Chromium browsers.
- **Cmd-Tab, the Dock, and notifications** still show agent apps. Not solvable on-host.
- **SIGKILL leaks apps.** A daemon killed with `-9` cannot quit the apps it started; displays
  normally follow process lifetime, while `SIGTERM`, Ctrl-C, and `spaceo daemon stop` perform
  orderly cleanup.
- **Display-stack risk.** On the macOS 27 preview verification host, a rapid integration run
  while the physical displays were mirrored at high refresh left phantom virtual displays in
  the login session and left both physical displays online but inactive. A display sleep/wake
  removed the ownerless display IDs. Creation is now fail-closed: a new display is published only
  after it is active, non-overlapping, owns a managed Space separate from the user's active Space,
  and the online/active/main/bounds/mirroring/rotation/mode/refresh state of every physical display
  is unchanged. Unsafe attachments are invalidated and refused. Empty displays remain available
  for a 15-second churn debounce, then all are retired; detach waits for both the virtual display
  to disappear and the physical configuration to return to its baseline. The strict computer-use
  matrix also checks that every app window is contained, the pool reaches zero displays, and the
  user's online/active/mirrored topology matches before and after the run.
- **Private API risk.** `dlsym` detects a missing name, not a changed calling convention or
  behavior. SpaceO avoids the corrupting private getters, verifies restoration through public
  AppKit state, and reports when a required class or symbol is absent.
- Production exposes no diagonal-parking API or `CGConfigureDisplayOrigin` path. See FINDINGS
  §4.1 for why the historical research probe remains as evidence only.


For readiness, menu-bar apps, explicit placement, stable selectors, memory capture and controller
handoffs, see [Reliable interactive testing](TRANSCRIPT_WORKFLOWS.md). Discover the current
command surface offline with `spaceo schema --json` or any subcommand's `--help`.
