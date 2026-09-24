# Troubleshooting

Start with these two commands. Most problems show up here with the fix printed next to them.

```bash
spaceo doctor      # capabilities, permissions, daemon state, displays
spaceo setup --no-prompt --no-self-test  # report and fixes without starting a live test
```

For a live session self-test, run `spaceo setup` while the desktop is idle; it creates a temporary
virtual display. A passing self-test does not establish app-input compatibility.

The daemon log is at `~/Library/Logs/SpaceO/daemon.log` (path shown by `doctor`). It records
every failed request. Set `SPACEO_LOG_DEBUG=1` on the daemon for full request logging.

`doctor` reports `focus-without-raise` as `n/a (intentionally disabled)`: the incompatible private
focus-record path was removed on purpose, and nothing needs fixing.

## Scripting and exit codes

Every command that accepts `--json` prints exactly one JSON object on stdout (`{ok, errorCode?,
error?, …}`, keys sorted); progress and prompts go to stderr. `events --follow --json` is the one
stream: one object per line. Global flags (`--json`, `--socket`, `--session`, `--lease`) may come
before the command. In text mode a failure prints `error: …` and, when there is one, `next: …`.

| Exit | Meaning | Typical codes |
|---|---|---|
| 0 | success | |
| 1 | the command failed | `operation_failed`, `bad_request`, `launch_failed` |
| 2 | usage error | `usage_error`: unknown command or option, bad value |
| 3 | daemon unavailable, busy, stopping, or outdated | `daemon_not_running`, `daemon_busy`, `daemon_outdated`, `daemon_unresponsive` |
| 4 | controller lease missing or wrong, or session owned elsewhere | `lease_required`, `session_detached` |
| 5 | isolation not verified, or breached | `isolation_requirements_unmet`, `isolation_breached` |
| 6 | wait condition not met before the timeout | `spaceo wait` with outcome `timeout`; `wait_timeout` in `steps` |

So `spaceo wait element_label Save --timeout 10 && spaceo click --label Save` no longer clicks
after a timed-out wait. `SPACEO_SESSION` and `SPACEO_LEASE` fill in `--session` and `--lease`;
`eval "$(spaceo session create --export)"` sets both. They are never applied to `session create`,
`daemon stop`, `daemon restart`, or `clean`, where a lease widens what the command may affect.

## Permissions

| Symptom | Cause | Fix |
|---|---|---|
| `MISS accessibility` in `doctor`; clicks and typing fail | The app running `spaceo` is not in Accessibility | System Settings → Privacy & Security → Accessibility. Enable the app named on doctor's `caller attributed to:` line (the error text names it too), not the `spaceo` binary. `spaceo doctor --fix` opens the pane for you. |
| Grants keep depending on which client started the daemon | The daemon inherits its spawner's TCC identity | `spaceo daemon install` (stably signed build) gives the daemon its own identity; grant it once. |
| `MISS screen-recording`; screenshots fail but input works | Same, for Screen Recording | Privacy & Security → Screen & System Audio Recording → enable the host app. |
| CLI says `ok` but `daemon can drive: NO` | The daemon was started by a different app (an MCP client) that lacks the grant | Grant Accessibility to that client, then `spaceo daemon stop` and let it restart. `doctor` reports client and daemon grants separately for this reason. |
| Grants were fine, then vanished after a rebuild | Ad-hoc-signed binaries change identity on every build | For the Viewer, `make viewer` picks up a Developer ID or Apple Development certificate if one exists; or re-grant. The CLI inherits its host's grants and is unaffected. |
| Viewer: "Control unavailable. Accessibility permission is required" | `SpaceO Viewer.app` needs its own grants | Enable the Viewer in both Accessibility and Screen Recording; the in-app banner links to the panes. |

## Daemon

| Symptom | Cause | Fix |
|---|---|---|
| `daemon matches CLI: NO — run spaceo daemon restart --operator` | You upgraded, but the old daemon is still running | `spaceo daemon restart --operator` drains it (existing sessions keep working) and starts the new build. A daemon too old to drain is waited on until it has no live sessions, then stopped; `--now` skips the wait. |
| `warning: the running daemon is 1.0.0 (pid N); this CLI is 1.1.1` | Same: the CLI was upgraded, the daemon was not | `spaceo daemon restart --operator`. |
| `daemon_outdated` / `the running daemon (1.0.0) predates spaceo find` (exit 3) | The old daemon does not know a command this CLI sends | Same restart. Before this check it looked like `unknown command 'find'`, a typo it was not. |
| `daemon running: yes (did not answer within 2s — busy?)` | A daemon holds the socket but is busy with a long request | Retry `spaceo doctor` in a few seconds. Doctor reports no orphaned displays and offers no fixes in this state, because the daemon still owns them. |
| Agents see `daemon_draining` | A restart is in progress | Existing sessions keep working; retry `session create` in a few seconds. The MCP server retries automatically. |
| `daemon_busy` | More than 64 requests in flight, or more than 32 event subscribers | Back off briefly and retry; a stuck client no longer stalls the others. |
| `no SpaceO daemon listening at .../spaceo-501.sock` | No daemon, or it is bound to a different socket | `spaceo daemon &`, or let your MCP client start it. With the LaunchAgent installed, `launchctl kickstart -k gui/$(id -u)/com.spaceo.daemon`, then `spaceo daemon status`. Check `SPACEO_SOCKET` is the same in the client and the shell. Read `daemon.log` for a startup error. |
| `daemon stop` says `already stopped` | Nothing was listening on the socket | Nothing to do; it exits 0 so stop-then-start scripts work on a clean host. |
| `daemon stop` waits or asks you to try later | A session teardown is in flight, or a previous daemon's recovery records are in their 30 s grace | Wait about 30 seconds and retry. Do not `kill -9` it. |
| Apps left running after a crash or `kill -9` | A daemon killed with SIGKILL cannot quit what it launched | Quit them by hand. A new daemon finishes cleanup of exact matches after grace; `spaceo session list` shows detached records and blockers. See [Session ownership and recovery](SESSION_RECOVERY.md). |
| Each agent seems to get its own daemon | Different socket paths | All clients for one user share one daemon at the default socket. Remove stray `SPACEO_SOCKET` overrides. |
| Density env vars are ignored | The daemon reads `SPACEO_SESSIONS_PER_DISPLAY` and `SPACEO_DISPLAY_SIZE` only at startup | Restart the daemon, or use `spaceo pool set N --operator` for displays created from now on. |

## Setup self-test

| Symptom | What to do |
|---|---|
| `daemon build` is missing, unknown, or mismatched | Finish active sessions, stop the daemon, then restart it from the updated CLI or rebuilt Viewer helper. Run setup again. |
| Caller grants pass, but `daemon input` or `daemon capture` fails | Grant the required permission to the app hosting the daemon, then restart that daemon. |
| `cleanup unconfirmed` | Inspect the uniquely named setup session with `spaceo session list`, then use the targeted recovery command printed by setup. |
| `self-test` is skipped | Fix the preceding `MISS` rows or rerun without `--no-self-test` on an idle desktop. A skipped test is not evidence of a working session. |

## Sessions and leases

| Symptom | Cause | Fix |
|---|---|---|
| `controller lease is required for session 'x'` | Session mutations and reads need the lease from `session create` | Pass `--lease UUID`. MCP clients do this automatically. |
| MCP reconnects and can no longer control its session | The old MCP process exited, so the daemon marked its session abandoned within seconds (not after the TTL). The new connection has no lease for it | Call `spaceo_session_claim` with the session id (CLI: `spaceo session claim --session x`) before its grace ends — 120 s for MCP-created sessions, 30 s by default otherwise; `session list` shows the time left. It keeps the apps and windows. After the grace the janitor quits its apps; to free it sooner, `spaceo session destroy --session x --operator`. |
| `session 'x' already exists` | Name in use, or still tearing down | Use another name, or destroy it, or wait for teardown to finish. |
| `session 'x' is paused by the human operator` | Someone has Control on in the Viewer | Release Control with Control-Command-Escape. If the Viewer crashed, reopen it and use Resume Agent for the paused session. The agent's lease cannot clear an operator pause. |
| `no session named 'x'` | Typo, or already destroyed | `spaceo session list`. |
| A session shows `abandoned` or `reclaimable` | Its controller exited, or stopped heartbeating past the TTL | Send `spaceo session heartbeat --lease UUID` while idle for longer than the TTL. An abandoned session can be taken over with `session claim` until its grace ends; reclaimable means the grace is over and the janitor is about to quit its apps. |
| `session destroy --all` fails | A detached recovery record has a blocker | Check the blocker in `session list` and follow the table in [Session ownership and recovery](SESSION_RECOVERY.md#observe-and-retry-recovery). |

## Input and clicks

| Symptom | Cause | Fix |
|---|---|---|
| A click is reported `unconfirmed` | A coordinate click landed where there was no accessibility element, or the app ignored it | Use a fresh `--element N` from `spaceo ax`, check the response, and read back the screen. Use coordinates only for right-click, double-click, modifiers, or drags. |
| `web clicking requires a SpaceO-managed Chromium DevTools bridge` | The browser was not launched by SpaceO, so there is no DevTools port | Launch it with `spaceo run` (for example `spaceo run "Google Chrome"`). Adopted browsers have no bridge. |
| Web actions refused with several page targets | More than one tab or target is open | `spaceo_list_targets`, then `spaceo_attach_target`. Web input is refused until one target is attached. |
| Scroll in Cursor or VS Code is refused or unconfirmed | Electron renderers ignore background wheel events; SpaceO uses the editor's own scroll command instead | Aim at a single visible editor pane. Grid layouts, non-editor panes (Settings, Agents, welcome), hover, and renderer drag have no confirmed channel. Horizontal scroll is delivered but unconfirmed. |
| Typing into an Electron editor reports "unobserved" | The keystroke did not change the document | The report is honest, not a bug. Click into the editor first, then retry. |
| Canvas, game, or video surfaces ignore input | They do not accept synthetic background events | Use a purpose-built API if available. Viewer Control uses similar background delivery and may have the same limitation. |
| An app briefly steals focus | Some apps self-activate | Check the isolation report, stop the affected workflow, and report a reproducible breach. A best-effort focus restoration does not make the disturbance an isolation pass. |
| Agent apps show in Cmd-Tab, the Dock, and notifications | macOS behavior; not solvable on-host | Expected. |
| `isolation: partial` | A required check could not be established; the public Accessibility route proxy may be unavailable | Inspect the per-check coverage. `partial` is not a pass; `intact` can still include explicitly inferred checks. Stop on `breached`. |

## Displays

| Symptom | Cause | Fix |
|---|---|---|
| `doctor` reports **orphaned displays** | Virtual displays outlived their owner (crash, `kill -9`, aggressive live-test churn) | Trigger a display sleep/wake, which rebuilds the display graph: `pmset displaysleepnow` then `caffeinate -u -t 3`. Never disable SIP. |
| Screen goes blank or input seems dead after heavy live runs | Same, at its worst; see the [incident report](incidents/2026-07-26-display-input-lockout.md) | Same sleep/wake. Do not run `make test-live` or the computer-use matrix on a desktop you are using, or with mirrored displays. |
| `SpaceO display ids` still listed 15 s after the last session ended | Empty displays stay for a 15-second reuse window | Expected. They retire on their own. |
| Session creation fails with a CoreGraphics or WindowServer error | The requested geometry or density could not be allocated | Lower `SPACEO_SESSIONS_PER_DISPLAY`, drop `SPACEO_DISPLAY_SIZE`, or check `spaceo pool`. |
| Viewer refuses Control on a display | It is a physical display, or an empty SpaceO display | Expected: physical displays are view-only; pick a SpaceO display that holds a session. |

## MCP clients

| Symptom | Cause | Fix |
|---|---|---|
| Client cannot start the `spaceo` server | `~` in the config path, or the binary is not executable | Use the absolute path (`/Users/you/.local/bin/spaceo`). Check `ls -l` on it. |
| Tools missing after an upgrade | MCP tools come from the `spaceo` binary the client launches, not from the daemon. The client's config still names an old copy (often `~/.local/bin/spaceo` from before `make install`), or the client was not restarted | `spaceo doctor` → **MCP clients** shows the path and version each client launches and marks `STALE` ones. Update that binary (`make install`) or re-register this one (`spaceo setup --client claude-code`), then restart the client. Restart the daemon too if doctor says it does not match. |
| `setup --client claude-code` says `claude` was not found | `claude` is not on the `PATH` of the shell running setup | Run setup from a shell where `which claude` works, or run the printed `claude mcp add -s user …` command yourself. |
| `claude mcp add` fails because `spaceo` already exists | An older registration is present | `spaceo setup --client claude-code` removes the user-scope entry first and shows both commands before running them. |
| setup warns the path is inside `.build/` | You registered a build product, which the next build or clean replaces | `make install`, then `~/.local/bin/spaceo setup --client claude-code`. |
| Want to test the server outside a client | — | `node scripts/mcp-smoke.mjs "$HOME/.local/bin/spaceo"` runs the black-box MCP test. |
| Tool failures are hard to trace | — | Each MCP failure is echoed to the client's stderr log with a trace id that matches the `daemon.log` record. |

## Building and testing

| Symptom | Cause | Fix |
|---|---|---|
| Build errors on a fresh checkout | Wrong toolchain | SpaceO is pinned to Xcode 26.0.1 / Swift 6.2. Check `xcodebuild -version` and `swift --version`. |
| `make test-live` skips everything | The process running the tests lacks the grants, or a required API or app is missing | Grant Accessibility and Screen Recording to the terminal running the tests. `make test-live-full` turns a skip into a failure on purpose. See [Live tests](LIVE_TESTS.md). |
| `make computer-use-check` exits `2` | A suite was skipped (Chrome or Cursor not installed) or a documented blocker remains | Install the missing app, or read the report. Exit `2` is "healthy but unknown", not a pass. |
| Live tests hang or the host looks wrong afterwards | Live suites create real displays and send real input | Run them in a dedicated login. See "Displays" above. |

## Reporting a bug

Collect these, remove usernames, paths, window titles, and app content, then open a GitHub issue
as described in the [support policy](../SUPPORT.md):

```bash
spaceo version --json
spaceo doctor --json
tail -n 50 ~/Library/Logs/SpaceO/daemon.log
```

Add the macOS version and build, how you installed SpaceO, the exact command or MCP tool call,
what you expected, and what happened. Request summaries omit direct typed-text, screenshot, accessibility, and lease payloads. Error
details can still contain window titles, paths, or app-provided text. Inspect and redact the
entire excerpt before sharing; do not assume a log is safe solely because it came from SpaceO.

Security issues go through [SECURITY.md](../SECURITY.md), not a public issue.
