# Changelog

All notable user-visible changes are recorded here. SpaceO follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses the structure from
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Release qualification fixes

- Keep healthy display mutations from causing false query timeouts, retain display backings
  after failed cleanup preflight, and serve daemon display health from memory without journal I/O.
- Return per-file completion receipts when reopening files in Chromium partially fails, so
  clients can distinguish confirmed opens, unknown delivery and files never sent.
- Surface persistent display-safety latches in daemon health and `doctor`, with blocked readiness
  and recovery guidance. Report the actual wait for the shared creation budget.
- Use verified Space IDs when allocating a display, reject circuit-failed allocations, and use
  one total deadline for display retirement. Reused Chromium file opens now use background
  DevTools targets, with no LaunchServices fallback.

- Contain the September 25 display incident: refuse unsafe display graphs, coordinate creation
  across processes,
  persist lifecycle failures and creation budgets, and bound lifecycle waits even when display
  IPC stalls. Live tests now require reserved-host opt-in, stop after a failure, and have an
  external supervisor. These safeguards do not fix or guarantee prevention of Apple's driver
  panic; see `docs/DISPLAY_SAFETY.md`. The temporary macOS 27+ blanket quarantine was removed
  at the owner’s request; runtime checks and lifecycle safeguards remain enforced.
- Report exhausted Chromium startup deadlines as `launch_failed` after owned-process cleanup,
  preserving cancellation and application-exit errors.
- Create managed Chromium pages in the background through DevTools instead of allowing the
  first browser window to activate the user’s desktop during launch.
- Scope the first DMG to a native-app and Chromium preview. Refuse managed Electron launches
  before startup because Cursor can take desktop focus; MCP clients in those editors remain usable.

### Open-source preparation

- Finish retired daemon socket cleanup before allowing the same server to restart, avoiding
  an intermittent stale-socket removal failure.

- Fix CLI argument normalization for the hosted Swift 6.2 compiler and align the live
  conformance harness with the current 34-tool MCP catalogue.

- GitHub-hosted Apple Silicon CI and signing, pinned actions, history secret scanning, and
  explicit release-environment checks. Releases remain disabled pending owner approval.
- Developer ID signing and publisher verification for the DMG container as well as its payload.
- Illustrated README, synthetic Viewer screenshot, contribution guide, and Markdown plans.
- Private local workspaces and signing material excluded from source control.

UX round of 2026-09-23 (SPAO-240 – SPAO-271). The plan, evidence and verification for every item
are in [docs/plans/2026-09-23-ux-improvements.md](docs/plans/2026-09-23-ux-improvements.md).

### Added

- Local diagnostic logging for improvement loops. `spaceo logging enable|disable|status` writes
  owner-only settings that the daemon and MCP servers pick up within five seconds.
  - Every MCP tool call is journaled to `~/Library/Logs/SpaceO/journal/`, one file per connection.
    Each record has redacted arguments, the outcome, the error code and recovery hint, the action
    outcome, timing, the estimated token cost of the result, and loop context (sequence, previous
    tool, identical retry, after-error). At `full`, it also keeps the result text the agent read.
    Typed and clipboard text are never stored; URL queries are dropped; retention and per-file
    caps are bounded.
  - Daemon records now name the client (`cli`, `mcp`, `viewer`), the error code, the recovery
    tool and the shape of the request, never its payload.
  - `scripts/journal-report.mjs` ranks friction: error codes and whether recovery hints were
    followed, retry loops, schema mistakes, re-reads, token and latency hogs, and daemon failures
    from every client. See `docs/IMPROVEMENT_LOOP.md`.
- `spaceo doctor` has a Logging section.
- `spaceo_menu` / `spaceo menu` lists and presses the session app's menu-bar items without
  activating it. The Apple menu, Services, Hide Others and Show All are never offered.
- `spaceo_session_claim` / `spaceo session claim` takes over an abandoned session (for example
  after the agent's MCP client restarted) and keeps its apps. `orphan_grace_seconds` on create
  (30–1800; MCP default 120) sets how long an abandoned session waits.
- Action tools accept `observe` (`none` | `diff` | `full`, default `diff`), so a successful action
  returns fresh element indices. `verbose` and `SPACEO_MCP_VERBOSE=1` restore full receipts.
- `wait_for session_resumed` waits out a human's pause (allowed while paused) and returns the
  operator's note. Element waits and click-by-label accept `match` (exact | contains) and `role`.
- Destroys return a `destroySummary` (reason; apps quit, forced and released; duration; recording
  path or error). `resource_limit` failures carry `retryAfterSeconds` and `holders`.
- New error codes: `resource_limit` (now actually produced), `session_detached`,
  `focus_elsewhere`, `daemon_outdated`. `SessionInfo` gains `exitedApps`, `idleSeconds`,
  `lastOwnerActionAt`, `orphanGraceSeconds` and `graceRemainingSeconds`; windows are marked
  `focused`, `modal` and `defaultTarget`.
- Events `window.escaped`, `window.reparked`, `lease.expiring`, `session.claimed` and
  `session.display_lost`; sessions are revalidated after wake and display reconfiguration.
- CLI: `spaceo help <command>` and short per-command `--help`, `spaceo completions
  zsh|bash|fish`, `session create --export`, `SPACEO_SESSION` / `SPACEO_LEASE` defaults, and exit
  codes by class (2 usage, 3 daemon unavailable or outdated, 4 lease, 5 isolation, 6 wait not met).
- Doctor reports the CLI version and path, every configured MCP client's spaceo binary and version,
  and the installed Viewer. `make install` says when the running daemon is older than the install.
- Viewer: an "Agent needs you" notification (the only class on by default), a hand-raised status,
  waiting count, Dock badge and VoiceOver announcement; a Session menu with shortcuts; Take Control
  from any tile, banner or menu-bar row; a key-destination banner; a stalled-stream indicator; a
  daemon banner (offline, draining, restarted, version mismatch); and an Events filter.

### Changed

- The Viewer is redesigned around the session, not the plumbing.
  - Two columns by default: sessions on the left and the live screen in the middle. A details
    panel (⌥⌘I) opens on the right with two tabs, Session and Activity.
  - The sidebar is a native list with arrow-key navigation. Each row shows the session's app
    icon, a status dot, and one line saying what it is doing ("Needs you · Enter the 2FA code",
    "Working · Click · Save", "Paused · Safari"). Right-click a row for Take Control, Pause,
    Colour, Copy Session ID and End Session. Physical displays are no longer listed; virtual
    displays sit in their own section.
  - The window title and subtitle name the session and its status. The toolbar has Take Control,
    Pause/Resume, Screenshot, More and Details. Zoom, and the Session/Whole Display switch when a
    display is shared, sit in a slim footer. At Fit, the canvas takes the shape of the agent's
    screen instead of drawing black bars around it.
  - Hovering the canvas says "Click to take control". Taking control shows a card in the middle
    of the screen, and then a bar across the top, naming the keys that give it back (⌃ control,
    ⌘ command, esc) and where your typing goes.
  - While you're in control, dragging a window's title bar or toolbar background moves the
    window, kept inside the session's area. Before, the drag reached the app and nothing moved.
  - Settings is now part of the window (⌘, or the gear in the sidebar), with General, Agents,
    Permissions, SpaceO Service, Virtual Displays and Notifications panes. The separate Settings
    window and the inspector's Health and Infrastructure views are gone.
  - Connecting an agent is one click: Settings ▸ Agents (and the setup guide) show whether
    Claude Code, Codex, Cursor and Claude Desktop are installed and connected, and Connect runs
    `claude mcp add` or writes that tool's MCP config, keeping its other entries.
  - Every missing permission leads to a guide that says which switch to turn on, for which app,
    opens the right System Settings pane, and closes itself when the grant lands. It appears from
    the setup guide, from a black canvas, when Take Control is refused, and for the daemon's own
    permissions from Health.
  - A four-step setup guide replaces "Choose a session": welcome, allow access, connect your
    agent, try it with TextEdit. "SpaceO isn't running" has a Start button, and a launch without
    a daemon shows "Connecting…" instead of flashing the guide first.
  - Virtual displays can be removed from Settings ▸ Virtual Displays or by right-clicking one in
    the sidebar. Removing one ends its sessions after a confirmation.
  - The Mini Monitor has a close button on hover, a right-click menu (Hide, Clicks Pass
    Through, Open Viewer), opens the Viewer on double-click, and appears on the Viewer's screen.
  - New Session opens an app straight into the new session (Safari, TextEdit, Notes, Terminal,
    or any app) instead of an empty desktop.
  - Each problem is stated once, and notices share one card style. "Destroy Session" is now "End
    Session", "Release Input" is "Release Control", and notification settings are in plain words.
- The Viewer redraws much less. Its model uses Swift Observation, so a view updates only when
  something it shows changes. Panning, agent activity and the 2-second poll no longer re-render
  the whole window, and polled values that did not change are not re-published.
- `SpaceO Viewer --background` launches the Viewer without activating it: no menu bar item,
  notifications, Dock badge or saved preferences. `--preview NAME` adds fixture data (no daemon,
  no capture, no Control). `scripts/viewer-snapshots.sh` screenshots every preview scenario
  inside SpaceO sessions, for reviewing Viewer changes without touching the desktop.
- `spaceo pool remove <DISPLAY> --operator` ends every session on a virtual display and removes
  it (daemon command `pool.remove`).

- MCP receipts are compact by default and lead with an honest outcome, for example
  `click: confirmed (accessibility-action)`. An intact isolation verdict is one line.
- `tools/list` shrank from 37.6 KB for 32 tools to about 30 KB for 34; every property is described.
- Tools that omit `session` use the session this MCP connection created, even when other agents
  have sessions. `session_list` marks `[yours]` and redacted sessions.
- MCP errors name MCP tools rather than CLI commands, end with a trace id, and suggest the intended
  argument name. Daemon messages use wording that fits both surfaces; recovery hints carry the
  request's session and window on every failure path.
- Commands that omit `window` target the app's focused window (an alert or sheet) rather than the
  largest one. Screen reads show control state tokens; web reads show input type, checked state
  and selected option.
- `type` and `press_key` without `web` follow the agent's last page click through DevTools.
- AppKit apps launch clean: an untitled document instead of the Open panel, and neither restoring
  nor overwriting the user's saved windows. The overrides are per-process launch arguments only.
- `read_text` reads checkboxes and radio buttons by name instead of their 0/1 state.
- A PARTIAL verdict's cause comes from the daemon's real Accessibility grant.
- CLI `--json` always prints one sorted object with `ok`; global flags may precede the command;
  doctor is grouped into sections with sentence-form blockers. `setup --client claude-code`
  registers at user scope, finds `claude` on `PATH`, and replaces an existing entry.
- Viewer: pasting during Control uses an inline prompt and restores the session clipboard
  afterwards; Reclaim became "Clean Up…" with a confirmation; Resume All skips agents waiting for
  a person; events read as sentences with verdict-based severity.

### Fixed

- An exclusive session now reuses an idle display of the same size instead of building a new one.
  Creating and ending exclusive sessions in a loop used to fill the display budget with idle
  framebuffers until the idle grace retired them.
- The Viewer no longer reports "cleanup failed" for a session whose apps took more than two
  seconds to quit. Teardown requests now wait up to a minute.
- A click refused before delivery (an index past the end of the snapshot) no longer expires the
  agent's valid indices, and the out-of-range index is a recoverable `stale_snapshot` naming the
  valid range instead of a terminal `bad_request`. Both were found by the first journal report.
- Every app launch failed on 1.1.1 with "window count is unavailable": a still-launching app's
  transient `kAXErrorCannotComplete` aborted the launch. Busy answers are retried a bounded number
  of times, presence waits retry provider failures within their budget, and the same transient
  answer no longer fails `verify`.
- Web reads printed the value of unlabeled password, card-number and one-time-code fields.
- An exited or never-launched app was reported as "no windows yet" with a wait that could never
  succeed.
- A second agent's session broke every MCP call that omitted `session`.
- Taking Control of an agent that paused itself did not hold it or hand back the note; pasting
  during Control ended Control; pasted secrets remained readable in the session clipboard.
- `spaceo wait` exited 0 on timeout; `daemon restart` failed against a daemon that predates drain;
  `doctor --fix` suggested a nonexistent `--when-idle` flag; doctor called a busy daemon "not
  running"; `spaceo help click` printed the whole usage.
- Hosts with Accessibility granted were told to grant it on every PARTIAL verdict.
- Recorder finish errors were swallowed on destroy, and detached recovery quit apps without logging.

## [1.1.1] - Planned

### Changed

- Simplified the Viewer around Take Control and Pause/Resume Agent. Screenshot, maintenance,
  and destructive actions live in More Actions; zoom and Fit/Actual Size are in the status bar.
  The inspector starts collapsed for new preferences, has a visible toggle and section picker,
  and health/review actions reveal it. Saved panel preferences are preserved.
- Reduced sidebar repetition, collapsed display infrastructure, honored session titles in the
  canvas header, and reduced the minimum window size to 900 × 560.

### Fixed

- Release gate tests enforce the current self-hosted runner and exact toolchain pins, fixing
  stale expectations while retaining rejection of incompatible Xcode and Swift versions.
- AX observation rendering appends components directly and avoids replacement strings for
  ordinary AX roles while preserving unusual Unicode role formatting.
- MCP failures identify a returned session so agents can address partial creation failures
  without an extra session-list lookup; controller leases remain private.

- Daemon request timing uses a monotonic clock, and baseline process metrics are skipped when
  logging is unconfigured. Configured logs retain baselines for unexpected request failures.
- Supplied log timestamp callbacks run outside the logger lock, allowing them to inspect logger
  state without deadlocking; record formatting and file writes remain serialized.

- Unconfigured logs skip request metrics and record construction. Non-finite or out-of-range
  duration telemetry is marked unavailable instead of trapping, and byte deltas handle the
  full unsigned counter range.
- Log rotation atomically replaces its predecessor and stops on failure, preserving the active
  log when rename fails and refusing to recursively delete an unexpected predecessor directory.

- Event and log diagnostic clipping no longer scans an entire oversized grapheme to produce a
  small preview. Logging applies character and byte limits in one bounded pass while preserving
  existing Unicode boundaries, exact-fit values, and truncation markers.

- Busy queued event subscribers yield after 128 delivery decisions so continuously replenished
  replay/live traffic cannot indefinitely starve heartbeat or control work on the same queue.
  Continuations remain coalesced; inline subscriptions retain synchronous delivery behavior.

- Closed event deliveries release writer captures and event-bus backlogs even when the closed
  handle is retained. Unsubscribing releases callback captures outside the bus lock, avoiding
  deadlock when captured owners perform cleanup that calls back into the bus.

- Event stream framing validates contiguous chunks by newline-delimited segment length and
  transfers complete single-frame storage directly to the decoder, reducing per-byte work and
  avoiding an extra frame-sized Data value while preserving byte limits and stream recovery.

- Long-running MCP connections drain Foundation temporaries after each request, avoiding
  cumulative memory growth during repeated JSON parsing and response encoding.
- MCP batch steps reject unknown envelope fields and non-object arguments instead of silently
  ignoring them. Unknown resource and batch tool names use bounded diagnostic previews.

- MCP prompts enforce a 16384-byte limit alongside their existing 4096-character argument
  limit. Unknown fields and incorrect types now produce actionable invalid-parameters errors
  instead of being ignored or misreported as missing; prompt discovery advertises the limits.

- MCP unexpected-argument errors show a bounded, sorted name preview and omitted count instead
  of copying every field name. Unknown tool/method names and stderr previews are byte-bounded,
  Unicode-safe, and escape control characters; ordinary short typo messages remain unchanged.

- Text validation checks byte limits before Unicode character counts, avoiding expensive scans
  of already oversized arguments. Daemon/browser typing validation skips a redundant character
  traversal while preserving the existing character, scalar, and byte limits.

- Transport framing rejects oversized chunks before growing its buffers. MCP drains oversized
  lines without repeatedly copying discarded data and avoids extra buffer growth at valid line
  limits while preserving subsequent messages and malformed-input recovery.

- Cancelling event subscriptions interrupts setup I/O instead of waiting out the connection
  budget. Cancellation before start is terminal. Finished handles release request/callback
  storage, and socket cleanup preserves ownership across setup, cancellation, and reader exit.

- Daemon client exchanges share one timeout across connection, upload, and response reception.
  Nonblocking sockets prevent late fragments from extending that budget; event subscriptions
  share their setup deadline and wait without spinning while idle. Expired writers refuse work.

- MCP input parsing avoids temporary text conversions for ordinary ASCII requests, reducing
  peak memory near the input limit while retaining strict UTF-8 and Unicode whitespace handling.

- Daemon JSON responses avoid unnecessary slash escaping, reducing image payload size and
  preventing slash-heavy images within the 5 MiB image limit from exceeding the 8 MiB frame
  limit solely due to escaping. Frame limits and required JSON escaping remain enforced.

- MCP screenshot validation no longer decodes a full temporary PNG buffer. It checks encoding,
  decoded size, and signature while preserving the original image payload, and rejects malformed
  nonterminal or excess base64 padding that some Foundation versions accept.

- Screenshot `capturedAt` now preserves the backend image-return time through processing and
  saving. It no longer makes delayed frames appear newly captured; freshness and presentation
  remain explicitly unverified. Agent guidance now describes shared browser/stability deadlines.

- Screenshots share a 15-second capture/processing budget and keep at most one pending worker
  after timeout or cancellation. Late workers cannot publish files; session teardown retains
  their resources. PNG annotation and encoding run off the manager actor, file PNGs are capped
  at 64 MiB, native frames are capped at 64 Mi pixels, and geometry is rechecked before output.
  Invalid region sizes and unsupported tile annotations fail
  before capture starts, and empty annotations reuse the original bitmap.

- Stability waits now bound capture and hashing by the remaining wait time, retain at most one
  pending capture worker, and discard late frames. Pending native work keeps its session tile
  reserved with a retryable teardown report; recording captures use the same protection and
  reject frames completed after their deadline.
  Stability probes skip redundant owned-window scans
  while retaining checked foreign-window exclusions and full-resolution frame validation.

- Browser selector and title waits now share their remaining deadline with HTTP discovery,
  command admission, evaluation, and cleanup. HTTP responses accumulate bounded chunks and
  cancel stalled transfers; expired observations cannot become matches. Title observations
  also reject a target binding changed during discovery.

- Watcher movements now inherit sweep deadlines, call limits, and stop requests while retaining
  their own movement ceiling. Unconfirmed movement or unavailable containment remains retryable;
  only observed unchanged refusals suppress retries. Late containment reads cannot clear history.

- Window movement now shares one monotonic budget across mutation and settling, shortens final
  sleeps, and bounds AX geometry fallback reads. Unavailable geometry no longer echoes the
  requested frame. Accessibility deadline accounting avoids clock-boundary underflow and refuses
  provider calls when timeout setup has already exhausted the budget.

- Session re-parking, rollback, and teardown evacuation reuse handles from their checked window
  discovery instead of searching again for every move. Handles are released before verification
  or process waits; cached windows omitted by Accessibility retain a bounded recovery lookup.

- Launch polling now stops on cancellation, uses monotonic deadlines, and bounds DevTools
  marker reads to small regular files with complete port lines. Failed launches await cleanup
  independently of cancellation, rechecking process identity before escalation. Bridge readiness
  starts no provider work after validation consumes its deadline or cancels the request.

- Session cleanup and detached recovery now use monotonic process-exit waits with capped final
  sleeps. Polling compacts the survivor list in place, skips already-confirmed exits, and retains
  entries whose checks could not finish within the wait budget.

- Electron editor pane discovery now pages window and child lists within shared time, node,
  call, and allocation limits. Scroll and selection refuse incomplete discovery instead of
  routing from partial panes. Cyclic/shared subtrees are visited once, the pane cap is strict,
  and pane ordering no longer repeats deduplication.

- App rollback temporarily suspends idle watchers and defers while a sweep is active, preserving
  containment after failure without rebuilding observers. Rollback and teardown rediscover windows
  after evacuation and retain ownership for new dialogs or unconfirmed geometry. Ambiguous cached
  windows cannot disappear on cleanup retries, and evacuation cascades stay on the user display.

- Timed window reads now share a monotonic deadline with discovery, shorten the final sleep,
  reject late observations, and return a successful probe without another full refresh.
  Timeout messages describe an unconfirmed match rather than claiming the app has no window.

- Session refresh now uses one checked discovery budget across owned apps and preserves known
  windows on failure. Reads and target resolution report incomplete discovery; post-action
  receipts retain their results with warnings. Teardown reports discovery failures and keeps
  ownership for retry while still honoring explicit quits of launched apps. The legacy window
  list also uses bounded discovery, and retained-window storage counts toward its budget.

- Watcher moves reuse handles from one checked discovery instead of resolving each window again.
  Sweeps skip title reads without a placement callback, release handles when finished, and avoid
  redundant tracking sets and rebuilding unchanged refusal records.

- Window watchers now use checked, bounded discovery and preserve refusal history when a sweep
  cannot complete. Session audits report bounded sweep diagnostics. Stopped watchers cannot
  restart from late notifications, and active sweeps check stop/deadline before further work.
  Teardown stops watchers before evacuation and retains resources with a retryable incomplete
  report until any in-flight sweep or placement callback returns.

- Launch readiness now checks for one resolved window ID, and `allow_no_windows` uses one checked
  count query, avoiding full window lists, titles, and geometry. Window polling uses a monotonic
  deadline, passes the remaining budget into discovery, caps its final sleep, and rejects late results. Provider
  failures remain errors. Fractional window timeouts no longer display as zero seconds.

- Multi-window placement now completes bounded, paged discovery before moving anything and
  reuses verified AX handles for forward moves and rollback instead of repeatedly enumerating
  every window. Single-window lookup is bounded too. `allow_no_windows` requires a confirmed
  empty discovery result; provider failures no longer take the successful no-window path.

- Capture exclusion discovery now uses checked paging and one resource budget across neighbouring
  sessions, including retained and teardown window identities. Incomplete discovery prevents
  capture. Exclusion-only reads omit titles and merge identities without intermediate combined
  arrays, reducing AX calls and temporary memory while preserving fail-closed overlap checks.

- Wait probes now discover windows in checked pages with one shared time, window-count, call,
  and allocation budget across the session's apps. Failed discovery preserves known windows;
  cached titles retained for containment no longer satisfy a fresh title wait. Legacy placement
  and teardown enumeration remain separate follow-up work.

- Accessibility wait observations now limit traversal and per-call timeouts to the remaining
  wait budget instead of starting a fresh three-second traversal. Root discovery that exhausts
  that budget remains an unmet observation, and partial trees cannot prove element absence.
  Waits also recheck deadlines after preparation before starting browser or capture queries.

- Batch queue admission now shares its time budget, including final authorization. Expired
  queued steps are marked unexecuted. Final queue expiry preserves earlier receipts and warns
  against replaying completed input, without publishing unreauthorized session metadata.
  Cancellation during step admission also reports the step as unexecuted.

- Wait queue admission now shares the condition budget. Expired and cancelled waiters leave
  the queue promptly without releasing the current owner or retaining request state until a
  timer fires. Initial/final admission failure returns `wait_queue_timeout` with recovery guidance
  and no unreauthorized session metadata. Already-running queries remain a separate latency limit.

- Stability waits confirm short and fractional polling intervals promptly instead of rounding
  them up to 250 ms. Their probe watchdog accommodates the extra confirmations during long waits.
- Wait probes that expire in the operation queue skip the observation and report a truthful
  timeout/count. Final authorization and response metadata share one gate entry, and requested
  isolation evidence is retained for the final assertion in standalone and batched waits.

- Recording retention scans completed frame trees with lower allocation overhead and releases
  temporary filesystem metadata after each pass. File sizes are still recounted, links are not
  followed, and unreadable entries now fail explicitly instead of understating disk usage.

- `actions+frames` now captures bounded before/after session-tile images around individual
  actions, including nested launches and batch steps. Capture failures and capacity omissions
  have explicit statuses; frame failures do not change the action outcome. Captures time out
  without accumulating background requests, and actions-only recording never writes images.
- Recording reports and help clarify that opt-in images can contain visible typed text, even
  though text/key payloads are omitted from receipts. Batch responses retain step warnings.

- Nested batch and launch actions receive individual recording receipts without repeatedly
  assembling session metadata or consuming handoff notes. Admission-refused steps report
  `executed: false`; skipped actions are not recorded.
- Failed create-and-open or post-create setup returns the created session and controller lease.
  MCP retains that lease for recovery, and the CLI prints it while preserving failure status.

- Recording errors stop repeated writes and warn the owning agent without changing the command
  outcome. Ordinary preflight/execution failures receive receipts; finalized routes/completion
  and UTF-8 payload lengths are recorded. Text/key response prose is omitted to prevent echoes.
- Failed CLI and MCP responses retain warnings, including recording failures.
- MCP input avoids redundant line-buffer copies and repeated prefix removal for coalesced
  requests. Line limits and recovery after malformed input are preserved.
- Recording reports decode and render one receipt at a time instead of retaining the entire
  sidecar and decoded history alongside the HTML. Output and the 64 MiB input limit are preserved.
- Recording appends avoid rescanning live frame trees, preserve every active recorder during
  pruning, and reserve receipt space before optional frames. Live writers share capacity
  admission; final manifests cannot overrun it, and failed finalization stays a failure on retry.
- Recording reports bound sidecar reads before allocation, reject non-regular/symlink inputs,
  and handle extreme coordinates without integer-conversion crashes.
- In-memory PNG encoding bounds retained output as it is written and discards partial output
  on overflow. Capture rejects incompatible memory/export options before capture, checks pixel
  storage arithmetic, and documents the existing 5 MiB PNG limit and full scale range.
- Event cursors reject invalid input without trapping and accept the full unsigned wire range.
  Failed event subscriptions now exit unsuccessfully so automation can detect and recover.
- MCP discovery reuses its immutable tool catalogue and encoded schema resource, avoiding
  repeated dictionary construction and schema serialization.
- Viewer event handoff uses bounded batches and backpressure instead of a main-actor task per
  response. Replaced streams cannot ingest stale events or reconnect over their replacements.
  Event-history gaps stay visible, and unconfirmed/redacted verdicts no longer clear known breaches.
- Event delivery preserves per-subscriber order during nested publication and replay. Socket
  subscribers use independent delivery queues outside the bus lock; ring overruns produce an
  explicit resync notice instead of silently losing history. Pending storage stays ring-bounded.
- Stream cursors now match polling's exclusive resume semantics. Handshakes and heartbeats do
  not acknowledge unseen events, and JSON event-follow gap notices remain valid JSON. The
  Viewer refreshes its session state on standalone resync notices. Stream shutdown signals
  waiting handlers directly instead of polling every half second.
- Diagnostic field selection keeps bounded scratch storage instead of sorting every key.
  Log records now bound field count and UTF-8 payloads, including oversized single graphemes;
  text clipping avoids temporary strings for each character.
- Admission timeout callbacks no longer retain removed request owners or form timer cycles.
  MCP doctor polling compares build UUIDs before reading the executable for a hash fallback.
- Event streams enforce per-line byte limits even at newline boundaries and report incomplete
  EOF. Incremental framing avoids rescanning partial lines and shifting coalesced buffers.
- Screenshot forwarding reuses validated base64 instead of encoding it again. One-shot
  transport decodes original framed bytes and releases completed request buffers promptly.
- Text reads bound selection previews before browser serialization, and native text reads
  preserve values beyond the outline attribute cap with accurate truncation reporting.
  Copy/cut refuse incomplete selections; append-style paste requires a known complete field
  value. Cut receipts leave deletion unconfirmed when only selection changes are observable.
- Browser JavaScript evaluations request a five-second Chromium execution timeout, including
  viewport reads. Returned remote result/exception handles are released on the original binding;
  primitive results need no cleanup request. Boolean results remain `true`/`false` rather than `1`/`0`.
- Native key delivery also avoids opening the shared pasteboard before rejecting clipboard
  shortcuts. Diagnostic snapshots bound metadata reads and use one worker per complete snapshot,
  avoiding one dispatch/semaphore allocation per value.
- Clipboard policy/diagnostic tests use an in-memory provider, and Viewer event/accessibility
  fixtures omit rendering/drag-service setup, avoiding unrelated clipboard-service stalls.
- Browser key delivery no longer initializes the shared system pasteboard, avoiding an
  unrelated synchronous service wait. Clipboard shortcuts remain rejected before dispatch.
- Native reads track actual label clipping instead of treating ordinary ellipses as missing
  content. Labels such as “Open…” no longer cause false partial-read warnings or block absence waits.
- Web search checks full labels/values beyond their display prefix, normalizes query whitespace,
  and explicitly reports match and 1,000-control scan limits. Empty partial searches no longer
  imply absence; daemon hit counts use structured results.
- MCP and batch receipts retain observation completeness. CLI/MCP batch failures include it,
  and find guidance distinguishes native snapshot indices from live page indices and coordinates.
- Native outlines append directly into a reserved result buffer, and snapshot diffs stream keys
  with index-based matching to reduce temporary allocations. Exact-label targeting stops once ambiguous.
- Native rendering safely clamps indentation and omits unrepresentable coordinates while keeping
  indexed controls available. Nonpositive native find limits now return no results.
- Browser element lookups stop at the requested index and share streaming DOM traversal with
  page reads/searches. Exact-limit page reads and native searches no longer claim omitted results.
- Page observations reject malformed data and JavaScript exceptions instead of reporting empty
  results or invented coordinates. Unavailable page reads/searches mark combined observations incomplete.
- Browser text and element labels no longer split UTF-16 surrogate pairs at clipping boundaries.
- Browser and Electron readiness polling stops on cancellation, uses monotonic deadlines,
  and rejects late successes. Cancelled queued DevTools commands are removed promptly.
- DevTools sends and replies share a ten-second budget and cancel their transport before
  releasing the command slot. Completed callbacks release timeout captures promptly.
- DevTools commands, gestures, element lookup/click, and navigation retain their original
  target/socket instead of following a rebind to another tab. Interrupted gestures attempt
  bounded release cleanup on that same binding while preserving the original error.
- Pixel-stability waits fingerprint every pixel instead of a sparse grid and reject unreadable
  frame data. Hashing streams buffer views without allocating another full-frame bitmap.
- Browser new-tab responses enforce their 64 KiB limit while streaming. Discovery and new-tab
  reads share bounded chunk accumulation and stop transfers on errors or cancellation.
- Batches release the daemon command gate between steps and during waits, rechecking session
  generation, controller authority, pause state, and isolation requirements before proceeding.
  A shared 60-second budget prevents starting further steps indefinitely.
- Batch waits that time out or are cancelled now fail the step; shortened standalone pauses
  report timeout. Wait timing is monotonic, late observations cannot claim success, and
  element disappearance requires a complete snapshot, including static labels.
- Batch receipts retain bounded find observations and snapshot IDs. MCP and CLI errors include
  completed, failed, and skipped step receipts so agents can recover without replaying work.

- Native `read_text` now reads full text values directly within character, traversal, and memory
  budgets instead of returning 480-byte screen-outline labels. It skips geometry/action queries,
  stops after enough text is available, and respects Unicode and separator limits.
- Partial Accessibility snapshots retain only element handles whose nodes fit in the memory budget.
- Accessibility walks skip repeated/cyclic references. Screen reads report omitted descendants
  at the depth limit and preserve clipping warnings even when an incremental diff is empty.
- Incremental screen reads no longer build and discard the full outline before rendering changes.

- Incremental screen reads report reindexed controls with their current targets and reject diff
  bases from another window. Duplicate labels with suffixes and extreme accessibility geometry
  no longer risk a crash during diff generation.
- Accessibility diff history shares normal snapshot arrays and caps retained node/string payloads
  at 8 MiB per session, evicting old entries with the existing full-read fallback. History for
  closed or replaced windows is released when the window list changes.
- MCP input framing scans each byte once while assembling long messages and reuses read scratch
  storage within a message; oversized input is discarded without repeatedly rebuilding a large buffer.
- Event polling reads only the requested ring-buffer page, avoiding whole-history scans and
  temporary arrays when agents poll for small updates or are already caught up.

- Capture delivery retains only the latest pending frame while the UI is busy, avoiding a backlog
  of retained frame buffers. Surfaces render in the generation-checked delivery turn rather than
  scheduling another main-queue hop; unchanged geometry no longer triggers redundant layout.
- Slow, incremental canvas drags no longer accidentally capture input on mouse-up. Display tile
  pause actions no longer nest inside the tile selection button, and the pan hint passes clicks
  through to the canvas.

### Changed

- CI, the release workflow and the live-test preflight run on the repository-owned Apple Silicon
  runner `spaceo-mac` (Xcode 27.0 / Swift 6.4) instead of billed hosted `macos-15` runners.

## [1.1.0] - 2026-09-17

The 36-item UX round from `docs/plans/2026-09-16-ux-improvements.md`. Deterministic coverage
only: this version has not completed the live qualification, Developer ID signing, notarization
or publication gates in `docs/RELEASE_POLICY.md`, so it is tagged as a pre-release.

### Added

- Agent ergonomics (SPAO-140, 143, 144, 146, 207–213): `spaceo_open_url` / `spaceo open-url`,
  `spaceo_wait_for` / `spaceo wait` (bounded waits on labels, titles, selectors or pixel
  stability, probing without holding the daemon gate), `spaceo_find`, `spaceo_read_text`,
  incremental `spaceo_read_screen since=` diffs, `spaceo_run_steps` batches with per-step
  receipts, element references on scroll/move/drag with a `resolved_point` receipt, typing
  `replace`/`submit`, key `hold_ms` and `action: down|up` with a held-key watchdog, annotated
  set-of-marks screenshots (`annotate`), idempotent `spaceo_open_app` (reuses a running instance;
  `new_instance` opts out), create-and-open with `app`, exclusive display presets, session
  `title`/`record`, and a machine-readable truncation footer on every screen read.
- Per-session clipboard broker (`spaceo_clipboard_set`/`get`, `spaceo clipboard`): ⌘C/⌘X/⌘V are
  brokered through the session buffer via DevTools, typing or the focused field's value; the
  user's pasteboard is never touched. Refusals are reported as `inserted_via: refused`.
- Structured `recovery` hints on every common error code, delivered as JSON in MCP failures and
  in `--json` output.
- Hand-off between human and agent (SPAO-219): `spaceo_session_pause(reason)`, an operator note on
  release (`session resume --note`), delivered to the agent exactly once as a `HUMAN HANDOFF:`
  line; session titles and colour tags (`session annotate`, `spaceo_session_set_title`) persisted
  in the ledger.
- Daemon event stream (SPAO-214): `events.subscribe` over a long-lived socket connection with a
  4096-event ring, replay and lease-scoped redaction; `spaceo events [--follow]`, `spaceo_events`.
- `spaceo daemon restart --operator` drains the daemon (new sessions refused with
  `daemon_draining`, existing ones keep working) and starts this build; MCP retries creates while
  the daemon drains. `spaceo daemon install|uninstall|status` supervise the daemon with a
  LaunchAgent so grants attach to SpaceO rather than to whichever client started it; the MCP
  server does not spawn a daemon when one is supervised.
- Setup names the responsible app macOS attributes grants to, opens the exact Settings pane and
  waits for the grant on a TTY, remembers passed steps, and `setup --client` writes the MCP
  registration for Claude Code, Codex, Cursor or Claude Desktop after showing a diff.
  `doctor --fix` applies the safe remediations behind a prompt; doctor reports attribution,
  launchd supervision, disk use and orphaned profiles.
- Disk hygiene (SPAO-153): startup and `spaceo clean` remove orphaned browser profiles and
  control roots older than a day that no live or detached record references; an unsupported
  ledger schema is quarantined with a note instead of stopping the daemon.
- Session recording: `session create --record actions|actions+frames` writes per-action receipts
  (never typed text) under Application Support, capped at 500 MB, and `spaceo report` renders an
  HTML timeline.
- One-sentence isolation verdict summaries in the CLI, MCP and Viewer; `--mute-audio` for managed
  Chromium launches; a "quiet agent apps" setup step with Focus guidance.
- MCP `prompts/list`, `prompts/get`, `resources/list`, `resources/read` and `spaceo skill`,
  generated from `docs/playbook/*.md` by `scripts/generate-playbook.mjs`.
- Viewer: no stream restart when a tile moves, persisted preferences, Fit/Actual Size/zoom
  commands, drag-to-pan, agent action overlay and activity sparkline, hand-back note sheet,
  session titles/colours grouped by controller, first-session walkthrough, native notifications
  for the four events a human must know about, Copy from Session and drop-to-open, a menu bar
  extra and mini monitor.

### Changed

- Screen reads that hit the traversal budget return the partial tree flagged `truncated:
  traversal_budget` instead of failing; the web element cap is reported as `web_cap`.
- `session_paused`, `lease_required`, `daemon_draining`, `web_target_ambiguous` and
  `daemon_busy` are distinct error codes. Permission errors name the responsible app.
- The janitor persists a session only when its durable projection changed (SPAO-151); the socket
  accept loop no longer reads requests on the accept thread (SPAO-152).
- MCP tool count is 32.

### Fixed

- The full computer-use matrix expects the current MCP tools and continues to the remaining
  suites and final display-cleanup checks when one suite fails.

## [1.0.0] - Planned

Release contents are consolidated below. Set the publication date after qualification and owner approval.

### Added

- Transcript-review contract: offline help at every command depth and versioned CLI schema,
  structured readiness/error codes, optional strict isolation/window assertions, unique AX
  snapshot and window-geometry receipts, and exact-label Accessibility selection.
- Explicit preserve/fit/cover placement, no-initial-window launch/adoption, bounded window waits,
  launch argument forwarding and timed drags. MCP adds adoption, placement, pause/resume, scoped
  keep-apps release, automatic lease renewal and memory-only screenshot delivery.
- Bounded synthetic presentation fixture and evidence classifier that separate GPU completion,
  callback timestamps, capture freshness and unverified display cadence. See
  [the workflow contract](docs/TRANSCRIPT_WORKFLOWS.md) for integration and live acceptance.

- The empty Viewer now offers a prominent New Session action and Command–Shift–N shortcut.

- `make signed` creates Developer ID signed local CLI and Viewer artifacts at stable paths for
  repeatable permission-bearing development. It rejects ad-hoc fallback and CLI identity drift.

- Setup, update-check, and troubleshooting guides (`docs/SETUP.md`, `docs/UPDATING.md`,
  `docs/TROUBLESHOOTING.md`), plus a quick start, documentation index, and short troubleshooting
  table in the README.

- MIT open-source license.
- Responsible-disclosure, security-boundary, support, and release-governance policies.
- Guided first-run setup, permission checks, daemon startup, self-test, and MCP client
  configuration through `spaceo setup`.
- A durable, owner-only daemon event and metrics log with bounded diagnostic fields, per-request
  trace IDs, rotation, and a local summary tool. MCP tool failures are also echoed to the host's
  retained stderr log.
- A semantic `spaceo_select_text` action for VS Code-family editors, plus effect-confirmed editor
  typing and scrolling.
- Branded SpaceO Viewer artwork and application icon.
- Separate safe and live test runners: `make test` excludes `IntegrationTests`, `make test-live`
  runs them against the real WindowServer with no opt-in environment variables.
- Fail-closed Developer ID DMG packaging, notarization, stapling, checksum signing, and
  distribution verification automation.
- Installation, upgrade, rollback, and uninstall guidance for verified release artifacts.
- Explicit Chromium target listing/attachment in the CLI and MCP surface.
- Viewer session creation, confirmed destruction, recovery cleanup, recent agent-action status,
  and pause/resume arbitration when a person takes Control.

### Changed

- `spaceo doctor` now compares the current CLI with the running daemon's executable image and
  reports the daemon's version, build UUID, digest, permissions, and restart requirement. MCP
  clients warn about stale or unidentifiable daemon images.
- Named `session destroy --operator` can reclaim an abandoned session immediately; non-operator
  failures state the automatic reclamation boundary and the operator recovery command.
- The computer-use qualification matrix now retains complete failure detail, verifies physical
  display topology and final zero-display cleanup, and waits for a cold Electron editor's usable
  window instead of assuming its first transient window is ready.
- The computer-use matrix now covers sliders, modifier-extended multi-selects, and context actions,
  reports a parity percentage in its structured output, and is published by the live workflow.
- Controller leases now fence cross-agent access, not just named-session mutations (SPAO-147).
  Session-scoped reads — `windows`, `ax`, `screenshot`, `verify` — require the session's
  `--lease`; `session.list` remains open to every client but redacts other controllers' app and
  window detail (marked `redacted` in JSON) unless the caller's lease or declared owner covers
  the session, or the caller passes `--operator`. `session.destroy --all` and `daemon.stop`
  proceed only when every live session is covered by the caller's lease or with the explicit
  `--operator` flag; `pool.configure` always requires `--operator`. `session.create` over the
  socket now requires a controller owner (the CLI and MCP server already send one), so a raw
  client can no longer mint a session that everyone may mutate lease-free. The Viewer and the
  daemon's own SIGTERM/SIGINT shutdown act with operator scope. This is coordination between
  cooperating clients sharing one daemon, not a security boundary: the uid remains the trust
  line, and the flags are deliberate confirmations rather than credentials.

### Fixed

- Preserve normal window sizes and remove the 40-point overflow for display-sized panels across
  initial placement, watchers and re-parking. Report requested/observed explicit placement bounds.
- Report adoption/repark isolation and pause on known breaches; launch no longer blindly restores
  an earlier foreground app. Inspection commands no longer request a placement sweep.
- CLI daemon stop waits for the identified process to exit; `daemon wait` supports bounded startup
  readiness polling. Doctor exposes client/daemon permission mismatch separately from host health.
- Enforce practical default allocation budgets and checked arithmetic, including failed-attempt
  rate limits. Deliberate unrestricted daemon startup is explicitly reported.

- Viewer Pause/Resume stays disabled during Human Control and its pending transitions, preventing
  an agent from being resumed while the human is still driving the same display. Taking Control
  also waits for pending manual Pause/Resume requests. The Control
  menu advertises the working local escape, and view-only displays no longer offer capture input.

- Guided setup now supplies the required controller identity, uses a unique test session and
  private temporary capture, validates the PNG, and fails if session cleanup is unconfirmed.
  Its report distinguishes skipped tests and checks the actual daemon's build and permissions.
- Setup's MCP configuration correctly escapes executable paths for shell, TOML, and JSON.
  Doctor no longer treats an unknown daemon image or missing daemon health as a passing check.
- Failed display retirement remains visible for cleanup but its invalidated display cannot be
  reused by a new session. Pool reports snapshot occupancy under the lock, and aggregate
  framebuffer arithmetic fails with a structured error before it can overflow.
- Viewer Control stops on failed admission, rechecks permissions after delayed pause replies,
  and waits for earlier pause/resume transitions before accepting another takeover. Slow polls
  are coalesced; replies predating a completed mutation cannot discard new session leases.
  Failed takeover also reports rollback failures and identifies sessions that may remain paused.
  A daemon connection timeout now attempts to release Viewer-owned pauses and reports an
  unconfirmed resume instead of assuming the daemon exited and discarded its pause state.
- The computer-use matrix rejects JSON-RPC errors, missing screenshot evidence, and incomplete
  isolation coverage. Early MCP exit and shutdown are handled without hanging, fixtures are
  private and unique per run, and raw failure text is excluded from structured step labels.
- Setup and troubleshooting distinguish preview support, prerequisite checks, live session
  testing, and isolation qualification; log-sharing guidance accounts for sensitive error text.

- `SIGTERM`/`SIGINT` and `daemon stop` no longer refuse while a named session teardown is in
  flight; they wait for it (bounded) instead, so a supervisor's stop is not escalated to
  `SIGKILL`. The daemon's signal handler also exits when a previous daemon's detached recovery
  records are still inside their grace period, leaving those records on disk for the next daemon
  and saying so; the interactive `spaceo daemon stop` keeps asking the operator to wait.
- `session.create` for a different name is accepted while another session tears down; only the
  name being torn down is refused (as "already exists"). The janitor keeps reaping exited apps
  and recovering detached records during a teardown and no longer aborts its whole reclamation
  pass on one failed session.
- A pause set by the human operator (Viewer, or `--operator`) can no longer be cleared by the
  agent's own lease, and `run` is refused into a paused tile.
- `session.list`, heartbeats, and janitor passes no longer overwrite a `--keep-apps` cleanup
  intent in the durable record with "terminate", so crash recovery honours it.
- A neighbouring session's tile screenshot excludes the pre-teardown windows and processes of a
  session that is tearing down instead of failing for the length of the teardown.
- A DevTools send failure retires the dead WebSocket so the next attach starts clean.
- Session ids are bounded to 128 characters / 512 UTF-8 bytes; destroying a name that is neither
  live nor detached says "no session named" rather than "no detached session named".
- The daemon line-buffers stdout, so its startup and recovery lines reach a log file or the MCP
  startup-diagnostics file as they are written rather than at exit. The MCP server stops waiting
  as soon as a spawned daemon exits over a stale non-socket path instead of polling for 10 s.
- Viewer: releasing Control (or losing it to a stream restart, selection change, permission
  loss, session end, or disconnect) always resumes the sessions it paused; a pause round-trip
  that completes after Control was released hands input back instead of re-enabling it; and a
  refused heartbeat for a Viewer-owned session drops that lease instead of reading as a daemon
  disconnect that empties the navigator every poll.

- Shared clipboard shortcuts now fail closed consistently: Command-C, Command-X, and Command-V
  cannot overwrite or disclose the user's pasteboard through either native or Chromium input.
- Chromium input no longer silently degrades when target attachment is ambiguous or unavailable;
  every web command verifies its exact bound target first.
- Destroying one live session no longer holds the process-wide command gate during process-exit
  waits, so other sessions remain responsive.
- Isolation reports use the public Accessibility focused-application attribute as explicitly
  inferred keyboard/text-route evidence when available, while retaining a partial verdict when it
  is unavailable.

- Native `type` and `key` now refuse before sending when a multi-window application would route
  the keystroke to a different or unidentifiable window. Type read-back is scoped to the requested
  window instead of attributing another document's text to a successful command.
- Tile captures exclude windows owned by neighbouring sessions, including windows created during
  the AX-to-ScreenCaptureKit race, and fail closed when an overlapping foreign window cannot be
  resolved. Oversized or unmovable windows can no longer leak another agent's pixels into a tile
  screenshot (SPAO-148).
- A transient or partial Accessibility enumeration no longer erases live windows that the
  WindowServer still attributes to the session's process; containment, audit, and teardown retain
  those windows with current geometry and re-check ownership before acting.
- Whole-display Viewer captures are named for the display rather than the previously selected
  session, and app reaping now leaves a durable lifecycle record.
- Viewer packaging now includes the canonical icon and brand mark, and CI verifies the complete
  ad-hoc-signed bundle as well as the standalone release binaries.
- A `spaceo daemon stop` that reports incomplete teardown no longer disables the daemon. It
  previously latched shutdown before running teardown, so every later command — including `ping`,
  `session list`, and cleanup retries — was refused and the janitor stayed stopped, leaving
  `kill -9` (which abandons the surviving apps and displays) as the only exit. Shutdown state and
  the janitor are now restored on every failed stop; a successful stop remains terminal.
- Turning Viewer Control off, or switching the streamed display, no longer freezes the Viewer
  window. Both transitions waited on the input queue, so they inherited the worst case of whatever
  was still being delivered — Accessibility hit-testing has a one-second timeout per candidate
  window under the pointer, plus focus-settle and pointer-pacing delays. Clicking a point stacked
  with several windows and then pressing the Control-Command-Escape exit chord could beachball the
  UI for seconds, with no frames painted and an unresponsive toolbar, at the one moment that
  escape hatch has to work. The cleanup is now scheduled onto the input queue instead of awaited;
  held keys and buttons are still released and queued input is still cancelled, because the gate
  epoch already invalidates the backlog synchronously.
- A request that arrives in pieces is no longer answered with `malformed message`. The daemon's
  framing treated a receive timeout and a mid-connection hangup as the end of a line, so a client
  that paused between writes for longer than the two-second socket timeout had its half-message
  decoded and rejected — and the request never ran, at an effective deadline shorter than the
  advertised one. A line is now a line only once its newline actually arrives; a stall waits out
  the caller's deadline instead. Symmetrically, a response too large for the socket buffer going
  to a slow reader is written to completion rather than abandoned mid-body, which used to reach
  the CLI and MCP clients as a JSON decode error rather than as the transport stall it was.

### Security

- Public release requires qualification of the exact signed artifact and explicit
  approval after all security and display-safety gates pass.
- Release packaging fails closed outside `arm64`.

## Release-notes process

Every user-visible pull request should update `[Unreleased]` under `Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, or `Security`. Release notes describe observable behavior and
migration or rollback implications; they are not generated solely from commit titles.

For an approved release:

1. confirm the target version matches `VERSION` and `SpaceOVersion.current`;
2. move the accumulated entries into `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD`;
3. leave a new empty `[Unreleased]` section;
4. link the notes from the GitHub release and retain the qualification record; and
5. if a security issue is under embargo, add the public detail only when coordinated disclosure
   permits it.

Do not call an artifact supported, publish its tag, or mark a signing/notarization ticket complete
until the exact public artifact has passed the release policy.
