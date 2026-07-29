# SpaceO — Plan

## Goal

Ship a working macOS toolkit that lets one or more AI agents drive real GUI applications on the
user's own Mac **without ever taking the cursor, the keyboard focus, or the screen** from the user.

Success is a single invariant, machine-checked:

> While an agent launches an app, moves it, clicks it, types into it, and screenshots it,
> `NSWorkspace.frontmostApplication` and the cursor position are **bit-identical** before and after,
> and the agent's window is **fully composited** (screenshot is not blank).

If that holds under test, the project works.

## Non-goals

- Not a window manager. SpaceO moves an already-running process's windows only when the caller
  adopts it explicitly; a launch that macOS satisfies by substituting a running app fails instead.
- Not an agent. SpaceO is the substrate an agent runtime sits on.
- Not a sandbox. Agent apps run as the user, with the user's files. Isolation here is about
  *attention*, not security. Security isolation is Tier 2/3 (second login session, or a VM).
- No SIP disabling, ever. If a capability needs SIP off, we don't ship it.

## Scope: what gets built

| # | Layer | Deliverable |
|---|---|---|
| 1 | Stage | `Stage` + `DisplayPool` — headless displays, shared between sessions as tiles |
| 2 | Placement | `AppLauncher` + `WindowPlacement` — non-activating launch, window relocation onto the stage |
| 3 | Input | `InputRouter` — focus-without-raise, per-PID keys/mouse, AX actions |
| 4 | Vision | `Capture` + `AXTree` — ScreenCaptureKit per-display/window, indexed accessibility tree |
| 5 | Diagnostics | `IsolationSnapshot`, `PasteboardGuard`, session janitor |
| 6 | Orchestration | `AgentSession` + `spaceo` CLI + MCP server for agent runtimes |

## Milestones

- **M1 — Foundations.** Package scaffold, private-API shim, `spaceo doctor` capability gate passes.
- **M2 — Stage.** Create/park/destroy a display; prove it owns its own Space; prove zero leaks.
- **M3 — Occupancy.** Launch an app into a session without activation; window lands on the stage.
- **M4 — Control.** Type and click into that window from the background; read it back through AX.
- **M5 — Sight.** Screenshot the stage and the window; assert non-blank.
- **M6 — Diagnostics.** Pasteboard preservation, isolation reporting, and teardown hold under test.
- **M7 — Green.** Whole suite passes, including the isolation invariant and leak checks.

## Test strategy

Three tiers. Unit tests remain non-mutating; the live target runs without an acknowledgement gate.

1. **Unit** — pure logic, no system state: capability gating, parking geometry, AX tree
   serialization, coordinate mapping. Must pass on any machine.
2. **Integration** — real WindowServer via `make test-live`, gated only by capabilities/TCC and
   skipped with a clear message when a required grant or app is missing.
3. **Invariant** — the one that matters. Records frontmost app + cursor position, runs a full
   agent workflow against TextEdit, asserts both unchanged and the capture non-blank.

Plus a **leak check** that runs last: no virtual displays left, no orphan processes, display
arrangement restored.

Every test that creates system state does teardown in `defer` and verifies removal.

## Risks and how we handle them

| Risk | Handling |
|---|---|
| Private API vanishes in a macOS update | Every symbol behind `dlsym` + `Capabilities` gate; fail closed with a readable error, never crash |
| TCC not granted in the test runner | Integration tests skip with instructions, unit tests still run |
| Apps reject per-PID input | Delivery is attempted for every target; failures are observed rather than pre-blocked |
| Chromium drops synthetic mouse events | Prefer a loopback DevTools endpoint; fall back to unrestricted per-PID delivery |
| A display does not retire | Serialize lifecycle, reuse idle displays, and report teardown/orphan state without blocking creation |
| Agent app steals focus on its own | Janitor detects frontmost change caused by an owned pid and reports it; never fights the user |

## Definition of done

- Release build, unit tests, MCP black-box smoke, and live tests green.
- `spaceo doctor` reports all capabilities on this machine.
- A scripted demo launches an app, drives it, screenshots it, and tears down — with the isolation
  invariant asserted, not just claimed.
- README documents the verified surface and the honest gaps.
