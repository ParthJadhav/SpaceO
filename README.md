# SpaceO

Give each AI agent its own screen on your Mac, so it can drive real apps while preserving the
user's cursor, keyboard focus, and display.

> [!NOTE]
> Virtual-display creation and focus routing are enabled. The unsafe private focus getters from
> the 2026-07-26 incident remain removed; focus preparation and route restoration are best-effort.
> Display creation no longer has product caps or preflight refusals for mirroring,
> ownerless displays, physical-display activity, overlap, or cursor-fence availability. Those
> conditions remain visible in diagnostics, and teardown is still verified. See the
> [incident report](docs/incidents/2026-07-26-display-input-lockout.md) and
> [release audit](RELEASE_AUDIT.md) for the historical failure and accepted policy change.

> [!WARNING]
> **SpaceO isolates attention, not security.** Agent apps still run as your logged-in macOS user
> and can use the files, network, app sessions, notifications, and credentials that user or app
> is allowed to access. Session tiles prevent accidental cross-tile screenshots; they are not an
> OS sandbox or hostile multi-tenant boundary. Run untrusted agents or applications in a separate
> macOS login session or a VM.

Expected UX:

```
$ spaceo demo
  PASS  stage created
  PASS  launch did not disturb the user
  PASS  typed text reached the app
  PASS  window screenshot is really rendered
  PASS  session audit is clean
  PASS  stage removed on teardown
```

## The idea

The naive approach is to give the agent its own Mission Control **Space**. That doesn't work: a
window on an inactive Space is officially "not visible", so macOS tells the app to stop drawing
and accessibility trees go stale.

SpaceO gives each agent its own **display** instead — a headless `CGVirtualDisplay` that isn't
attached to anything. A window there is genuinely visible, so it renders normally and every
standard API works. Input goes straight to the target process, so the cursor never moves and the
menu bar never changes hands.

| what gets stolen normally | how SpaceO returns it |
|---|---|
| screen real estate | agent windows live on a display that isn't on your desk |
| the mouse cursor | AX actions or per-PID events drive the target; the pointer never moves |
| keyboard focus / frontmost app | input routing is flipped without raising or activating |

The load-bearing rule: **never call `SLPSSetFrontProcessWithOptions`** — that is the one API
that raises a window and drags you to its Space.

Background, evidence, and the private-API map: [FINDINGS.md](FINDINGS.md).
Design and module contracts: [ARCHITECTURE.md](ARCHITECTURE.md). The current release status and
every defect found during hardening are in [RELEASE_AUDIT.md](RELEASE_AUDIT.md).

## MCP configuration

SpaceO speaks MCP and starts its shared daemon on demand. Every client for the same macOS user
shares that daemon and its privileges; session names are routing identifiers, not authorization
tokens.

**Claude Code**
```bash
claude mcp add spaceo -- "$HOME/.local/bin/spaceo" mcp
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

Display creation is admitted against a resource budget before anything is allocated — live
sessions, attached displays, total framebuffer pixels and bytes, displays created per minute, and
a minimum usable tile. A virtual display is a framebuffer the WindowServer composites inside
*your* login session, so an agent stuck in a retry loop must not be able to walk the machine into
a reboot. `spaceo doctor` and `spaceo pool` print current usage against the limits, and every
refusal states the requested value, the limit, and what to do about it. Setting
`SPACEO_UNSAFE_RESOURCE_LIMITS=1` in the daemon's environment raises the limits considerably; it
is deliberately an operator decision at daemon start rather than something an agent can request.

Tools the agent sees: `spaceo_session_create`, `spaceo_session_list`, `spaceo_open_app`, `spaceo_read_screen`,
`spaceo_click`, `spaceo_type`, `spaceo_press_key`, `spaceo_screenshot`, `spaceo_list_windows`,
`spaceo_verify_isolation`, `spaceo_pool_status`, `spaceo_session_destroy`.

`spaceo_read_screen` is the one that matters. It returns an indexed outline —

```
  [3] Button — Save
  [5] TextField — Address and search bar

page content (click these with --element wN):
  [w0] button — CLICK ME  at (920,419)
```

— and `spaceo_click` takes those references. Clicking `3` presses an app control through
accessibility; clicking `w0` dispatches a real DOM event through the browser. Neither needs
coordinates, so neither can miss.

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

- Apple Silicon Mac; the package deployment target is macOS 14
- **SIP stays on.** Nothing here needs it disabled.
- Accessibility and Screen Recording granted to whatever runs `spaceo`

The current development machine runs a macOS 27 developer build. Private framework behavior can
change between macOS releases, so inspect `spaceo doctor` on each host before sessions are used;
the deployment target is not itself a compatibility guarantee. Its display-graph findings are
diagnostic and do not block creation.

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

The viewer uses the same delivery path as the rest of SpaceO:

- A pressable Accessibility element receives `AXPress`; all other points fall back to **per-PID**
  events stamped with the window under your click. A target is primed with the same
  focus-without-raise sequence and paced pointer events used by the CLI.
- Control is available for both SpaceO virtual displays and physical displays; display provenance
  is not an input allowlist.
- While Control is on, every keyboard shortcut, including Control-Command-Escape, is forwarded
  to the selected display. Turn the toolbar toggle off to stop forwarding.
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
back to ad-hoc signing and macOS may require the grants to be refreshed after a rebuild. The
viewer creates no displays itself; agent displays appear when the daemon owns one or more
sessions.

## Use

Sessions outlive a single command, so they live in a daemon:

```bash
spaceo daemon &
```

```bash
spaceo session create --session research
spaceo run TextEdit ~/notes.txt
spaceo ax
spaceo click --element 3
spaceo type "hello from an agent"
spaceo screenshot -o /tmp/agent.png
spaceo verify
spaceo session destroy --session research
spaceo daemon stop
```

Every command that touches an app reports whether isolation held:

```
  isolation: intact (user undisturbed)
```

The check knows which processes and Spaces belong to agents, so it blames SpaceO only for
changes that land on agent territory. You switching apps mid-command is reported as a note, not
a violation — a safety check that cries wolf is one nobody reads.

`--json` on any command gives machine-readable output for an agent runtime to consume.

### Addressing elements

Prefer `--element N` from `spaceo ax` over pixel coordinates. It is coordinate-free, needs no
focus, survives the window moving, and cannot miss:

```
$ spaceo ax
5 actionable element(s) in window 15115
    [0] TextArea — agenda
    [1] Button
    [2] Button — this button also has an action to zoom the window
```

## Tests

```bash
make test
```

There are 80 non-GUI tests. The live WindowServer suite creates real virtual displays and drives
installed applications:

```bash
SPACEO_RUN_INTEGRATION_TESTS=1 make test-live
```

Run it only in a disposable graphical login session, never in your primary login. The
three-display churn case is separately gated with `SPACEO_RUN_DISPLAY_STRESS_TESTS=1`.

The live suite asserts the isolation invariant end-to-end, proves DOM clicks actually reach a
Chromium page, exercises simultaneous displays, and fails if a test leaks a virtual display.

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
| input, native apps | enabled; focus preparation and route restoration are best-effort |
| input, Chromium pages | DevTools when available, unrestricted per-PID delivery otherwise |
| vision | AX outlines plus per-window, per-tile, and full-display capture |
| session hygiene | pasteboard preservation, audit, clean shutdown; no pointer fencing |
| the invariant | checked after every agent action and by the live suite |

App classes actually exercised: **native AppKit** (TextEdit), **Electron** (Cursor), **Chromium**
(Google Chrome).

Known boundaries:

- **Application event handling varies.** SpaceO attempts per-PID delivery for every target rather
  than maintaining a bundle denylist. Some canvas, game, or browser renderers may ignore synthetic
  events even though the operation was not blocked.
- **Chromium web content prefers DevTools.** Launched browsers get their own profile and DevTools
  port for reliable page actions. When no bridge exists, SpaceO still attempts per-PID delivery
  instead of rejecting the target.
- **Self-activating apps.** Some Electron shells activate themselves despite `activates=false`.
  SpaceO hands focus straight back and reports that it had to, so the theft is a blip rather
  than a state change — but there is a visible moment.
- **Cmd-Tab, the Dock, and notifications** still show agent apps. Not solvable on-host.
- **SIGKILL leaks apps.** A daemon killed with `-9` cannot quit the apps it started; displays
  normally follow process lifetime, while `SIGTERM`, Ctrl-C, and `spaceo daemon stop` perform
  orderly cleanup.
- **Display-stack risk.** On the macOS 27 preview verification host, a rapid integration run
  while the physical displays were mirrored at high refresh left phantom virtual displays in
  the login session and left both physical displays online but inactive. A display sleep/wake
  removed the ownerless display IDs. The lifecycle remains serialized, one empty daemon display
  is kept warm instead of churned, and detach failures plus mirror/orphan/user-display state are
  reported. By owner decision, those observations no longer refuse or roll back display creation,
  and pointer fencing is absent rather than a creation precondition.
- **Private API risk.** `dlsym` detects a missing name, not a changed calling convention or unsafe
  behavior. SpaceO avoids the corrupting private getters, verifies restoration through public
  AppKit state, and fails closed when a required class or symbol is absent.
- Production exposes no diagonal-parking API or `CGConfigureDisplayOrigin` path. See FINDINGS
  §4.1 for why the historical research probe remains as evidence only.
