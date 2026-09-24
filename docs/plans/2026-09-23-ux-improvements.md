# SpaceO — UX improvement round, 23 September 2026

Thirty-two improvements across every surface of SpaceO: the agent's tool loop, session lifecycle, versions and
upgrades, the developer CLI, and the Viewer the human supervises from. Every item starts from something observed
by *using* the product or by reading the code that runs it, and says what changed, where it lives, and how
it was verified. This round follows the 36-item plan of 16 September
(<2026-09-16-ux-improvements.html>). None of those items is repeated here.

Date: 23 September 2026
Base commit: `8bfc7e9` (1.1.1 prepared)
Ticket range: SPAO-240 – SPAO-271
Author: product/engineering review and implementation performed with Claude Code

## Contents

1. [How this round was found](#method)
2. [Summary matrix](#matrix)
3. [A. First contact: launching an app (1, 2)](#launch)
4. [B. The agent's working loop (3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 32)](#loop)
5. [C. Session lifecycle and endings (13, 14, 15, 16, 17, 18, 19)](#lifecycle)
6. [D. Versions, upgrades and the developer CLI (20, 21, 22, 23, 24)](#dev)
7. [E. The Viewer: supervising agents (25, 26, 27, 28, 29, 30, 31)](#viewer)
8. [Verification performed](#verification)
9. [What remains](#next)

## How this round was found Using the product first, then auditing every surface

SpaceO has three users, and each item names the ones it serves:

* **The agent.** Its interface is the MCP tool list, every response and every error string. Its costs are round trips, context tokens and ambiguity.
* **The developer.** They install and upgrade SpaceO, wire up MCP clients, and script the CLI.
* **The human operator.** They supervise several agents in the Viewer, take control, type the password the agent can't, and hand back.

The round began by **driving SpaceO as an agent** on this Mac. We used the installed 1.0.0 MCP server
that Claude Code was actually launching, and then the 1.1.1 source build on a throwaway daemon socket. We created
sessions, launched Calculator and TextEdit, read screens, clicked, typed, pressed menu items through Accessibility,
verified isolation and destroyed sessions. Five findings came straight out of those runs:

* Every 1.1.1 launch failed (item 1).
* TextEdit's Open panel stalled the first read (item 2).
* The user's own menu bar appeared on the agent's display (item 3).
* Each click cost about 1.2 KB of boilerplate (item 5).
* This machine's MCP client was silently one version behind (item 20).

Four read-only audits then covered the MCP surface, the CLI and setup, the daemon lifecycle, and the Viewer. They produced 57
code-verified findings. We deduplicated them against the previous round, the `AE-001…AE-211` efficiency log and the open backlog,
merged them into the 32 items below, and implemented them. Each item keeps the project's non-negotiables:

* no private-API expansion;
* no activation, pointer warping or display-origin mutation;
* bounded inputs everywhere;
* no attempted action reported as a success;
* leases treated as coordination, never as security.

**32**improvements, SPAO-240 – 271

**5**surfaces: launch, agent loop, lifecycle, CLI, Viewer

**4 + 1**audits plus hands-on agent sessions

**P0 × 5**blocked the product claim on this host

## Summary matrix P0 blocks the product claim · P1 blocks a credible v1 · P2 quality

| # | Improvement | Surface | For | Priority | Status |
| --- | --- | --- | --- | --- | --- |
| 01 | [Apps launch again: a busy Accessibility answer is retried, not fatal](#i1) | First contact: launching an app | agent, developer | P0 | Implemented |
| 02 | [Clean-slate launches: an untitled document, never the user's own windows](#i2) | First contact: launching an app | agent, human | P1 | Implemented |
| 03 | [Menu bar access: spaceo\_menu lists and presses an app's menus without activating it](#i3) | The agent's working loop | agent | P1 | Implemented |
| 04 | [Actions return fresh element indices (observe)](#i4) | The agent's working loop | agent | P1 | Implemented |
| 05 | [Receipts that say what happened: compact by default, honest outcome first](#i5) | The agent's working loop | agent | P1 | Implemented |
| 06 | [The focused (or modal) window is the default target](#i6) | The agent's working loop | agent | P1 | Implemented |
| 07 | [Readable control state, and web reads never print password values](#i7) | The agent's working loop | agent, human | P0 | Implemented |
| 08 | [Label matching by name, and a way to wait for the human](#i8) | The agent's working loop | agent | P2 | Implemented |
| 09 | [Typing follows the agent's last web click](#i9) | The agent's working loop | agent | P2 | Implemented |
| 10 | ["My session" is implicit, and the session list says whose is whose](#i10) | The agent's working loop | agent | P1 | Implemented |
| 11 | [Errors in the agent's language](#i11) | The agent's working loop | agent | P1 | Implemented |
| 12 | [A lean tool catalogue](#i12) | The agent's working loop | agent | P2 | Implemented |
| 13 | [Reclaim a session after the agent's client restarts](#i13) | Session lifecycle and endings | agent, human | P1 | Implemented |
| 14 | [A crashed app is reported as a crash, not "no windows yet"](#i14) | Session lifecycle and endings | agent | P1 | Implemented |
| 15 | [A full pool says who holds it and when to retry](#i15) | Session lifecycle and endings | agent, human | P2 | Implemented |
| 16 | [Every ending explained: destroy summaries, recovery logs, real idle time](#i16) | Session lifecycle and endings | agent, human, developer | P2 | Implemented |
| 17 | [Truthful PARTIAL verdicts](#i17) | Session lifecycle and endings | agent | P1 | Implemented |
| 18 | [Sessions notice sleep, wake and display changes](#i18) | Session lifecycle and endings | agent, human | P2 | Implemented |
| 19 | [Promised events are actually emitted](#i19) | Session lifecycle and endings | agent, human | P2 | Implemented |
| 20 | [Version drift is loud everywhere](#i20) | Versions, upgrades and the developer CLI | developer, agent, human | P0 | Implemented |
| 21 | [Upgrades that work against an older daemon](#i21) | Versions, upgrades and the developer CLI | developer | P1 | Implemented |
| 22 | [A scriptable CLI: env session/lease, one JSON envelope, meaningful exit codes](#i22) | Versions, upgrades and the developer CLI | developer | P2 | Implemented |
| 23 | [Help that helps, and a doctor that tells the truth](#i23) | Versions, upgrades and the developer CLI | developer | P2 | Implemented |
| 24 | [setup --client claude-code works on real machines](#i24) | Versions, upgrades and the developer CLI | developer | P2 | Implemented |
| 25 | [Take Control works for an agent that asked for help](#i25) | The Viewer: supervising agents | human, agent | P0 | Implemented |
| 26 | [Pasting a secret: Control stays on, and the secret doesn't linger](#i26) | The Viewer: supervising agents | human | P0 | Implemented |
| 27 | ["Agent needs you" is impossible to miss](#i27) | The Viewer: supervising agents | human | P1 | Implemented |
| 28 | [Know where your keys go, and know when the picture is stale](#i28) | The Viewer: supervising agents | human | P1 | Implemented |
| 29 | [Daemon state banner; selection survives reconnects](#i29) | The Viewer: supervising agents | human | P2 | Implemented |
| 30 | [Take Control from anywhere, and a keyboard-first Session menu](#i30) | The Viewer: supervising agents | human | P2 | Implemented |
| 31 | [An event list and VoiceOver that read like English](#i31) | The Viewer: supervising agents | human | P2 | Implemented |
| 32 | [Text reads are text: read\_text drops control state values](#i32) | The agent's working loop | agent | P2 | Implemented |

## A. First contact: launching an app Before this round, every app launch failed on 1.1.1

### 01 Apps launch again: a busy Accessibility answer is retried, not fatal

P0SPAO-240agentdeveloperImplemented

#### Problem, as experienced

Driving the 1.1.1 source build as an agent, **every** launch failed within about 1.5 s,
whether the app was Calculator or TextEdit:

```
[operation_failed] session 'agent-2' was created (keep its lease), but launching Calculator failed:
accessibility traversal stopped (provider): incomplete window discovery: window count is unavailable.
Narrow the target window or retry after the application responds.
```

The 1.1.1 window discovery (`AXWindowDiscovery.windowCount`) turns any non-success Accessibility
status into a provider failure. `WindowReadiness.wait` retried only `.deadline` stops, so the
`kAXErrorCannotComplete` (−25204) that a still-registering app returns for a few hundred
milliseconds aborted the launch. The same transient error later failed `spaceo verify` once in three
runs on a healthy TextEdit session. The daemon had both permissions, and `doctor` reported "can drive: yes".

#### What changes

* Retry `kAXErrorCannotComplete` on the window-count and window-page calls a bounded three times, 40 ms apart
  (`AXWindowDiscovery.retryingBusy`). Every discovery caller benefits: launch, placement, verify, waits.
* Presence waits (`WindowReadiness.wait`) retry provider failures within their budget, but a failed read
  still never becomes an empty poll. If the deadline ends on a failure, that failure is rethrown with its AX error code.
* Error details now include the AX status (`AXError -25204`), so the next report is diagnosable.

#### Where it lives

* Sources/SpaceOKit/AXWindowDiscovery.swift — `retryingBusy`, status in details
* Sources/SpaceOKit/WindowReadiness.swift — provider-failure retry + rethrow at deadline

#### How it is verified

* `WindowReadinessTests`: transient failure then success; persistent failure rethrown at the deadline
  (never an empty poll); a later confirmed-empty read replaces an earlier failure; busy retry is bounded and
  applies only to `cannotComplete`.
* Live on this host (throwaway socket): Calculator launched in 2.1 s, TextEdit in 1.4 s, then read → click → type → destroy.

### 02 Clean-slate launches: an untitled document, never the user's own windows

P1SPAO-241agenthumanImplemented

#### Problem, as experienced

TextEdit launched into its *Open* panel. That panel is drawn by a separate system service. Reading it took the
whole 3 s Accessibility budget and returned the user's `/tmp` file list as 120 text fields:

```
121 actionable element(s) in window 986
  note: this read is INCOMPLETE (traversal_budget) …
    [1] TextField — spaceo-build
    [2] TextField — oldpool.json …
```

An app that restores windows would also have reopened the *user's* documents onto the agent's display. And
quitting the separate instance could overwrite the restoration state the user's next launch depends on.

#### What changes

* A plain AppKit app launched with no custom arguments receives per-process argument-domain defaults.
  `-ApplePersistenceIgnoreState YES` skips restoring the user's windows.
  `-NSQuitAlwaysKeepsWindows NO` stops quit from overwriting the user's saved window state.
  When no files are given, `-NSShowAppCentricOpenPanelInsteadOfUntitledFile NO` opens an untitled
  document instead of the Open panel.
* These settings apply only to the launched process. The user's preferences and saved state are never written.
* Electron, Qt and Java apps are excluded, because they can read the value words as documents to open.
  Chromium and VS Code keep their managed launch paths. Caller-supplied `arguments` always take precedence.

#### Where it lives

* Sources/SpaceOKit/AppLauncher.swift — `cleanSlateArguments`, `acceptsDefaultsArguments`

#### How it is verified

* `CleanSlateLaunchTests`: argument pairs, files vs no files, fixture bundles for AppKit / Electron / Qt / Java / no principal class.
* Live: TextEdit now opens directly to "Untitled"; read\_screen returns its 21-control format bar in 50 ms.

## B. The agent's working loop What an LLM spends its round trips and tokens on

### 03 Menu bar access: spaceo\_menu lists and presses an app's menus without activating it

P1SPAO-242agentImplemented

#### Problem, as experienced

The agent's app is never frontmost, so the menu bar drawn on the agent's display belongs to the
*user's* app (the screenshot showed "T3 Code (Nightly) File Edit View Window Help"). Accessibility walks
are rooted at windows, so commands such as *File › Export as PDF…*, *Format › Make Plain Text* or
*View › Show Sidebar* were unreachable unless the agent guessed a shortcut.

#### What changes

* A new daemon command `menu` with the MCP tool `spaceo_menu` and the CLI `spaceo menu`.
  With no path it lists the top-level menus. A path lists that menu's items with enabled/checked state, submenu
  markers and shortcuts. `press: true` performs AXPress on the leaf item.
* This was verified live before implementation. Pressing TextEdit's File › New AXMenuItem created an "Untitled"
  window while the user's frontmost app stayed the same.
* Safety: the Apple menu (Log Out, Shut Down, Force Quit) and Services submenus are refused outright. Disabled items and
  submenu headers cannot be pressed. Isolation is snapshotted before and after, and containment is re-swept.
  All inputs are bounded and a lease is required.

#### Where it lives

* Sources/SpaceOKit/AXMenu.swift (new)
* Sources/SpaceOKit/SessionManager+Menu.swift (new)
* Protocol — `menu` in `ownerScopedMutations`
* MCPServer `spaceo_menu`; CLI `spaceo menu [TITLE…] [--press] [--pid N]`

#### How it is verified

* `AXMenuTests` (15): listing, path matching, shortcuts, refusal of the Apple, Services, Hide Others and Show All items, bounds; `InteractionCommandTests`: lease-before-validation, refused while paused, MCP and CLI mapping.
* Live on this host: File › New pressed through Accessibility without activating TextEdit (see Verification).

### 04 Actions return fresh element indices (observe)

P1SPAO-243agentImplemented

#### Problem, as experienced

Every click, type, key, scroll, move and drag invalidates the accessibility snapshot. That is correct, because
stale indices are dangerous. But it means an agent must spend a `spaceo_read_screen` round trip
before its next indexed action, and a `run_steps` plan like click 3 → type → click 5 fails at step 2.

#### What changes

* Action tools accept `observe: "none" | "diff" | "full"`, defaulting to `diff`. After a successful
  native action, the MCP server reads the window again as a diff against the last snapshot this connection saw.
  It appends the result under `after action:`, so the new indices are immediately usable.
* A failed observation never turns a successful action into an error. The receipt says `observe: unavailable (reason)`.

#### Where it lives

* Sources/SpaceOMCP/MCPServer.swift
* Sources/SpaceOMCP/MCPConnectionMemory.swift (new) — bounded per-connection snapshot and display memory

#### How it is verified

* `MCPCompactReceiptTests.testObservePlansADiffAgainstTheLastSnapshotForThatWindow` and the failure-degrades-to-note cases. The daemon's diff history survives the post-action index invalidation, so no daemon change was needed.

### 05 Receipts that say what happened: compact by default, honest outcome first

P1SPAO-244agentImplemented

#### Problem, as experienced

A successful Calculator click returned about 1.2 KB. The first line was
`readiness: ready; blockers=[]; visibility=unknown; presentation=unverified (fps=null)`, followed by a 64-hex
geometry token, a `displayTarget` JSON with a UUID and a 64-hex topology hash,
`completion=operation_completed_postcondition_not_asserted`, and seven isolation lines of evidence prose.
The playbook tells agents to require a `confirmed` receipt, but that word never appeared.
The daemon computed the outcome and sent it only to the event stream.

#### What changes

* `ActionReceipt.outcome` (confirmed / unconfirmed / refused) is set wherever a receipt is built
  and rendered first, for example `click: confirmed (accessibility-action)`.
* An intact isolation verdict renders as one line, `isolation: intact (6/6 checks covered)`. A partial verdict shows only the
  checks that did not pass, and a breach shows everything. Readiness appears only when blocked. The display target
  appears only when it changed. Action receipts omit the geometry token.
* `verbose: true` on a call, or `SPACEO_MCP_VERBOSE=1` for a connection, restores the full audit trail.
* Destroy summaries, pool holders, menus, window markers and idle time render in the same compact style.

#### Where it lives

* Sources/SpaceOMCP/MCPPresentation.swift (new) — pure rendering helpers
* Sources/SpaceOMCP/MCPServer.swift render / renderIsolation
* SessionManager `enrich` keeps the handler's outcome

#### How it is verified

* `MCPCompactReceiptTests.testIntactClickRendersUnder300BytesAndVerboseRestoresTheTable`, partial and breach rendering, destroy summary and capacity rendering; `InteractionStateTests` covers the receipt-outcome rule (`SessionManager.receiptOutcome`).

### 06 The focused (or modal) window is the default target

P1SPAO-245agentImplemented

#### Problem, as experienced

Tool text says "read the focused window", but the session picked the *largest* window by area. With a "Save changes?"
alert up, `read_screen`, waits and screenshots targeted the document behind it, and
`press_key return` failed with a terminal `bad_request`: "window 111 is not where this application's
keystrokes go — it reports window 222 as focused".

#### What changes

* The default target is now the owning app's `AXFocusedWindow` when that window belongs to the session, with the largest window as the fallback.
* Window listings mark `[focused]`, `[modal]` and `[default]`.
* Keystroke misrouting gets its own code, `focus_elsewhere`, with a recovery that reads the focused window.

#### Where it lives

* AgentSession window resolution
* InputRouter keystroke targeting
* Protocol `WindowInfo.focused/modal/defaultTarget`
* Errors.swift `focusElsewhere`

#### How it is verified

* Pure default-window selection tests and a keystroke-targeting error-code test.

Only the focused window carries a `modal` value; other windows report it as unknown. Resolving the default costs one bounded 0.5 s Accessibility read.

### 07 Readable control state, and web reads never print password values

P0SPAO-246agenthumanImplemented

#### Problem, as experienced

Native checkboxes render as `CheckBox — bold · value: 0`, and focus, expansion and selection are never shown.
On web pages, `labelSource` fell back to `el.value` before `placeholder`, so an
unlabelled `<input type=password>` printed the password in `read_screen` and
`find`. The native path deliberately hides secure fields; the web path did not.

#### What changes

* Outline state tokens: `[checked]`, `[unchecked]`, `[mixed]`, `[focused]`, `[expanded]`, `[collapsed]`, `[selected]`.
* Web items carry the input type, checked state and selected option. Values are never read for password
  fields or for `cc-*` and `one-time-code` autocomplete fields.

#### Where it lives

* AXTraversal.swift rendering
* ChromiumObservation.swift

#### How it is verified

* `ChromiumFieldStateTests.testUnlabeledSecretFieldsNeverExposeTheirValue` (password, card-number, one-time-code, current/new-password) and state-token rendering in `InteractionStateTests`; state-only changes now appear in `since` diffs.

### 08 Label matching by name, and a way to wait for the human

P2SPAO-247agentImplemented

#### Problem, as experienced

`wait_for element_label "Name"` never matched a field, because it compared against the composed line
`TextField — Name · value: Bob`. Paused agents were told to "keep calling spaceo\_session\_heartbeat", even though MCP
already renews leases every 10 s, and to poll `session_list` for fields the MCP output never prints.

#### What changes

* Element waits and click-by-label match the accessible name, with `match: exact | contains` and an optional role filter.
* `window_title_contains` returns the matched window id.
* A new `session_resumed` wait condition works while paused and returns the human's hand-back note. The heartbeat instructions are removed.

#### Where it lives

* AXTree.swift / WaitCondition.swift
* SessionManager+Ergonomics wait path
* MCP wait\_for schema, playbook

#### How it is verified

* `WaitConditionTests` covers name, contains and role matching, plus `session_resumed` being allowed while paused.

### 09 Typing follows the agent's last web click

P2SPAO-248agentImplemented

#### Problem, as experienced

After `click element:"w3"` on a page field, a plain `spaceo_type` went to the browser's native
chrome unless the agent remembered `web:true`. Nothing warned, and the echoed "window text now" was the
address bar.

#### What changes

* When `web` is omitted, the window has a DevTools bridge, and the session's last pointer action there hit a
  `wN` element, typing and keys route to the page and report `route=chromium-devtools (auto)`.
  `web:false` forces native input.

#### Where it lives

* SessionManager type/key routing

#### How it is verified

* A pure routing-decision test.

A coordinate click that DevTools delivered into the page also counts as a page click. Held keys and separate down/up presses stay native.

### 10 "My session" is implicit, and the session list says whose is whose

P1SPAO-249agentImplemented

#### Problem, as experienced

The rule "omit `session` when only one exists" counted every session on the machine, so a second agent's
session broke every call with `2 sessions exist; name one explicitly`, which listed no ids.
`session_list` showed other agents' redacted sessions as if they were empty, and never marked the caller's own.

#### What changes

* The MCP server fills `session` from the single lease its connection holds. With several leases it lists them.
  The daemon defaults to the session a supplied lease covers, and its ambiguity error lists ids.
* `session_list` marks `[yours]` and `[another controller; contents redacted]` and shows idle time and lease expiry.

#### Where it lives

* MCPServer controller context + describe
* SessionManager session resolution

#### How it is verified

* `ControllerClientTests` covers one lease, two leases and redacted rendering; the daemon ambiguity text is tested too.

### 11 Errors in the agent's language

P1SPAO-250agentImplemented

#### Problem, as experienced

Inside MCP, the agent was told `next action: spaceo windows --timeout 10 --help`. Daemon messages said
"run `spaceo ax` again", "click by --x/--y" and "Pick a Button from `spaceo ax`". Recovery hints on thrown errors
lost their session. `session_id` was rejected with no suggestion. The per-call trace id reached only stderr.

#### What changes

* MCP drops the CLI-form `next action` whenever structured recovery exists; otherwise it maps CLI verbs to tool names.
  A contract test renders every error and forbids `spaceo …` and `--help`.
* Daemon wording is neutral and works for both surfaces. Recovery hints are bound to the request's session and window on every failure path.
* Argument errors add `accepted: …` and `did you mean 'session'?`. `session` is accepted on create.
* Every MCP error ends with `trace: <id>` for log correlation.

#### Where it lives

* MCPServer renderFailure + argument validation
* Errors.swift, AXSnapshotCache.swift, SessionManager messages

#### How it is verified

* A render contract test over all error cases, a did-you-mean test, and a recovery-binding test.

### 12 A lean tool catalogue

P2SPAO-251agentImplemented

#### Problem, as experienced

`tools/list` held 32 tools in 37.6 KB, about 9,400 tokens loaded into every conversation. Some descriptions
spent their budget on internals ("late frames are discarded and pending native work cannot accumulate"). Three
`controller_*` parameters no agent needs were advertised. The useful `label` argument on click was never mentioned.

#### What changes

* Descriptions are capped at 400 characters, with internals moved to the `spaceo://docs` resources.
  Every property has a description. `label` is documented. `controller_*` is accepted but no longer advertised.
* A test holds the whole catalogue to 30 KB even after this round's new tools.

#### Where it lives

* Sources/SpaceOMCP/MCPServer.swift tool schemas

#### How it is verified

* Catalogue budget, per-description and per-property tests; the MCP smoke tool count.

The budget test holds `tools/list` to 31 KB. That is 34 tools after adding `spaceo_menu` and `spaceo_session_claim`; the round started from 37.6 KB for 32 tools.

### 32 Text reads are text: read\_text drops control state values

P2SPAO-271agentImplemented

#### Problem, as experienced

A live `read_text` of a TextEdit window returned the document followed by `0 0 0 0 Clear Clear font size 1 0 0 0 …`:
the format bar's checkbox states mixed into the document text an agent was trying to verify.

#### What changes

* Checkboxes and radio buttons contribute their accessible names, never their 0/1/2 state value.

#### Where it lives

* Sources/SpaceOKit/AXTraversal.swift `allText`, AXTree.swift `stateValuedRoles`

#### How it is verified

* `AXTraversalTests.testAllTextReadsControlNamesInsteadOfTheirStateValues` (the state value is never even requested).

## C. Session lifecycle and endings Sessions should survive ordinary accidents, and every ending should be explained

### 13 Reclaim a session after the agent's client restarts

P1SPAO-252agenthumanImplemented

#### Problem, as experienced

When Claude Code restarts, the MCP process exits at EOF. The janitor marks the session abandoned within about 3 s and
quits its apps about 30 s later. `TROUBLESHOOTING.md` said "TTL (default 300 s) plus 30 s". A new conversation
could not take the session back; its apps and their state were gone.

#### What changes

* `orphan_grace_seconds` on create (30–1800; MCP defaults to 120).
* A new `session.claim` (`spaceo_session_claim`, `spaceo session claim`) takes over an abandoned,
  not-yet-reclaimed session with a fresh lease and keeps its apps. It is refused for live-owned or already-reclaimed sessions.
  This follows the project's model that leases coordinate clients rather than secure them.
* `session_list` shows the remaining grace, and the documentation is corrected.

#### Where it lives

* Sources/SpaceOKit/SessionManager+Lifecycle.swift (new)
* AgentSession controller runtime
* Protocol `DaemonCommand.leaseIssuing`, `SessionInfo.graceRemainingSeconds`
* MCPServer `spaceo_session_claim`; CLI `spaceo session claim`
* docs/SESSION\_RECOVERY.md, docs/TROUBLESHOOTING.md

#### How it is verified

* `SessionClaimTests` (9): claim within grace, refusals for live-owned, ended, detached, unknown and tearing-down sessions, janitor race; `ControllerClientTests` covers MCP and CLI lease storage and the MCP 120 s default.

A claim is accepted when the controller process exited *or* the lease expired, because in both cases the old lease can never renew. The janitor re-checks reclaimability under the command gate, so a claim that lands between its scan and its destroy wins.

### 14 A crashed app is reported as a crash, not "no windows yet"

P1SPAO-253agentImplemented

#### Problem, as experienced

After a failed launch or an app crash, every tool answered
`[window_not_ready] … has no windows yet` with the recovery "call spaceo\_list\_windows with timeout 10, retry once a
window is listed". That wait can never succeed. We reproduced this live: eight consecutive calls failed identically.

#### What changes

* Each session keeps a bounded list of recently exited apps (name, pid, time, status).
* With no live app, the error is `application_exited: TextEdit (pid 123) exited at …` (relaunch). If no app was ever
  attached, it is `no app is attached to this session; open one`, with recovery pointing to `spaceo_open_app`.
* `SessionInfo.exitedApps` and `lifecycleReason = app_exited`.

#### Where it lives

* AgentSession reapExitedApps + window resolution
* Protocol `ExitedAppInfo`

#### How it is verified

* Janitor reap tests extended to cover the next resolve's error code and message.

Exit status is never reported, because SpaceO launches through LaunchServices and is not the parent process; no public API exposes another process's exit status.

### 15 A full pool says who holds it and when to retry

P2SPAO-254agenthumanImplemented

#### Problem, as experienced

`[bad_request] session budget exhausted (limit 16)`. The playbook maps `bad_request` to "fix your
call". A transient rate limit and a hard cap produced the same message, and nothing said who held capacity or that an
abandoned session would free a tile in seconds.

#### What changes

* A new `resource_limit` error with a kind (sessions, displays or creation\_rate), `retryAfterSeconds`, and
  `holders` (session, owner label, age, idle time, abandoned, frees-in). Holders never include app or window content.
* Recovery: `spaceo_pool_status`, then retry after N seconds.

#### Where it lives

* Sources/SpaceOKit/ResourceBudget.swift, Errors.swift
* Sources/SpaceOKit/SessionManager+Failures.swift (new)
* DisplayPool rate-window hint

#### How it is verified

* Budget tests assert the code, kind and retry-after for rate and capacity limits; holder redaction is tested.

### 16 Every ending explained: destroy summaries, recovery logs, real idle time

P2SPAO-255agenthumandeveloperImplemented

#### Problem, as experienced

Destroy answered `destroyed 'x'` whether the owner, an operator or the janitor did it. A 6-second destroy
(TextEdit waiting on an unsaved-document prompt) looked the same as an instant one. Recorder finish errors were swallowed. Post-crash
recovery quit apps without a log line. Heartbeats overwrote `lastActivityAt` every 10 s, so a forgotten
session always looked active.

#### What changes

* `DestroySummary` returned and rendered: reason, apps quit, forced and released, duration, action count,
  recording path or error, clipboard cleared, profiles removed. The reason is also in the `session.destroyed` event.
* `recovery.cleaned` is logged and evented.
* `lastOwnerActionAt` and `idleSeconds` ignore heartbeats.

#### Where it lives

* SessionManager destroy + janitor
* DetachedSessionRecovery / SessionRecoveryCoordinator
* DaemonLog
* AgentSession controller runtime

#### How it is verified

* `DestroySummaryTests` (4); `SessionRecoveryCoordinatorTests.testDetachedCleanupIsLoggedAnnouncedAndSummarizedByName`; idle assertions in `LifecycleEventTests`.

Idle-based reclamation (`janitor_idle`) was not implemented; only visibility of idle time was. `lastOwnerActionAt` is runtime state and is not persisted to the ledger.

### 17 Truthful PARTIAL verdicts

P1SPAO-256agentImplemented

#### Problem, as experienced

The partial-verdict cause was inferred by substring-matching "accessibility" in evidence text. The production evidence
for an unavailable focused-app proxy always contains that word, so hosts *with* the grant were told to grant
Accessibility. Every partial verdict gave the same advice.

#### What changes

* The cause comes from the daemon's actual grant state.
* The next step depends on the cause, and tells the agent to continue for reversible steps but request strict isolation for irreversible ones.

#### Where it lives

* IsolationSummary.swift, IsolationSnapshot report construction

#### How it is verified

* `IsolationSummaryTests` uses the production evidence string with the grant present.

### 18 Sessions notice sleep, wake and display changes

P2SPAO-257agenthumanImplemented

#### Problem, as experienced

Nothing observed wake or display reconfiguration, and the janitor never re-checked `stage.isValid`. The
troubleshooting guide itself uses display sleep/wake to rebuild the display graph, but live sessions were never revalidated
afterwards.

#### What changes

* An injectable observer for `NSWorkspace.didWake` and CoreGraphics display reconfiguration (public API) that re-validates every stage and sweeps containment.
* A session on a lost display gets `lifecycleReason = display_lost` and paused input with a reason, and a `session.display_lost` event is emitted.

#### Where it lives

* Sources/SpaceOKit/DisplayEnvironmentObserver.swift (new, public API only)
* SessionManager+Lifecycle revalidation
* Sources/spaceo/main.swift daemon start

#### How it is verified

* A fake stage whose validity flips pauses input and emits the event; nothing else changes on a valid stage.

Revalidation is tested through `SessionManager.revalidateDisplays`. The real NSWorkspace and CoreGraphics registration needs a live sleep/wake check on an idle host. A `display_lost` session is paused, not destroyed automatically.

### 19 Promised events are actually emitted

P2SPAO-258agenthumanImplemented

#### Problem, as experienced

`DaemonEvent.kind` documents `window.escaped`, `window.reparked`, `lease.expiring`,
`teardown.progress` and `handoff.note`. None of them was emitted. A window that refused to go back into the
tile surfaced only as a count in `verify`.

#### What changes

* Emit `window.escaped` on the first refusal and `window.reparked` on a successful re-park, and attach a one-shot
  note to the owner's next response.
* Emit `lease.expiring` at 80% of the lease TTL.
* Remove from the documentation any kind that is still not emitted.

#### Where it lives

* WindowWatcher.swift, EventBus.swift, AgentSession

#### How it is verified

* `LifecycleEventTests` (4): escape and re-park events, the one-shot ambient note, `lease.expiring` once per expiry.

## D. Versions, upgrades and the developer CLI The machine this review ran on was stuck on version drift it could not see

### 20 Version drift is loud everywhere

P0SPAO-259developeragenthumanImplemented

#### Problem, as experienced

This machine's Claude Code config launches `~/.local/bin/spaceo mcp` at **1.0.0**, which exposes 16 tools;
the source builds 1.1.1 with 32. The 1.0.0 daemon answered new commands with `unknown command 'find'`, which reads
exactly like a typo. The drift warning went only to the MCP server's stderr, which the agent never sees. `doctor`
did not print its own version or look at MCP client configs, and the Viewer showed nothing.

#### What changes

* The CLI warns on stderr (or in `warnings[]` with `--json`). Unknown commands from an older daemon become
  `daemon_outdated`, "the running daemon (1.0.0) predates `find`".
* MCP prepends a one-time warning to the first tool result.
* `doctor` prints the CLI version and path and gains an *MCP clients* section: it reads each client's configured
  spaceo path (read-only), runs `version`, and flags mismatches.
* The Viewer shows a daemon banner (item 29).

#### Where it lives

* Sources/spaceo/main.swift remote(); Sources/SpaceOKit/CLIContract.swift (new)
* Sources/SpaceOKit/MCPClientInspection.swift (new) — read-only client config inspection
* Sources/SpaceOKit/DoctorReport.swift (new)
* MCPServer first-result warning + `daemon_outdated`
* SpaceOViewer/ViewerWorkspaceStatus.swift (new)

#### How it is verified

* `CLIContractTests`, `CLIScriptingContractTests` (built CLI against an in-process fake daemon), `MCPClientInspectionTests`, `MCPCompactReceiptTests.testDriftWarningLeadsTheFirstResultOnlyAndRewritesUnknownCommands`, `ViewerStatusAggregateTests.testWorkspaceBannerFollowsConnectivityDrainingVersionAndRestart`.

### 21 Upgrades that work against an older daemon

P1SPAO-260developerImplemented

#### Problem, as experienced

`doctor` said "run `spaceo daemon restart --operator`", but restart sends `daemon.drain`, which
1.0.0 rejects, so the documented upgrade failed. `doctor --fix` suggested `--when-idle`, a flag that does
not exist. `make install` silently replaced the binary under a running daemon.

#### What changes

* When drain is unsupported, restart falls back to waiting (bounded, with progress) for zero sessions, or `--now`, then stop and start this build.
* The remedy text is fixed, and a test parses every `spaceo …` command quoted in a remedy against the CLI spec.
* `make install` reports "installed X over Y; the running daemon is still Y".

#### Where it lives

* Sources/SpaceOKit/DaemonRestart.swift (new)
* Sources/spaceo/HostCommands.swift (new)
* SetupRemedies.swift
* Makefile install

#### How it is verified

* `DaemonRestartTests`: drain path, old-daemon wait then stop, a daemon that never goes idle is left running, `--now`, refusal. A remedy-command sweep parses every quoted `spaceo …` command against CLISpec.

### 22 A scriptable CLI: env session/lease, one JSON envelope, meaningful exit codes

P2SPAO-261developerImplemented

#### Problem, as experienced

The setup guide repeats `--session try --lease UUID` on six consecutive commands. `--json` sometimes emitted
prose before the JSON. Every failure exited 1, and `spaceo wait … --timeout 5 && spaceo click …` clicked even
when the wait timed out, because the timeout exited 0.

#### What changes

* `SPACEO_SESSION` and `SPACEO_LEASE` act as defaults, and `session create --export` prints them for `eval`.
* `--json` always means exactly one JSON object on stdout, with sorted keys and an `ok` field; progress goes to stderr. Global flags are accepted before the subcommand.
* Exit codes: 2 usage, 3 daemon unavailable or outdated, 4 lease, 5 isolation, 6 wait not met. Text-mode errors print `next: …`.

#### Where it lives

* main.swift, CLIArguments.swift

#### How it is verified

* A table-driven JSON-envelope test, an exit-code mapping test, and an env-precedence test.

### 23 Help that helps, and a doctor that tells the truth

P2SPAO-262developerImplemented

#### Problem, as experienced

`spaceo help click` printed the global usage followed by "Options for spaceo help". `spaceo click --help` was 132 lines.
A daemon that answered slowly was reported "not running" and its displays "orphaned". The deliberately removed focus path showed as
`MISS`. `SpaceO displays : 7` was a display id that read like a count.

#### What changes

* `help <cmd>` and `<cmd> --help` print one command's usage, one line per flag, and examples.
  Every command is listed or deliberately hidden. `spaceo completions zsh|bash|fish` is generated from the spec.
* Doctor distinguishes a busy daemon from a stopped one, prints `n/a` for disabled capabilities, gives a `Next:` sentence,
  labels display ids as ids, and is grouped into sections, including the Viewer.

#### Where it lives

* Sources/SpaceOKit/CLIHelp.swift (new)
* Sources/SpaceOKit/DoctorReport.swift (new)
* Sources/spaceo/main.swift

#### How it is verified

* Usage contract tests and a golden test of the pure doctor renderer.

### 24 setup --client claude-code works on real machines

P2SPAO-263developerImplemented

#### Problem, as experienced

`claude` was looked up in three fixed directories, so it was "not found" under Homebrew-in-home or nvm. It registered at local
(project) scope, failed when an entry already existed (exactly the stale-entry case), and could register a `.build/` path that
`make clean` deletes.

#### What changes

* Resolve `claude` through `PATH`; register at user scope; remove and re-add an existing entry; warn about build-tree paths.

#### Where it lives

* MCPClientConfig.swift, main.swift setup

#### How it is verified

* Pure helper tests; `claude` is never invoked in tests.

## E. The Viewer: supervising agents The human's console for watching agents, taking control and handing it back

### 25 Take Control works for an agent that asked for help

P0SPAO-264humanagentImplemented

#### Problem, as experienced

An agent pauses itself with "needs 2FA code", and the human takes Control, types the code and releases. There was no hand-back sheet,
no note was delivered, and the banner still said "Agent paused itself". Worse, the agent could resume itself while the human
was typing. `beginHumanControl` skipped sessions that were already paused, and `endHumanControl` returned early when
it had paused none.

#### What changes

* Take Control now places an operator pause over an agent's own pause, tracks it, shows the hand-back sheet, and resumes with the note.

#### Where it lives

* Sources/SpaceOViewer/ViewerModel.swift begin/endHumanControl

#### How it is verified

* A control-plane test: a self-paused session receives the operator pause, the pending hand-back, and a resume carrying the note.

A deliberate choice: if Control is forced off (stream or permission loss), an agent that asked for help stays paused ("Still waiting for you") rather than being resumed with no one present.

### 26 Pasting a secret: Control stays on, and the secret doesn't linger

P0SPAO-265humanImplemented

#### Problem, as experienced

The paste confirmation was a modal sheet. The sheet became key, the canvas resigned key, and that ended Control mid-paste,
with the hand-back sheet colliding with it. After `clipboard.set` and ⌘V, the pasted text (often a password) stayed in the session's
clipboard broker, where the agent could read it with `clipboard_get`.

#### What changes

* Confirmation is now an inline canvas overlay ("Press ⌘V again to paste into …"), and resign-key does not end Control while a Viewer prompt is open.
* After the paste, the previous broker contents are restored, and the prompt says the text is not kept.

#### Where it lives

* ViewerModel+Clipboard.swift, SurfaceView.swift, ContentView.swift

#### How it is verified

* Pure `releasesOnResignKey` policy test; request order get → set(text) → key → set(previous).

The daemon has no clipboard-clear command, so an empty broker is restored as an empty string. Needs a live check that the inline prompt never takes key status.

### 27 "Agent needs you" is impossible to miss

P1SPAO-266humanImplemented

#### Problem, as experienced

With three or four agents running, one asking for help looked like any paused session: an amber dot, no notification, no badge,
and nothing in its sidebar row. "Resume All Agents" also lifted help requests, which looked like consent. "Reclaim" destroyed a session in one click.

#### What changes

* A default-on `agentNeedsHuman` notification with a Take Control action.
* A `needsHuman` status (hand icon) that ranks above amber, the reason shown in the sidebar, help requests sorted first, a Dock badge, and a VoiceOver announcement.
* Resume All skips help requests. Reclaim becomes "Clean Up…" behind a confirmation.

#### Where it lives

* NotificationPolicy.swift, ViewerStatusAggregate.swift, NavigatorView.swift, ViewerModel+Operations.swift, InspectorView.swift

#### How it is verified

* Notification policy, status aggregate and control-plane tests.

### 28 Know where your keys go, and know when the picture is stale

P1SPAO-267humanImplemented

#### Problem, as experienced

After Take Control, keys went to whichever window was frontmost on the stage, and the banner said only "Input captured". A stalled
capture stream still said "Live", so the human could be typing into a frozen picture.

#### What changes

* A live key destination in the banner, for example "Keys → Safari — Sign in", with a warning when it is not a session app.
* `ViewerStreamHealth` shows "Stalled · last update 6s ago" after about 3 s without samples, loudly while in Control, and the status-bar tooltip shows fps.

#### Where it lives

* ViewerInputController.swift, ContentView.swift, DisplayStream.swift, ViewerModel.swift

#### How it is verified

* A front-window-provider test and a fake engine that goes silent.

Needs a live check that ScreenCaptureKit sends idle samples on a static screen; if it does not, a still screen would show "Stalled" after 3 s.

### 29 Daemon state banner; selection survives reconnects

P2SPAO-268humanImplemented

#### Problem, as experienced

With the daemon down, draining, restarted or on a different version, the canvas could keep showing a frozen display with no banner.
After a daemon blip, the selection jumped to the newest session instead of the one being watched.

#### What changes

* A pure banner function (unreachable, draining, version mismatch, restarted) and selection restore from preferences on reconnect.

#### Where it lives

* ViewerModel.swift, ContentView.swift

#### How it is verified

* Select B, fail for 6 s, re-apply [A, B], and B is still selected; banner unit tests.

### 30 Take Control from anywhere, and a keyboard-first Session menu

P2SPAO-269humanImplemented

#### Problem, as experienced

Take Control on another session's tile only selected it. Pause/Resume, next/previous session, "go to the session that needs me",
Save Screenshot, Refresh and Destroy had no shortcuts. Clicking a notification in menu-bar-only mode opened no window.

#### What changes

* Pending control that begins once the stream starts.
* A Session menu: ⌘⇧P pause/resume, ⌘] / ⌘[, ⌃1–⌃9, ⌘⇧A attention, ⌘⇧S screenshot, ⌘R refresh, ⌘⌫ destroy.
* Notification actions request a window and deep-link to the session.

#### Where it lives

* ViewerApp.swift, ViewerModel.swift, ViewerNotifications.swift, MenuBarExtraView.swift

#### How it is verified

* Pure `ViewerSessionNavigation` tests and a notification-action model test.

⌃1–⌃9 can collide with macOS "Switch to Desktop N" when that shortcut is enabled.

### 31 An event list and VoiceOver that read like English

P2SPAO-270humanImplemented

#### Problem, as experienced

Each agent action appeared twice, details were raw `key=value`, intact isolation verdicts were shown as warnings, and 100
entries of action spam evicted pauses. VoiceOver read rows as "Session abc123. Status: Owned."

#### What changes

* Deduplication while the stream is connected, per-kind formatters, verdict-based severity, a this-session/all filter, a separate cap for non-action events, titles on links, and richer accessibility labels and announcements.

#### Where it lives

* ViewerModel+EventStream.swift, InspectorView.swift, ViewerModel.swift

#### How it is verified

* Control-plane ingest tests and presentation-label tests.

## Verification performed Deterministic suites, release gates, and live agent sessions on this Mac

| Check | Result |
| --- | --- |
| `make verify-release`: optimized build, the safe suite (live class excluded), Viewer install transaction checks, Node evidence tests, MCP smoke | Passed: 1,545 Swift tests with 0 failures (live `IntegrationTests` excluded, as `make test` does), Viewer install transaction checks, and MCP smoke over 34 tools covering validation, mutation safety and clean exit. |
| `swift build -c release -Xswiftc -warnings-as-errors` | Clean |
| `git diff --check` | Clean |
| `SPACEO_CODESIGN_IDENTITY=- make viewer` + `codesign --verify --deep --strict` | Valid on disk; satisfies its Designated Requirement |
| New deterministic suites | `WindowReadinessTests` (extended), `CleanSlateLaunchTests`, `ErrorGuidanceTests`, `DetachedSessionGuidanceTests`, `MCPCompactReceiptTests`, `SessionClaimTests`, `DestroySummaryTests`, `LifecycleEventTests`, `AXMenuTests`, `InteractionStateTests`, `ChromiumFieldStateTests`, `InteractionCommandTests`, `CLIContractTests`, `CLIHelpTests`, `CLIScriptingContractTests`, `DaemonRestartTests`, `DoctorReportTests`, `MCPClientInspectionTests`, `ViewerEventFormatterTests`, `ViewerSessionLabelAccessibilityTests`, plus additions to about 15 existing suites |

### Live agent sessions (throwaway daemon socket, release build)

We drove SpaceO the way an agent does, over MCP stdio against `/tmp/sux.sock`. Every session was destroyed, and no app was left running.

```
spaceo_session_create {app: TextEdit}      → run: confirmed (NSWorkspace) · window "Untitled" [default] · isolation: intact (6/6)
spaceo_read_screen                         → [1] CheckBox — bold [unchecked] … [11] CheckBox — align left [checked]
spaceo_menu {path: ["Format"]}             → [Format] Make Rich Text ⌘⇧T (disabled) …
spaceo_type {text: "hello from spaceo"}    → type: confirmed (per-pid-events)
                                             note: the app changed the typed text (auto-capitalisation …)
                                             after action: snapshot … changed (2) … Indices above are from the NEW snapshot
spaceo_menu {path: ["File","New"], press}  → menu: confirmed (accessibility-menu) · pressed File › New in pid … (⌘N)
spaceo_list_windows                        → window 5021 "Untitled 2" [focused] [default]
spaceo_click {session_id: …}               → did you mean 'session_id' → 'session'?
— connection A exits without destroying —
spaceo_session_list (connection B)         → session 'uxv' … [abandoned: spaceo_session_claim within 1m46s keeps its apps]
spaceo_session_claim {session: "uxv"}      → claimed 'uxv' … with 1 app(s) and 2 window(s) kept
spaceo_session_destroy                     → destroyed 'uxv' (owner): quit TextEdit; force-quit TextEdit; 6s
```

Four defects found in these runs were fixed in the same round, each with a regression test.
Menus were rendered twice. A single index shift listed 21 controls as changed. A refused
`AXPress` was reported as "no press action (available: AXPress)". An abandoned session gave no hint that it could be claimed.

**Incident during implementation.** This host now holds the Accessibility grant (attributed to T3 Code).
`IntegrationTests` gates only on `Capabilities().canDrive`, not on `SPACEO_LIVE`, so two
implementation agents that ran an unfiltered `swift test` executed the live suite on the active desktop. It
launched Chrome and TextEdit, created virtual displays, and recorded a real isolation breach: the agent app took the menu bar
and key focus, and the user was moved to an agent display's Space. Nothing leaked afterwards: no SpaceO display stayed online and
no test process was left running. Every later run used `make test` / `--skip SpaceOKitTests.IntegrationTests`.
**Follow-up recommended:** gate `IntegrationTests` on an explicit opt-in such as `SPACEO_LIVE=1` as well,
so a host that gains grants cannot silently turn a bare `swift test` into a live run.

## What remains Evidence that only a live, idle host can provide

* **Live Viewer checks** on a spare login or VM:
  + the inline paste prompt never takes key status;
  + the broker restores its contents after a paste into a real app;
  + ScreenCaptureKit sends idle samples on a static screen, otherwise a still screen shows "Stalled";
  + clicking a notification opens a window in menu-bar-only mode;
  + the Dock badge renders, and the key destination is accurate with real windows.
* **Wake and display reconfiguration** through the real NSWorkspace and CoreGraphics observers; only the revalidation path is unit-tested.
* **Menu presses in more apps** than TextEdit, in particular apps that build menus lazily (`menuNeedsUpdate`).
* **Qualification** is unchanged. `make test-live-full` and `make computer-use-check-full` on an eligible idle host with retained results are still required before any release claim; skipped live tests are not evidence.
* **Upgrade this machine.** Claude Code here still launches `~/.local/bin/spaceo` 1.0.0. Once installed, the new `doctor` MCP-clients section and the first-result drift warning will flag exactly this.
  The upgrade path is `make install` then `spaceo daemon restart --operator`, which now falls back correctly against a 1.0.0 daemon. Then restart the MCP client.

SpaceO UX round, 23 September 2026 · generated from the item table in the round's working notes ·
previous round: [16 September 2026](2026-09-16-ux-improvements.html) · change log: `CHANGELOG.md` [Unreleased]
