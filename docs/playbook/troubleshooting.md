# Troubleshooting for agents

Every SpaceO failure is structured: it starts with `[errorCode]`, carries for the common codes a
`recovery` object `{tool, arguments, then}` you can execute as-is (the session and window you
named are already filled in), otherwise a `next action:` line naming the tool to call or what to
ask the user, and ends with a `trace:` id. Run the recovery once, then retry once. If the same
code repeats, stop and report it, including the trace id. The human-facing symptom tables live in the repository's
`docs/TROUBLESHOOTING.md`; this is the agent-facing subset.

## Error codes

| errorCode | Meaning | Call next |
|---|---|---|
| `stale_snapshot` | The element index came from an earlier read; the outline has changed | `spaceo_read_screen`, then retry with a fresh index from the new snapshot |
| `stale_geometry` | The window moved, resized, or changed backing scale since your geometry token | `spaceo_list_windows`; retry with the new token, or use an element index instead of coordinates |
| `window_not_ready` | No matching window was confirmed within the wait budget; this does not prove absence | `spaceo_list_windows` with `timeout: 10`; retry once a window is listed. If the message says no app is attached, open one with `spaceo_open_app` instead of polling |
| `application_exited` | The app's process is gone; the message names the app, pid and exit time, and `spaceo_session_list` shows recent exits | `spaceo_open_app` to relaunch, then read the screen again |
| `session_paused` | A human holds Control in the Viewer, or you paused yourself | `spaceo_session_list`; wait until `inputPaused` is false, read `operatorHandoff`, re-read the screen. An operator pause cannot be cleared by `spaceo_session_resume` |
| `permission_denied` | The daemon lacks Accessibility (input) or Screen Recording (capture) | Stop. Tell the user which app the message names must be enabled in System Settings > Privacy & Security. No retry will succeed until it is granted |
| `wait_queue_timeout` | A wait exhausted its budget before initial or final authorization could enter the operation queue; no fresh session evidence is returned | Inspect daemon/session responsiveness with `spaceo_session_list`, then retry the wait; do not act on unconfirmed observation data |
| `batch_queue_timeout` | A batch could not enter initial or final authorization before its budget expired; final expiry retains historical step receipts but omits fresh session/isolation evidence | Review receipts and re-observe the session before further input; do not replay completed steps |
| `daemon_draining` | The daemon is draining ahead of a restart: existing sessions keep working, new ones are refused | Wait a few seconds for the replacement daemon, then retry `spaceo_session_create` |
| `daemon_stopping` | The daemon is shutting down | Wait for stop completion; a replacement is started by the client. Terminal for this call |
| `lease_required` | This connection does not hold the session's controller lease (another client created it, or the connection reconnected) | `spaceo_session_create` a session on this connection and use that. Leases are never recoverable from a list |
| `web_target_ambiguous` | A web action needs one bound Chromium target and the browser has several | `spaceo_list_targets`, then `spaceo_attach_target` with the intended id, then retry |
| `unsupported_target` | The element has no press action, or the surface does not accept synthetic input | `spaceo_read_screen`; pick a Button, Link or CheckBox index, or click the element's coordinates from a screenshot |
| `isolation_breached` | An action disturbed the user's desktop; the session is paused | `spaceo_verify_isolation`; resolve the named breach, then `spaceo_session_resume` |
| `isolation_requirements_unmet` | You asked for `strict` or `require_isolation` coverage the host cannot observe | Terminal. Drop the requirement or report that the host cannot satisfy it |
| `unknown_session` | No session with that id | `spaceo_session_list`; create one if needed |
| `capability_unavailable` | This macOS build lacks a required private API | Terminal. Tell the user to run `spaceo doctor` |
| `display_creation_failed`, `resource_limit` | The pool could not allocate a display or is at its bounds | Destroy sessions you no longer need. When the failure says `retry after Ns; held by: …`, the holders are named (abandoned ones say when they free up); retry after that delay. `spaceo_pool_status` shows capacity |
| `session_detached` | A daemon restart detached your session; its apps are quit after the recovery grace | The lease is dropped for you. `spaceo_session_create` a new session (a new name, or omit it) and reopen your apps |
| `daemon_outdated` | The running daemon is an older build than this MCP server and does not know the command | Terminal. Ask the user to run `spaceo daemon restart --operator` |
| `launch_failed` | The app could not be launched | Terminal. Check the app name, bundle id, or path |
| `capture_failed` | Capture or processing failed, timed out, is still pending, or exceeded a PNG limit | Wait for pending screenshot work to finish before retrying. Reduce scale/region for size errors. Missing Screen Recording reports `permission_denied` instead |
| `teardown_incomplete` | Destroy left a process or display behind | Read the named resource and call `spaceo_session_destroy` again; the retry is safe |
| `placement_rejected` | The app refused the requested window placement | Terminal. `cover` needs an exclusive display; try `preserve` or `fit` |
| `bad_request` | An argument was malformed or out of bounds | Fix the call; the message says which argument |

Codes marked terminal have no automatic recovery: report them to the user instead of retrying.

## Isolation verdicts

`spaceo_verify_isolation`, launches, and input receipts include an isolation report. It is
compact: `isolation: intact (N/N checks covered)` when nothing is wrong; for `partial`, the
one-sentence summary, the next step and only the checks that did not pass; for a breach, the full
per-check table (`dimension`, `status`, `coverage` observed/inferred/unknown, `evidence`).
`verbose: true` always prints the full table.

| Verdict | Meaning | Your next action |
|---|---|---|
| `intact` | Every required check had usable coverage and none failed | Continue. Some checks may still be marked `inferred` rather than observed |
| `partial` | No covered check found a breach, but at least one required check was unknown (usually key or text input routing, which has no safe public getter) | Continue with that gap in mind. This is the most common verdict on a healthy host and is not a failure — but it is not proof the user was undisturbed |
| `breached` | A check attributed a disturbance to agent territory (frontmost app, cursor, active Space) | Stop. The session is already paused and further input is refused. Report the evidence; resolve the cause; `spaceo_session_resume` only when you understand what happened |

The user switching apps mid-command is reported as a note, not a breach; SpaceO blames itself
only for changes that land on agent territory. `strict: true` or `require_isolation` on a tool
turns unobservable coverage into a refusal before any effect.

## Receipts that are not errors

- `unconfirmed`: the action was delivered but no effect was observed. Do not count it as done.
  Re-read the screen; for a coordinate click, switch to an element index.
- Managed Electron launches are refused in this preview; editor typing, selection and scrolling
  cannot establish a supported controller. Use a native app or managed Chromium instead.
- `truncated: true` in a read footer: you saw part of the window. Use `spaceo_find` or scroll.
- `diff_base_missing` on a `since` read: the base snapshot is gone; you received the full
  outline. Continue normally.
- `load: timeout` from `spaceo_open_url`: the page is still loading. Use `spaceo_wait_for`.
- `reused: true` from `spaceo_open_app`: the session already had this app; no new process was
  started.
- `after action: read the screen for fresh indices`: the action succeeded, but you have not read
  that window yet, so there was no base to diff against. `observe: unavailable (...)`: the
  action succeeded and only the follow-up read failed.
- `WARNING: the running SpaceO daemon is … but this MCP server is …`: the daemon is a different
  build. Some tools fail with `daemon_outdated` until the user restarts it.
- `the SpaceO daemon restarted; sessions from before the restart have ended`: create a new
  session. Read-only calls are replayed once automatically; actions never are.

## Sessions and leases

- Leases renew on every successful mutation and every ten seconds while the MCP connection is
  alive, so you never need to heartbeat by hand. `spaceo_session_heartbeat` exists for clients
  that drive the daemon without this server's renewal.
- Tools that omit `session` use the one session this connection holds. With several, the call
  is refused with `this connection holds sessions a, b; pass session`.
- `spaceo_session_list` marks this connection's sessions `[yours]` and shows other controllers'
  sessions as `[another controller; contents redacted]`, with idle time and lease expiry.
- A session showing `abandoned` or `reclaimable` lost its controller. Reclaimable means safe to
  clean up, not safe to take over.
- `spaceo_session_destroy` ends only sessions this connection created. Other agents share the
  pool and keep theirs. If a destroy reports blockers, the retry is safe.

## Web

- `web clicking requires a SpaceO-managed Chromium DevTools bridge`: the browser was not launched
  by SpaceO. Use `spaceo_open_url` or `spaceo_open_app` for the browser inside the session.
- Refusals in Cursor or VS Code (grid layouts, non-editor panes, hover, renderer drag) are
  documented limits, not bugs. See `spaceo://docs/drive-web`.
- An `incomplete editor pane discovery` or accessibility traversal budget error means SpaceO
  could not confirm the layout for scroll or selection. Retry after the editor responds, or
  simplify its layout; a partial pane list does not authorize an active-editor fallback.
