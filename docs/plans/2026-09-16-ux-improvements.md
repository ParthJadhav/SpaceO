# SpaceO — whole-product UX improvement plan

Thirty-six improvements across every surface of SpaceO: first-run setup, the agent-facing MCP and CLI tools,
the shared daemon, the Viewer, attention isolation, and documentation. Each entry states the problem as a
user or agent experiences it, the proposal, exactly where in the codebase it lands, how to build it, and
how to verify it without breaking the project's safety rules.

Date: 16 September 2026
Base commit: `e44f732` on `main`
Scope: SpaceO 1.0.x and 1.1
Author: product/engineering review performed with Claude Code

## Contents

1. [How this plan was built](#principles)
2. [Priority matrix](#matrix)
3. [A. First run, setup and permissions (1–6)](#onboarding)
4. [B. Agent-facing tools: MCP and CLI (7–19)](#agent)
5. [C. Daemon health and reliability (20–25)](#daemon)
6. [D. The Viewer: the human's console (26–33)](#viewer)
7. [E. Attention isolation (34–35)](#isolation)
8. [F. Discoverability and documentation (36)](#docs)
9. [Suggested sequencing](#roadmap)
10. [Guardrails that apply to every item](#guardrails)

## How this plan was built What was read, and the lens applied

The review covered `README.md`, `AGENTS.md`, `PRODUCT_BACKLOG.md` (SPAO-135 to 191),
`TICKETS.md`, `CHANGELOG.md`, the 2026-09-05 product trust audit, the transcript-improvement plan,
the setup and troubleshooting guides, and the source for the CLI (`Sources/spaceo/main.swift`),
MCP server (`Sources/SpaceOMCP/MCPServer.swift`), the daemon (`SessionManager`, `Transport`,
`SessionStore`), the input and capture stack, and the Viewer (`ContentView`, `ViewerModel`,
`SurfaceView`, `DisplayStream`).

SpaceO has three distinct users, and every improvement is judged against all three:

* **The agent**, whose "UI" is the MCP tool list, the tool descriptions, the shape of every response, and every error string. Round trips, context tokens, and ambiguity are its friction.
* **The developer** installing SpaceO, granting permissions, wiring an MCP client, and debugging when something fails.
* **The human operator** who watches agents in the Viewer, takes control, and hands back.

Items that are already tracked in the backlog are cited by ticket id so this document adds design and placement detail rather than duplicating the ticket. Anything new receives a proposed id in the `SPAO-2xx` range so it can be imported alongside the existing set.

Every item respects the project's non-negotiables: no `SLPSSetFrontProcessWithOptions`, no pointer warping, no display-origin mutation, fail-closed capability checks, no silent downgrade of an action into a success claim, and no changes that turn attention isolation into a claimed security boundary.

## Priority matrix P0 blocks the product claim, P1 blocks a credible v1, P2 is quality

| # | Improvement | Surface | Priority | Effort | Backlog link |
| --- | --- | --- | --- | --- | --- |
| 1 | Interactive, resumable setup that opens the exact Settings pane and waits for the grant | Setup | P1 | M | new SPAO-201 |
| 2 | Name the responsible launcher app in doctor and every permission error | Setup / errors | P1 | S | new SPAO-202 |
| 3 | Write MCP client configuration for the developer (`setup --client`) | Setup | P2 | S | new SPAO-203 |
| 4 | One-command daemon restart that drains sessions and preserves grants | CLI / daemon | P1 | M | new SPAO-204 |
| 5 | First-session walkthrough in the Viewer's empty state | Viewer | P2 | S | new SPAO-205 |
| 6 | Install the daemon as a LaunchAgent with stable TCC identity | Daemon / setup | P1 | M | new SPAO-206 |
| 7 | `spaceo_open_url` and a `url` parameter on open\_app | MCP / CLI | P1 | M | SPAO-146 |
| 8 | `spaceo_wait_for`: bounded waits on element, title, or pixel stability | MCP / CLI | P1 | M | SPAO-140 |
| 9 | `spaceo_find` plus explicit truncation on every screen read | MCP / CLI | P1 | S | SPAO-144 |
| 10 | Incremental screen reads: return only what changed since a snapshot | MCP | P1 | M | new SPAO-207 |
| 11 | Batch actions with per-step receipts (`spaceo_run_steps`) | MCP / daemon | P2 | M | new SPAO-208 |
| 12 | Window-scoped text and selection reading (`spaceo_read_text`) | MCP / CLI | P1 | S | SPAO-144 |
| 13 | Per-session clipboard broker replacing the blanket ⌘C/⌘V refusal | Input | P1 | L | SPAO-143, SPAO-160 |
| 14 | Accept element references wherever a point is accepted | MCP / CLI | P1 | S | new SPAO-209 |
| 15 | Machine-actionable `nextAction` in every error | Errors | P1 | S | new SPAO-210 |
| 16 | Create-and-open in one call, with session presets | MCP / CLI | P2 | S | new SPAO-211 |
| 17 | Idempotent open\_app: reuse the session's running instance | Launcher | P1 | S | new SPAO-212 |
| 18 | Typing ergonomics: `submit`, `replace`, key hold and key down/up | Input | P2 | S | SPAO-140 |
| 19 | Annotated screenshots (set-of-marks) that unify vision and index workflows | Capture | P2 | M | new SPAO-213 |
| 20 | Persist only on change; keep an idle daemon silent | Daemon | P2 | S | SPAO-151 |
| 21 | Concurrent accept loop so one stuck client cannot stall the rest | Daemon | P1 | M | SPAO-152 |
| 22 | Disk hygiene: profile and ledger garbage collection, `spaceo clean` | Daemon / CLI | P2 | S | SPAO-153 |
| 23 | Event stream over the socket replacing Viewer polling | Daemon / Viewer | P1 | L | new SPAO-214 |
| 24 | Native notifications for the events a human must know about | Viewer | P2 | S | new SPAO-215 |
| 25 | `spaceo doctor --fix` for the safe remediations | CLI | P2 | S | new SPAO-216 |
| 26 | Viewer remembers state; zoom, fit and pan commands; ⌘N fixed | Viewer | P1 | M | SPAO-161 |
| 27 | Stop restarting the stream when a tile moves | Viewer | P1 | S | SPAO-162 |
| 28 | Show the agent's actions on the canvas as they happen | Viewer / daemon | P1 | M | SPAO-158 follow-up |
| 29 | Copy out of, and drop files into, an agent's display | Viewer | P2 | M | SPAO-160 |
| 30 | Menu bar extra and a floating mini monitor | Viewer | P2 | M | new SPAO-217 |
| 31 | Human-readable session names, colours and grouping by controller | Viewer / ledger | P2 | S | new SPAO-218 |
| 32 | Hand back with a note the agent can read | Viewer / protocol | P1 | S | new SPAO-219 |
| 33 | Session recording and a replayable action timeline | Viewer / daemon | P2 | L | new SPAO-220 |
| 34 | Explain the isolation verdict in one sentence everywhere it appears | MCP / Viewer | P1 | S | SPAO-163 follow-up |
| 35 | Guided mitigation for notifications, Dock, ⌘-Tab and audio | Setup / doctor | P2 | M | SPAO-165 |
| 36 | Ship the agent playbook inside the server: MCP prompts and resources | MCP / docs | P1 | S | new SPAO-221 |

Effort: S under two days, M up to a week, L more than a week including live qualification.

## A. First run, setup and permissions The first fifteen minutes decide whether anyone reaches a working session

### 01 Interactive, resumable setup that opens the exact Settings pane and waits for the grant

P1SetupEffort Mnew SPAO-201

#### Problem

`spaceo setup` prints a `MISS accessibility` row with a remedy and exits. The developer must find System Settings, locate the right pane, find the right host app in the list, come back, and rerun. The permission step is where the trust audit says the funnel is unverified, and it is also where the most manual work sits.

#### Proposal

* Make each MISS row actionable: setup opens the exact pane with the `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and `?Privacy_ScreenCapture` URLs, then polls `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` once a second for up to 120 s with a visible countdown, and continues automatically when the grant lands.
* Persist progress in `~/Library/Application Support/SpaceO/setup-state.json` so a rerun skips completed steps and says why ("step 3 passed at 14:02").
* Keep `--no-prompt` as the non-interactive path; the new behaviour is the default only on a TTY.

#### Where

* `Sources/SpaceOKit/Setup.swift`: add a `SetupStep.remedyAction` (open URL, wait-for predicate, deadline).
* `Sources/spaceo/main.swift` `case "setup"`: TTY detection, countdown rendering.
* `Sources/SpaceOKit/Capabilities.swift`: expose the two preflight predicates as injectable closures so `SetupTests` can simulate a late grant.
* `docs/SETUP.md` §3–4.

#### Verify

Deterministic: `SetupTests` with a fake clock and a predicate that flips after N polls. Live: one run on a host with no grants, recorded in `docs/validation/`. Do not auto-grant anything; SIP and TCC stay untouched.

### 02 Name the responsible launcher app in doctor and in every permission error

P1SetupErrorsEffort Snew SPAO-202

#### Problem

The single most confusing thing in SpaceO is that macOS attributes TCC to the *responsible* process, not the binary. The docs say "grant the host app (Terminal, iTerm, Cursor…)". The 2026-09-05 audit spent an entire section discovering that T3 Code and cmux produced different grant outcomes for the same binary. The user should never have to figure this out.

#### Proposal

* Resolve the responsible PID with `responsibility_get_pid_responsible_for_pid()` (public libproc symbol) and map it to a bundle name and path.
* `doctor` prints `caller attributed to: Cursor (/Applications/Cursor.app)` and, for the daemon, `daemon attributed to: Claude (…)`.
* `SpaceOError.accessibilityDenied` and `screenRecordingDenied` carry that name: "Add and enable **Cursor** in System Settings ▸ Privacy & Security ▸ Accessibility".
* MCP `initialize` logs the same line to stderr so the client log shows who needs the grant.

#### Where

* New `Sources/SpaceOKit/ResponsibleProcess.swift` (public API only; no private symbol).
* `Sources/SpaceOKit/Errors.swift`: make the two denial cases carry an optional attribution string.
* `Sources/spaceo/main.swift` doctor printing; `Sources/SpaceOKit/RuntimeIdentity.swift` so the daemon reports its own attribution in `daemon.identity`.
* `docs/TROUBLESHOOTING.md` "Permissions" table.

#### Verify

Unit test the mapping with the current process (attribution equals the test runner). Live: run doctor from Terminal, Cursor, and an MCP client and confirm three different names.

### 03 Write MCP client configuration for the developer

P2SetupEffort Snew SPAO-203

#### Problem

Setup prints three configuration blocks and asks the user to paste one. Paths with `~` silently break in Cursor and Claude Desktop, which the docs warn about instead of preventing.

#### Proposal

`spaceo setup --client claude-code|codex|cursor|claude-desktop` detects the client's config file, shows a diff, asks for confirmation, writes an absolute path, and preserves other servers. For Claude Code it shells out to `claude mcp add` when present. With `--print` it only prints. Never writes without a TTY confirmation or `--yes`.

#### Where

* New `Sources/SpaceOKit/MCPClientConfig.swift`: per-client locator, TOML/JSON merge, path escaping (reuse the escaping already tested for SPAO-181).
* `Setup.swift`: final step "register with client".
* `CLIArguments.swift`: add `client`, `print`, `yes` to `setup`'s allowlist and classification.

#### Verify

Golden-file tests for each client format including a pre-existing server entry. Confirm `CLISpecTests.testEveryAllowedFlagIsClassified` still passes.

### 04 One-command daemon restart that drains sessions and preserves grants

P1CLIDaemonEffort Mnew SPAO-204

#### Problem

Every upgrade ends with `daemon matches CLI: NO — restart daemon`. The remedy is a three-step manual dance (check who owns sessions, `daemon stop --operator`, start again or wait for an MCP client) and the upgrade guide devotes a page to it. Meanwhile any agent mid-task loses its session.

#### Proposal

* `spaceo daemon restart [--when-idle | --now --operator]`. Default `--when-idle` asks the running daemon to enter a *draining* state: it refuses new `session.create` with a clear `daemon_draining` code and next action, keeps serving existing sessions, and exits when the last one is destroyed or after a bounded deadline. The CLI then starts the new build from the same responsible process that owned the old one when it can, otherwise says which app should start it.
* MCP clients that receive `daemon_draining` retry create after the daemon restarts; the MCP server already auto-starts a daemon, so the retry needs only a bounded back-off.
* Doctor's "restart required" line becomes "run `spaceo daemon restart`".

#### Where

* `Sources/SpaceOKit/Protocol.swift`: `daemon.drain` command and a `draining` flag on `daemon.identity`.
* `Sources/SpaceOKit/SessionManager.swift`: drain state in the create path and in the janitor's exit condition.
* `Sources/spaceo/main.swift` `case "daemon"`: the `restart` subcommand reusing the existing `daemon.wait` readiness polling.
* `Sources/SpaceOMCP/MCPServer.swift`: back-off on `daemon_draining`.
* `docs/UPDATING.md`.

#### Verify

Deterministic: a draining manager refuses create, serves click on an existing session, and exits after destroy. Reuse the `TeardownResponsivenessTests` harness. Live: upgrade while one agent session is open.

### 05 First-session walkthrough in the Viewer's empty state

P2ViewerEffort Snew SPAO-205

#### Problem

The empty navigator says "Sessions appear automatically when agents connect." A new user with the Viewer open and no agent yet has nothing to do and no proof the machine works. The New Session button exists (SPAO-155) but creates an empty tile that shows nothing.

#### Proposal

A three-step card in the empty workspace: *1. Check host* (runs the same checks as doctor through the daemon and shows green rows), *2. Try it* (creates a session and launches TextEdit into it, so a real window appears in the canvas), *3. Connect an agent* (client picker with a copy button for the exact registration command). Dismissable, remembered per user, reachable again from Help.

#### Where

* `Sources/SpaceOViewer/ContentView.swift`: replace `navigatorEmptyState`'s workspace counterpart with an onboarding view.
* `Sources/SpaceOViewer/ViewerOperations.swift`: `createSession(launching:)` reusing the existing operator-scoped create plus `run`.
* Persist "dismissed" with the same file-backed store `HostInputGuard` uses rather than `UserDefaults`, for the reason documented there.

#### Verify

`ViewerControlPlaneTests` records the exact request sequence. VoiceOver pass on the card.

### 06 Install the daemon as a LaunchAgent with a stable TCC identity

P1DaemonSetupEffort Mnew SPAO-206

#### Problem

Today the daemon is started by whichever MCP client happens to connect first, and it inherits *that* client's TCC grants. The troubleshooting table has a row for "CLI says ok but daemon can drive: NO" precisely because of this. Two clients racing to start it, a client quitting and taking the daemon's grants with it, and "no daemon answered" are all symptoms of the same missing piece: the daemon has no home.

#### Proposal

* `spaceo daemon install` writes `~/Library/LaunchAgents/com.spaceo.daemon.plist` pointing at the signed Viewer's embedded helper (or the signed CLI from `make signed`), with `KeepAlive`, `RunAtLoad`, and the socket path; `uninstall` reverses it. Refuse to install an ad-hoc signed binary and say why: its identity changes on every build, so grants would not stick.
* Because launchd starts it, the daemon is its own responsible process. Permissions are granted once to "SpaceO" and survive client restarts.
* Setup offers this as step 2b when a Developer ID or Apple Development identity is present; doctor reports "daemon supervised by launchd: yes/no".

#### Where

* New `Sources/SpaceOKit/LaunchAgentInstaller.swift`: plist generation, `launchctl bootstrap/bootout gui/$UID`, identity check via the existing signing-identity helpers from `make signed`.
* `Sources/spaceo/main.swift` `daemon install|uninstall|status`.
* `Sources/SpaceOMCP/MCPServer.swift`: when a supervised daemon is configured, do not auto-spawn; wait for the socket with the existing bounded poll and report a clear error if launchd did not bring it up.
* `scripts/make-viewer-app.sh`: make sure the helper path is stable and documented.
* `docs/SETUP.md`, `docs/UPDATING.md`, `docs/SESSION_RECOVERY.md`.

#### Verify

Plist golden test; shell test that install refuses ad-hoc identity. Live: install, revoke and re-grant, kill the daemon and confirm launchd restarts it and detached-session recovery runs. Treat as a host change per `AGENTS.md`: never run it to verify a source edit.

## B. Agent-facing tools: MCP and CLI The agent's UI is the tool list, the response shape, and the error text

### 07 `spaceo_open_url` and a `url` parameter on open\_app

P1MCPCLIEffort MSPAO-146

#### Problem

Getting a browser to a page is the most common agent action and currently takes five calls with three failure points (launch, read screen, click address bar, type, Return), and then a sixth to attach the target once a second tab exists. `files` coerces an `https://` string into a nonsense file path.

#### Proposal

* `spaceo_open_url(url, session, new_tab?)`: reuse the session's managed Chromium if one exists, otherwise launch the default managed browser. Navigate through the existing DevTools bridge with `Page.navigate`, wait for `Page.loadEventFired` or a bounded timeout, auto-attach the resulting target, and return `{title, final_url, target_id, load: complete|timeout}`.
* `spaceo_open_app` rejects `files` entries that parse as remote URLs with a `nextAction` pointing at `spaceo_open_url`.
* CLI: `spaceo open-url https://…`.

#### Where

* `Sources/SpaceOKit/ChromiumBridge.swift`: `navigate(to:)` using `send("Page.navigate")` next to the existing `Runtime.evaluate` and `Input.insertText` calls; enable `Page` domain once per attach.
* `Sources/SpaceOKit/SessionManager.swift`: `openURL` that resolves "the session's browser window" the same way `attach-target` does.
* `Sources/SpaceOKit/Protocol.swift`: `open.url` command; `Sources/SpaceOMCP/MCPServer.swift` tool + argument translation; `CLIArguments.swift` allowlist.
* `scripts/computer-use-check.mjs`: one matrix step.

#### Verify

Deterministic: fake bridge records the exact DevTools call sequence and the timeout path. Live: navigate to the fixture page and assert the title.

### 08 `spaceo_wait_for`: bounded waits on an element, a title, or pixel stability

P1MCPCLIEffort MSPAO-140

#### Problem

After a click that opens a dialog, loads a page, or starts a build, the agent has no way to wait except burning tool calls on screenshots. Each screenshot costs a PNG through the model's context. The backlog notes there is no wait tool at all.

#### Proposal

One tool with one condition per call, bounded to 60 s:

* `element_label` appears (exact accessible label, same matcher as `--label`) or `element_gone`.
* `window_title_contains`.
* `web_selector` exists (through the DevTools bridge) or `web_title_contains`.
* `stable_ms`: a hash of a bounded down-scaled tile capture is unchanged for N ms (the "the spinner stopped" case).
* Plain `ms` as the last resort.

Returns what it saw when the condition was met (index, title, or snapshot id) so the next call needs no re-read. The wait must not hold the daemon's operation gate: the poll runs on the session's own lifecycle task and each probe enters the gate briefly.

#### Where

* New `Sources/SpaceOKit/WaitCondition.swift`: condition enum, evaluator protocol, deadline arithmetic.
* `Sources/SpaceOKit/SessionLifecycle.swift`: run the poll under the per-session lifecycle so a destroy cancels it.
* `Sources/SpaceOKit/Readiness.swift`: reuse the existing readiness reason codes for the "met/timeout/cancelled" result.
* `Capture.swift`: a cheap 1/8-scale hash capture path for `stable_ms`, excluded from metrics as "probe".
* `MCPServer.swift`, `Protocol.swift`, `CLIArguments.swift` (`wait` command).

#### Verify

Deterministic with an injected clock and evaluator. Latency test: another session's click stays under the SPAO-150 p99 while a wait is in flight.

### 09 `spaceo_find` plus explicit truncation on every screen read

P1MCPCLIEffort SSPAO-144

#### Problem

The traversal budget in `AXTraversal` and the 200-element web cap in `ChromiumBridge` truncate silently, so an agent reasons over a partial screen believing it is complete. `AXSnapshot.find(_:)` exists but is unreachable from any tool.

#### Proposal

* Every `spaceo_read_screen` result ends with a machine-readable footer: `elements: 143 shown, truncated: true, reason: traversal_budget|web_cap, hint: use spaceo_find or scroll`.
* `spaceo_find(query, role?, window?, session)`: case-insensitive substring over label, value, and role; returns up to 25 hits as fresh indices bound to a new snapshot id, with frames. Web content is searched through the bridge with the same shape (`wN` indices).
* CLI `spaceo find "Save"`.

#### Where

* `Sources/SpaceOKit/AXTraversal.swift`: return a `TraversalOutcome` with `truncatedBy` instead of a bare array.
* `Sources/SpaceOKit/ChromiumBridge.swift`: report when the 200 cap was hit; add a `findElements(query)` evaluate script.
* `Sources/SpaceOKit/AXTree.swift`: wire `find` into a snapshot-producing call in `AXSnapshotCache`.
* `MCPServer.render`: footer; new tool. Protocol: `ax.find`.

#### Verify

Unit test a synthetic tree that exceeds the budget and assert the flag. Smoke test asserts the footer is present on every read.

### 10 Incremental screen reads: return only what changed since a snapshot

P1MCPEffort Mnew SPAO-207

#### Problem

The tool description says "call it again after anything changes", and agents do, so a form with 80 controls is re-sent in full after every keystroke. Screen reads dominate the agent's context budget in every transcript reviewed, and long contexts are the main reason agent runs degrade.

#### Proposal

* `spaceo_read_screen(since: snapshotID)`: the daemon diffs the new walk against the cached snapshot and returns three short sections, *added*, *removed*, *changed* (label or value changed), plus the new snapshot id and totals. Unchanged elements keep their indices so the agent's existing references stay valid; the response says so explicitly.
* Stable identity comes from an AX path hash (role + parent chain + position among same-role siblings + identifier when the app provides one); web elements use the bridge's backend node id.
* If the cached snapshot is gone (daemon restarted, window replaced) the daemon returns the full read with a `diff_base_missing` note rather than an error.

#### Where

* `Sources/SpaceOKit/AXSnapshotCache.swift`: keep the last N snapshots per window keyed by UUID; add the diff.
* `Sources/SpaceOKit/AXTree.swift`: `AXNode.stableKey`.
* `Sources/SpaceOKit/ChromiumBridge.swift`: include `backendNodeId` in the element list.
* `MCPServer.swift`: `since` argument, diff renderer; tool description rewritten to recommend it.

#### Verify

Property test: diff(a, a) is empty; diff(a, b) applied to a reproduces b. Measure token count on the computer-use fixture before and after and record it in the matrix report.

### 11 Batch actions with per-step receipts

P2MCPDaemonEffort Mnew SPAO-208

#### Problem

Filling a login form is click, type, click, type, key. Five round trips through the model for something the agent already fully knows when it starts. Each round trip is latency plus a chance for the model to drift.

#### Proposal

`spaceo_run_steps(steps: [...], stop_on_failure: true)`, at most 16 steps drawn from click, type, press\_key, scroll, move, wait\_for. The daemon executes them under the session's normal per-action confirmation and returns an array of receipts identical to the single-call responses, plus the index of the first failure. Isolation is checked after the batch, and a breach pauses the session exactly as it does today. This is a transport optimisation, not a new capability: nothing in a batch can do what the single tools cannot.

#### Where

* `Sources/SpaceOKit/Protocol.swift`: `steps.run` carrying an array of existing `Request` bodies.
* `Sources/SpaceOKit/SessionManager.swift`: loop through the existing dispatch, entering the gate per step so other sessions interleave.
* `MCPServer.swift`: reuse the per-tool argument translators; render receipts with the existing `render(_:)`.
* Bound total typed bytes and steps in `ResourceBudget.swift`.

#### Verify

Deterministic: a failing step 3 leaves steps 4+ unexecuted and the receipt says so. Smoke test tool count updated.

### 12 Window-scoped text and selection reading

P1MCPCLIEffort SSPAO-144

#### Problem

An agent cannot read the body of a document, a terminal pane, or a web article without screenshots. `AXTree.text(in:)` exists and is used only by the demo. `spaceo_type` returns the app-wide focused value, which is ambiguous with two windows.

#### Proposal

`spaceo_read_text(window?, element?, max_chars = 20000)` returns the window's text in reading order, or one element's value, plus the current selection when the focused element exposes `AXSelectedText`. For Chromium web content the bridge returns `document.body.innerText` bounded the same way. The response states `truncated` and `source: accessibility|devtools`.

#### Where

* `Sources/SpaceOKit/AXTree.swift`: promote `text(in:)` and add `selectedText(in:)`.
* `ChromiumBridge.swift`: `pageText(limit:)`.
* `SessionManager.swift`, `Protocol.swift` (`ax.text`), `MCPServer.swift`, CLI `text` command.
* Metrics: typed and read payloads stay out of request summaries as today (`DaemonLog.swift`).

#### Verify

Unit test on a synthetic AX tree; smoke test on the fixture page; confirm the log redaction test still passes.

### 13 Per-session clipboard broker replacing the blanket ⌘C / ⌘V refusal

P1InputEffort LSPAO-143SPAO-160

#### Problem

SPAO-143 chose the safe option: refuse ⌘C, ⌘X and ⌘V everywhere. That protects the user's pasteboard but leaves the agent unable to move text between fields, which is table stakes for real work, and it makes the Viewer's ⌘C useless for the human too.

#### Proposal: a broker that never touches the general pasteboard

* `spaceo_clipboard_set(text)` and `spaceo_clipboard_get()` hold a per-session buffer in the daemon, bounded to 1 MiB, cleared on destroy, never persisted.
* ⌘V is rewritten: native targets receive the buffer through `AXSetValue` on the focused text element when it is settable, otherwise through the existing typing route; Chromium targets receive `Input.insertText`. The response says `paste: inserted_via accessibility|typing|devtools`. The `NSPasteboard.general` path stays refused.
* ⌘C and ⌘X read `AXSelectedText` (or the bridge's `window.getSelection()`) into the session buffer; ⌘X additionally deletes through the existing key route and reports whether the deletion was observed.
* Viewer: "Copy from session" reads the session buffer or the current AX selection into the *user's* pasteboard on an explicit click, which is the human's own consent.
* Rich content and files are out of scope and are refused with that exact explanation.

#### Where

* `Sources/SpaceOKit/PasteboardGuard.swift`: keep the refusal for the general pasteboard; add the interception hook that routes to the broker.
* New `Sources/SpaceOKit/SessionClipboard.swift` owned by `AgentSession`.
* `InputRouter.swift`: `paste(text:)` using AX set-value with typing fallback; `ChromiumBridge.swift` already has `Input.insertText`.
* `Protocol.swift`, `MCPServer.swift`, `CLIArguments.swift` (`clipboard get|set`), Viewer `ViewerOperations.swift`.
* `ARCHITECTURE.md` §3.5 rewritten to describe the broker.

#### Verify

Extend `PasteboardGuardProductionTests`: the general pasteboard is never read or written on any route. Live: copy from TextEdit, paste into Chrome, both inside one session; confirm the user's clipboard is byte-identical before and after.

### 14 Accept element references wherever a point is accepted

P1MCPCLIEffort Snew SPAO-209

#### Problem

The product's own guidance is "prefer indexed accessibility elements over coordinates", yet `spaceo_scroll`, `spaceo_move` and `spaceo_drag` require `x`/`y`. To scroll a list the agent must read the screen, take a screenshot to learn where the list is, then scroll. The element already carries a frame.

#### Proposal

Add an optional `element` (and `from_element`/`to_element` for drag) to those three tools and to the screenshot region. The daemon resolves the element's frame from the bound snapshot, uses its centre as the point, and reports `resolved_point` in the receipt so the agent learns the coordinate for later. Stale-snapshot refusal applies exactly as it does to click. Exactly one of point or element must be supplied.

#### Where

* `Sources/SpaceOKit/SessionManager.swift`: a shared `resolvePoint(request)` used by click, scroll, move, drag and screenshot region.
* `MCPServer.swift` schemas and the argument translator table near line 1269; `CLIArguments.swift` allowlists (`element`, `from-element`, `to-element`).
* `scripts/computer-use-check.mjs`: scroll-by-element step.

#### Verify

Deterministic: both-supplied and neither-supplied are structured errors; a stale snapshot is refused. Smoke tool schema check.

### 15 Machine-actionable `nextAction` in every error

P1ErrorsEffort Snew SPAO-210

#### Problem

Errors now carry `errorCode` and a prose `nextAction` (transcript review S04/S08). Prose is good for humans; agents still guess how to turn "read the screen again" into a call. The recovery loop is the single most repeated pattern in agent transcripts.

#### Proposal

Add a structured `recovery` object next to the prose: `{tool: "spaceo_read_screen", arguments: {session, window}, then: "retry with a fresh element index"}`. Populate it for the ten most common codes: `stale_snapshot`, `stale_geometry`, `window_not_ready`, `application_exited`, `permission_denied`, `web_target_ambiguous`, `session_paused`, `lease_required`, `daemon_draining`, `element_not_pressable`. MCP renders it as a fenced JSON line under the message; the CLI includes it in `--json`.

#### Where

* `Sources/SpaceOKit/Errors.swift`: `RecoveryHint` struct and a `recovery` computed property on `SpaceOError`.
* `Sources/SpaceOKit/Protocol.swift` `Response.failure`: carry it on the wire.
* `MCPServer.renderFailure`; `main.swift` JSON error output.

#### Verify

Table-driven test: every error code in `schema --json` either has a hint or is explicitly listed as terminal.

### 16 Create-and-open in one call, with session presets

P2MCPCLIEffort Snew SPAO-211

#### Problem

Every task begins with create, then open, then read. Density and display size live in environment variables read at daemon start, so an agent that needs an exclusive 1080p display for a canvas app has no way to ask for one.

#### Proposal

* `spaceo_session_create` gains `app` (runs open\_app after create and returns both receipts) and `preset`: `shared` (default), `exclusive` (own display at the pool's size), `exclusive_1080p`, `exclusive_1440p`. Presets map onto the pool's existing allocation path; a preset the pool cannot satisfy is refused with the pool status, never silently downgraded.
* CLI: `spaceo session create --app Safari --preset exclusive`.

#### Where

* `Sources/SpaceOKit/DisplayPool.swift`: per-request geometry override with the SPAO-183 representability checks.
* `SessionManager.create`; `Protocol.swift` create request; `MCPServer.swift`; `CLIArguments.swift`.

#### Verify

Deterministic pool tests for each preset including refusal. Doctor's pool summary shows mixed geometries correctly.

### 17 Idempotent open\_app: reuse the session's running instance

P1LauncherEffort Snew SPAO-212

#### Problem

An agent that loses track and calls `spaceo_open_app("Google Chrome")` a second time launches a second private-profile instance into the same tile, doubling windows and confusing target attachment. Agents retry after errors; the tool should tolerate that.

#### Proposal

If the session already owns a live process for the resolved bundle, return its existing windows with `reused: true` and, when `files` or `url` are given, open them in that instance (via `NSWorkspace.open(_:withApplicationAt:)` for files, the bridge for URLs). `new_instance: true` opts out. Adopted apps behave the same way.

#### Where

* `Sources/SpaceOKit/SessionManager.swift` open path before `AppLauncher.launch`.
* `Sources/SpaceOKit/AppLauncher.swift`: `openFiles(in: runningApp)`.
* `MCPServer.swift` schema; tool description updated to say the call is safe to repeat.

#### Verify

Deterministic with the fake launcher used by existing session tests. Matrix step: open twice, assert one process.

### 18 Typing ergonomics: `submit`, `replace`, key hold and key down/up

P2InputEffort SSPAO-140

#### Problem

Filling a field usually means "clear it, type, press Return". Today that is three calls, and clearing requires ⌘A which SpaceO does deliver but the agent has to remember. Games and canvas tools need held keys; `postKey` is a fixed 15 ms tap.

#### Proposal

* `spaceo_type` gains `replace: true` (select-all in the focused element through AX range selection, falling back to ⌘A) and `submit: true` (append Return, reported separately in the receipt).
* `spaceo_press_key` gains `hold_ms` (bounded 0–5000) and `action: down|up|tap`; a `down` without a matching `up` within 10 s is released by the daemon and reported, so a crashed agent cannot leave a key stuck.

#### Where

* `Sources/SpaceOKit/InputRouter.swift` `postKey` and a new `heldKeys` set per session with a watchdog in `SessionLifecycle`.
* `ChromiumBridge.swift` `Input.dispatchKeyEvent` already supports separate down/up.
* `MCPServer.swift`, `CLIArguments.swift`.

#### Verify

Deterministic: watchdog releases a held key; `replace` on a non-text element is a structured error. Matrix: a held arrow key moves the fixture slider more than a tap.

### 19 Annotated screenshots that unify vision and index workflows

P2CaptureEffort Mnew SPAO-213

#### Problem

Agents that reason visually take a screenshot, then separately read the screen to get indices, then mentally align the two. When the alignment is wrong they click the wrong control.

#### Proposal

`spaceo_screenshot(annotate: true)` draws small numbered tags at each actionable element's frame using the same indices the accompanying screen read would return, and returns both in one response with a shared snapshot id. Tags are drawn on the returned PNG only; nothing is drawn on the display. Bounded to 200 tags; beyond that, the response says annotation was partial.

#### Where

* `Sources/SpaceOKit/Capture.swift`: `annotate(image:with frames:)` using CoreGraphics on the captured `CGImage`.
* `SessionManager.screenshot`: take the AX walk and capture under the same gate entry so indices and pixels agree.
* `MCPServer.swift` screenshot content builder near line 982.

#### Verify

Golden image test with a synthetic frame list. Matrix: click the tag's index and the tag's pixel centre and land on the same control.

## C. Daemon health and reliability Invisible when it works, unmistakable when it does not

### 20 Persist only on change; keep an idle daemon silent

P2DaemonEffort SSPAO-151

#### Problem

The janitor persists every session every 3 s with two fsyncs each, while holding the operation gate. On a laptop this is a measurable battery and SSD cost for a daemon doing nothing, and a periodic stall for every agent.

#### Proposal

Persist from the janitor only when the durable projection differs from the last written one (compare an encoded hash kept in memory). Move recovery I/O and any `Thread.sleep` in `DetachedSessionRecovery` off the gate onto the detached worker introduced by SPAO-150. Add an `idle_writes_per_minute` counter to the metrics log so the improvement is measurable.

#### Where

* `Sources/SpaceOKit/SessionManager.swift` `runJanitorPassNow`, `persistSession`.
* `Sources/SpaceOKit/SessionStore.swift`: a `lastWrittenDigest` per session.
* `DetachedSessionRecovery.swift`.

#### Verify

Deterministic: an idle manager with three sessions performs zero writes over 20 simulated ticks; a state change performs exactly one.

### 21 Concurrent accept loop so one stuck client cannot stall the rest

P1DaemonEffort MSPAO-152

#### Problem

`acceptLoop` serves each client inline and blocks up to 3 s reading its request. A client that connects and hesitates delays every agent on the machine. This will happen by accident the first time an MCP client is paused in a debugger.

#### Proposal

Accept on one thread, hand each connection to a bounded pool (64 concurrent, additional connections queued with a fast `daemon_busy` response after 1 s). Keep the single-writer contract on the socket file; the manager actor already serialises mutations.

#### Where

* `Sources/SpaceOKit/Transport.swift` `acceptLoop`, `serve`.
* `ResourceBudget.swift`: connection concurrency bound.

#### Verify

Test: 100 idle connections open while a normal command completes within its usual latency; existing transport tests unchanged.

### 22 Disk hygiene: profile and ledger garbage collection, `spaceo clean`

P2DaemonCLIEffort SSPAO-153

#### Problem

The audit records about 419 MB of historical Chromium profile directories left in the temp folder, and ledgers keyed by socket path are orphaned when the path changes. Nobody sees this until the disk is full.

#### Proposal

* On startup the daemon lists SpaceO-prefixed profile and control directories not referenced by any live or detached record and older than 24 h, and removes them, logging one summary line.
* Orphan ledgers are quarantined to `…/quarantine/` with a note; an unsupported schema version is quarantined and the daemon still starts.
* `spaceo clean [--dry-run]` runs the same pass on demand and prints reclaimed bytes; `doctor` shows "SpaceO disk use" with the path.

#### Where

* `Sources/SpaceOKit/SessionStore.swift`: namespace enumeration and quarantine.
* `Sources/SpaceOKit/AppLauncher.swift`: a stable directory prefix for profiles and an `orphanedResources()` enumerator.
* `main.swift` `clean` and doctor row.

#### Verify

Filesystem tests in a temp root: referenced dirs survive, unreferenced old dirs go, unreferenced young dirs stay.

### 23 Event stream over the socket replacing Viewer polling

P1DaemonViewerCLIEffort Lnew SPAO-214

#### Problem

The Viewer polls `session.list` every two seconds and had to grow coalescing and stale-reply fencing (SPAO-185) to stay correct. Agent actions, pauses, breaches and teardown progress reach the human up to two seconds late, and the CLI has no way to follow what is happening at all.

#### Proposal

* `events.subscribe(since_seq)`: a long-lived connection on which the daemon writes newline-delimited JSON events with a monotonic sequence number: session created/destroyed, app launched/exited, window placed/escaped/reparked, agent action (type, point, element, outcome), pause/resume, isolation verdict change, lease expiring, teardown progress, daemon draining.
* A 4096-event ring buffer allows reconnect with replay; a gap returns `resync_required` and the client does one `session.list`.
* Viewer subscribes and falls back to the existing poll when the stream drops. CLI `spaceo events --follow [--session ID]`.
* Lease-scoped: a subscriber sees full detail only for sessions its lease or operator scope covers, matching SPAO-147's redaction rules.

#### Where

* `Sources/SpaceOKit/Transport.swift`: streaming response mode (depends on item 21).
* New `Sources/SpaceOKit/EventBus.swift`; emit from `SessionManager`, `WindowWatcher`, `InputControlGate`, `SessionLifecycle`.
* `Sources/SpaceOViewer/ViewerModel.swift`: replace the timer-driven refresh with a subscription, keep the poll as fallback.
* `DaemonLog.swift`: the same event record feeds the log, so nothing is logged twice.

#### Verify

Deterministic: replay after gap; redaction per lease. Live: Viewer shows a click within 100 ms of the agent's receipt.

### 24 Native notifications for the events a human must know about

P2ViewerEffort Snew SPAO-215

#### Problem

SpaceO's promise is that the human can ignore the agent display. That only holds if the few things that need a human, an isolation breach, a session that became abandoned, a teardown that left processes behind, a lease about to expire while the human has Control, come to them.

#### Proposal

The Viewer posts `UNUserNotificationCenter` notifications for exactly those four event classes, each with an action button ("Open in Viewer", "Resume agent", "Retry cleanup") that deep-links into the relevant inspector section. Off by default per class in a small Notifications preference; setup asks once. Never notify for routine agent actions.

#### Where

* `Sources/SpaceOViewer/ViewerModel.swift`: consume events (item 23, or the poll delta today) and a `NotificationPolicy`.
* `Sources/SpaceOViewer/ViewerApp.swift`: `UNUserNotificationCenterDelegate` for action routing.
* `scripts/make-viewer-app.sh`: usage description keys in Info.plist.

#### Verify

Policy unit tests; manual check that a breach produces one notification and a click opens Health.

### 25 `spaceo doctor --fix` for the safe remediations

P2CLIEffort Snew SPAO-216

#### Problem

Doctor diagnoses well but every fix is a copy-paste from the troubleshooting table.

#### Proposal

`doctor --fix` performs only remediations that cannot disturb a working session, each behind a y/N prompt (or `--yes`): quarantine orphan ledgers, remove orphaned profiles, open the exact Settings pane for a missing grant, run `daemon restart --when-idle` for a mismatched build, and print the display sleep/wake commands for orphaned displays without running them. Anything else prints the manual step.

#### Where

* `Sources/spaceo/main.swift` doctor case; a `DoctorRemedy` list in `Sources/SpaceOKit/Setup.swift` shared with setup (item 1).

#### Verify

Each remedy is a pure function of the doctor report in tests; a report with no findings yields no remedies.

## D. The Viewer: the human's console Watch, take over, hand back, and never be surprised

### 26 Viewer remembers state; zoom, fit and pan commands; ⌘N fixed

P1ViewerEffort MSPAO-161

#### Problem

Nothing persists: zoom, selection, inspector section, window size and density reset every launch. Zoom is toolbar-only from 1× to 4×; there is no Fit or Actual Size, no drag-to-pan despite an open-hand cursor, and ⌘N opens a second window that blanks the first because one `onFrame` closure is shared.

#### Proposal

* Persist selection, zoom mode, inspector section, sidebar widths and last density in the file-backed store; restore on launch, but never restore Control.
* View menu: Fit to Window (⌘0), Actual Size (⌘1), Zoom In/Out (⌘+ / ⌘−), Toggle Inspector (⌥⌘I); Fit is the default mode so a 2560-wide tile is visible on a laptop.
* Drag-to-pan with the hand cursor when zoomed; two-finger scroll keeps working.
* Multi-window: per-window `DisplayStream` instances keyed by window id, or disable ⌘N and document it. Recommend the former, since watching two sessions side by side is a real operator need.

#### Where

* `Sources/SpaceOViewer/ViewerApp.swift`: `Commands`.
* `Sources/SpaceOViewer/ViewerModel.swift`: a `ViewerPreferences` struct; make `onFrame` a dictionary keyed by surface id.
* `Sources/SpaceOViewer/SurfaceView.swift`: pan gesture, fit calculation.
* `Sources/SpaceOViewer/DisplayStream.swift`: one stream per window scene.

#### Verify

Preferences round-trip test; manual: open two windows on two sessions, both stream.

### 27 Stop restarting the stream when a tile moves

P1ViewerEffort SSPAO-162

#### Problem

The stream target includes tile geometry, so every time the agent resizes or moves a window the live view flickers to black and restarts, which is exactly when the human wants to watch.

#### Proposal

Split the target into *identity* (display id, pixel size) and *crop* (source rect). Crop changes call `SCStream.updateConfiguration` with a new `sourceRect`; only identity changes restart. Show a one-second subtle "tile moved" overlay instead of a black frame.

#### Where

* `Sources/SpaceOViewer/ViewerModel.swift` `currentStreamTarget` and the change handler.
* `Sources/SpaceOViewer/DisplayStream.swift`: `updateCrop(_:)`.

#### Verify

Unit test: a crop-only change produces an update, not a restart. Live: agent calls `place` repeatedly while the Viewer shows the session, no black frames.

### 28 Show the agent's actions on the canvas as they happen

P1ViewerDaemonEffort MSPAO-158 follow-up

#### Problem

SPAO-158 added `lastAgentAction` as text in the inspector. On the canvas itself there is no cue where the agent clicked, what it typed, or where it scrolled, so a human watching cannot tell agent activity from the app's own animation, and cannot judge whether to intervene.

#### Proposal

* Extend the session telemetry with the action's resolved point (window-relative), target element role and label, and outcome (confirmed, unconfirmed, refused).
* Canvas overlay: a ripple at the click point coloured by outcome, a brief typed-text ghost near the focused element (redacted to length when the action came from a secret-bearing route), a scroll arrow. Each fades in 1.5 s. Toggle in View menu, on by default.
* Navigator row shows a 60 s activity sparkline per session so idle sessions are obvious at a glance.
* Event feed lists actions with the same detail and lets the human click one to jump the canvas.

#### Where

* `Sources/SpaceOKit/Protocol.swift` `SessionInfo`: `lastAgentActionPoint`, `lastAgentActionOutcome`, `lastAgentActionTarget`.
* `Sources/SpaceOKit/SessionManager.swift`: record after each input dispatch.
* `Sources/SpaceOViewer/SessionOverlayLayout.swift` and `SurfaceView.swift`: overlay layer; `ContentView.swift` sparkline.
* Item 23 delivers these live; until then the 2 s poll shows the latest.

#### Verify

Layout tests for overlay placement at each zoom; typed text never appears in the daemon log (existing redaction test).

### 29 Copy out of, and drop files into, an agent's display

P2ViewerEffort MSPAO-160

#### Problem

A human who sees an error in the agent's window cannot copy it, and cannot hand the agent a file. These are the two most common "let me help" gestures and every VM console supports both.

#### Proposal

* Edit ▸ Copy from Session (⇧⌘C): reads the session's current AX selection or clipboard buffer (item 13) via the daemon and writes it to the user's pasteboard. This is an explicit user action, so the general pasteboard write is allowed here and only here.
* Drop a file on a tile: the Viewer asks "Open  with ?" and calls the session's open path; the file stays where it is, nothing is copied.
* When Control is active, ⌘V in the captured surface pastes the user's clipboard *text* through the session broker after a one-time per-session confirmation, so the human can paste a URL into the agent's browser.

#### Where

* `Sources/SpaceOViewer/SurfaceView.swift`: `NSDraggingDestination`.
* `Sources/SpaceOViewer/ViewerOperations.swift`: copy and open requests, operator-scoped.
* `Sources/SpaceOViewer/ViewerInputController.swift`: intercept ⌘V while captured and route to the broker.

#### Verify

`ViewerControlPlaneTests` records the requests; manual drop test with TextEdit.

### 30 Menu bar extra and a floating mini monitor

P2ViewerEffort Mnew SPAO-217

#### Problem

The Viewer is a full three-pane window. Most of the time the human wants a glance: how many agents, is anything paused or breached, and a one-click way to look. Keeping a large window open defeats the point of an off-screen display.

#### Proposal

* `MenuBarExtra` with the brand mark and a count badge; menu lists sessions with status dots and offers Open Viewer, Pause All, Resume All, and Take Control of the selected session. Red dot on breach, amber on paused or abandoned.
* Window ▸ Mini Monitor: a small always-on-top, borderless live view of the selected tile that follows the selection, with a click-through option. Uses the same `DisplayStream` at reduced scale.
* Preference to launch the Viewer as a menu bar item only.

#### Where

* `Sources/SpaceOViewer/ViewerApp.swift`: `MenuBarExtra` scene; new `MiniMonitorWindow.swift`.
* `ViewerModel.swift`: aggregate status for the badge.
* `scripts/make-viewer-app.sh`: `LSUIElement` toggled by preference at launch.

#### Verify

Status aggregation tests; manual check that the mini monitor never takes Control by itself.

### 31 Human-readable session names, colours and grouping by controller

P2ViewerLedgerEffort Snew SPAO-218

#### Problem

Sessions are identified by auto-generated ids. With three agents from two clients open, the navigator is a list of UUID fragments and the human cannot tell which is the Cursor task and which is the Claude Code task.

#### Proposal

* Agents already pass `controller_label`; add an optional `title` to create and a `spaceo_session_set_title` tool so an agent can name the task ("Booking flight to SFO").
* The human can rename and colour-tag any session in the Viewer; these live in the durable ledger so they survive Viewer restarts and are visible to `session list`.
* Navigator groups by controller label with a collapsible header, and each tile overlay in Display scope shows the title.

#### Where

* `Sources/SpaceOKit/Protocol.swift` `SessionInfo.title`, `colorTag`; `session.annotate` command.
* `SessionStore.swift` durable record fields (additive schema).
* `ContentView.swift` navigator; `SessionOverlayLayout.swift` labels; MCP tool.

#### Verify

Ledger round-trip test; smoke tool count.

### 32 Hand back with a note the agent can read

P1ViewerProtocolEffort Snew SPAO-219

#### Problem

Taking Control pauses the agent and releasing resumes it, which is correct. But the agent resumes with no idea what the human did in between: they may have dismissed a dialog, logged in, or fixed a typo. The agent's next screen read shows a changed world and it has to guess why.

#### Proposal

* On release, the Viewer offers a one-line note field (skippable). The note, the Control duration, and "windows changed: yes/no" are stored on the session as `operator_handoff`.
* The next input or read command from the agent returns that handoff at the top of its response once, then clears it; `spaceo_session_list` also shows it while unread. The `session_paused` error already tells the agent the human is driving; on resume it now learns what happened.
* The reverse direction: `spaceo_session_pause(reason)` lets an agent say why it stopped ("needs 2FA code") and the Viewer shows that reason on the tile with a Take Control button.

#### Where

* `Sources/SpaceOKit/Protocol.swift`: `OperatorHandoff` on `SessionInfo`; `reason` on `session.control`.
* `Sources/SpaceOKit/InputControlGate.swift`: store and deliver-once semantics.
* `Sources/SpaceOViewer/ContentView.swift`: release sheet; tile banner for agent reasons.
* `MCPServer.render`: prepend the handoff line.

#### Verify

`AgentInputArbitrationTests`: handoff delivered exactly once; the tile banner appears in overlay layout tests.

### 33 Session recording and a replayable action timeline

P2ViewerDaemonEffort Lnew SPAO-220

#### Problem

When an agent run goes wrong, the developer has a daemon log with no pixels and a chat transcript with no timing. Reconstructing "what did it click, and what was on screen" is manual. This is also the artefact the project's own live qualification keeps asking for.

#### Proposal

* Viewer: Record Session writes a `.mov` of the tile through ScreenCaptureKit's recording output (macOS 15+) with an `actions.jsonl` sidecar from the event stream. Explicit start, visible red indicator on the tile, saved to a user-chosen location.
* Daemon: `spaceo_session_create(record: "actions" | "actions+frames")` writes per-action receipts and, for the second mode, a bounded low-resolution capture before and after each action, under `~/Library/Application Support/SpaceO/recordings//`, capped at 500 MB with oldest-first pruning. Off by default; never written to support bundles automatically.
* `spaceo report`  renders a static HTML timeline (action, receipt, before/after thumbnails) for sharing after the user reviews it.

#### Where

* `Sources/SpaceOViewer/DisplayStream.swift`: `SCRecordingOutput` behind an availability check.
* New `Sources/SpaceOKit/SessionRecorder.swift` fed by the event bus (item 23) and `Capture`.
* `main.swift` `report`; `ResourceBudget.swift` caps.

#### Verify

Recorder tests with a fake capture; pruning test; the report renderer is a pure function with a golden file.

## E. Attention isolation Close the gap between "your desktop is undisturbed" and what the user actually notices

### 34 Explain the isolation verdict in one sentence everywhere it appears

P1MCPViewerEffort SSPAO-163 follow-up

#### Problem

`partial` is the most common verdict and the most misunderstood. The demo output shows "unknown required checks: key\_input\_route, text\_input\_route" with no indication whether that is bad. Agents either stop needlessly or ignore the field entirely, and the Viewer shows a badge without a tooltip.

#### Proposal

* Every isolation render starts with one plain sentence: "No disturbance to your desktop was observed; keyboard routing could not be checked because Accessibility is missing on the daemon." followed by the per-check table. `breached` names the exact evidence and what SpaceO did (paused the session).
* Viewer: the badge gets a popover with the same sentence and the check table; the Health section links a missing-coverage cause to its remedy (usually a grant).
* Tool descriptions for `spaceo_verify_isolation` and the create tool say what to do on each verdict in one line each.

#### Where

* `Sources/SpaceOKit/IsolationSnapshot.swift`: `IsolationReport.summarySentence` derived from coverage and cause codes.
* `MCPServer.renderIsolation`, CLI verify output, Viewer inspector badge in `ContentView.swift`.

#### Verify

Extend `IsolationCoverageTests` with the exact sentence for each verdict and cause combination.

### 35 Guided mitigation for notifications, Dock, ⌘-Tab and audio

P2SetupDoctorEffort MSPAO-165

#### Problem

Agent apps still appear in ⌘-Tab, the Dock and Mission Control, still post banners onto the user's display, and are fully audible. The troubleshooting table calls this "expected". It is expected, but it is also the residual attention leak the user notices most.

#### Proposal (no private APIs, no per-app hacks)

* **Notifications:** setup step "Quiet agent apps" that explains the Focus filter approach, opens Settings ▸ Focus, and lists the apps SpaceO has launched so far so the user can silence exactly those. Doctor reports whether a Focus is active during a session as informational only.
* **Audio:** investigate launching managed Chromium with `--mute-audio` (supported flag, safe for the managed route) and record the result; for other apps document the limitation. A per-session `mute_browser: true` option on open\_app.
* **Dock and ⌘-Tab:** document honestly that these cannot be hidden without changing the app; the Viewer's session titles (item 31) reduce confusion when the user does see them.
* Record the negative results in `FINDINGS.md` so they are not re-investigated.

#### Where

* `Sources/SpaceOKit/Setup.swift` optional step; `main.swift` doctor row.
* `Sources/SpaceOKit/AppLauncher.swift`: `--mute-audio` in the managed Chromium argument list when requested.
* `docs/SETUP.md`, `FINDINGS.md`.

#### Verify

Launcher argument test; live: a muted managed browser plays a video silently.

## F. Discoverability and documentation Put the playbook where the agent already is

### 36 Ship the agent playbook inside the server: MCP prompts and resources

P1MCPDocsEffort Snew SPAO-221

#### Problem

The MCP server implements `initialize` and `tools/list` only. The knowledge an agent needs to use SpaceO well, prefer indices, when to use coordinates, how to read the isolation verdict, what to do on `stale_snapshot`, lives in a server-instructions blob and in the README. Every host reads it differently, and none can fetch the troubleshooting table when something fails.

#### Proposal

* `prompts/list` with three prompts: *drive-app* (create, open, read, act, verify, destroy, with the error recovery loop), *drive-web* (open\_url, targets, web indices), *hand-off-to-human* (pause with reason, wait, read handoff).
* `resources/list` exposing `spaceo://docs/troubleshooting`, `spaceo://docs/coordinates`, `spaceo://schema`, and `spaceo://doctor` (a live, redacted doctor report) so an agent can self-diagnose without shelling out.
* A `SKILL.md` generated from the same source, printed by `spaceo skill`, so Claude Code and Codex users can install it in one step. Keep the README's tool section, the server instructions, and the skill generated from one Markdown source to stop drift (this also addresses SPAO-170).

#### Where

* `Sources/SpaceOMCP/MCPServer.swift`: `prompts/list`, `prompts/get`, `resources/list`, `resources/read`; capabilities advertised in `initialize`.
* New `Sources/SpaceOMCP/Playbook.swift` holding the Markdown as string literals generated at build time from `docs/playbook/*.md` by a small script in `scripts/`.
* `scripts/mcp-smoke.mjs`: assert prompts and resources round-trip.

#### Verify

Smoke test; a doc-drift test that fails when the README tool list and `tools/list` differ.

## Suggested sequencing Four increments, each with a user-visible exit criterion

| Increment | Items | Exit criterion |
| --- | --- | --- |
| **1. Agent ergonomics** two to three weeks | 9 find + truncation, 14 element points, 15 recovery hints, 17 idempotent open, 12 read\_text, 7 open\_url, 8 wait\_for, 34 verdict sentence, 36 prompts and resources | The computer-use matrix completes the fixture flows with at least 30% fewer tool calls and no full-screen re-reads after typing. All additive; no protocol break. |
| **2. Setup and daemon home** two weeks | 2 launcher attribution, 1 interactive setup, 4 daemon restart, 6 LaunchAgent, 3 client config, 25 doctor --fix, 21 accept loop, 20 idle writes, 22 disk hygiene | A new user on a clean Mac reaches a passing self-test without opening the docs; an upgrade with an open session does not lose it. |
| **3. Human console** three weeks | 27 no stream restart, 26 state and zoom, 28 action overlay, 32 handoff note, 23 event stream, 31 names and grouping, 24 notifications, 5 empty-state walkthrough | An operator can watch three agents, see each action land within 100 ms, take over, leave a note, and hand back, all without reading the manual. |
| **4. Depth** ongoing | 13 clipboard broker, 10 incremental reads, 11 batches, 18 typing ergonomics, 19 annotated screenshots, 16 presets, 29 copy and drop, 30 menu bar and mini monitor, 33 recording, 35 attention mitigations | Each ships with its own live evidence record under `docs/validation/`. |

Items 21 and 23 are the only ones with a dependency chain: the concurrent accept loop must land before the event stream, and the event stream makes items 24, 28 and 33 substantially simpler. Everything else can be picked up independently.

## Guardrails that apply to every item Carried over from AGENTS.md and the release audit

* **No new private API surface.** Every proposal above uses public frameworks or the existing bridges. If an implementation is tempted toward a private focus, pointer or display-origin call, the item is wrong, not the rule.
* **Never turn an attempt into a success claim.** New receipts (paste route, wait outcome, batch step, handoff delivery) report confirmed, unconfirmed or refused, in that vocabulary.
* **Keep CLI, protocol, MCP schema, limits, lease handling and help text aligned** for every new command; `CLISpecTests`, `schema --json` and the smoke suite's tool count are the tripwires.
* **Bound everything** at the public boundary: step counts, wait deadlines, clipboard bytes, recording size, event ring size, connection concurrency.
* **Safe tests stay deterministic.** Each item names its deterministic test; live evidence is separate and a skipped live test is never counted.
* **Host changes need consent.** LaunchAgent install, client config writes, doctor fixes and setup remediations prompt on a TTY and require `--yes` otherwise.
* **Attention, not security.** None of this changes the uid trust boundary; the clipboard broker, event stream redaction and notifications are coordination features and are documented as such.

Generated from a source and documentation review of the SpaceO repository at commit `e44f732`. Ticket ids SPAO-201 to SPAO-221 are proposals and do not yet exist in `TICKETS.md` or `PRODUCT_BACKLOG.md`.
