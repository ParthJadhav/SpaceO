# Session ownership and recovery

SpaceO records session ownership and app provenance in a durable, per-socket ledger. The ledger
lets a new daemon explain and safely finish work left by an interrupted daemon; it does not let
the new daemon reattach to old WindowServer objects.

Controller ownership is coordination within one macOS login, not a security boundary. Every
client and app still runs with the authority of the logged-in user. Keep controller lease values
private so another local client cannot accidentally mutate the same session.

## Owners, leases, and activity

| Term | Meaning |
|---|---|
| **owner** | Diagnostic controller identity: a stable id, kind, label, and, when available, an exact process identity. |
| **lease** | Opaque UUID for the session and current daemon instance. Owner-scoped mutations must present it. |
| **TTL** | Time from the last successful heartbeat or owner-scoped mutation until lease expiry. The default is 300 seconds; clients may request 30 through 3,600 seconds. |
| **idle** | Seconds since the controller last *used* the session: an owner-scoped mutation or read. Heartbeats renew the lease but do not reset idle time, so a forgotten session still shows how long it sat unused (`idleSeconds`, `lastOwnerActionAt`). `lastActivityAt` keeps its older meaning and does include heartbeats. Idle is an observation, not a lifecycle state. |
| **abandoned** | The lease expired or a controller with an exact process identity disappeared. The old lease can no longer be renewed, but the session can be **claimed** until its grace ends. |
| **grace** | The orphan grace: a per-session interval beginning at abandonment, or at restart fencing when no earlier boundary exists. `session create` accepts `orphanGraceSeconds` from 30 through 1,800; the daemon default is 30 seconds, and sessions created through MCP use 120. `session list` shows the seconds left (`graceRemainingSeconds`). |
| **reclaimable** | Grace elapsed and no blocker prevents resource cleanup. The janitor quits the session's apps on its next pass. |

`spaceo session create` returns the lease only to the creating client. Save that value and pass it
as `--lease UUID` to heartbeats and session mutations. It is returned again by a successful
heartbeat, but is deliberately omitted from `spaceo session list`.

```bash
spaceo session create --session research --controller-ttl 300
spaceo session heartbeat --session research --lease UUID
spaceo run TextEdit --session research --lease UUID
```

Read-only observation does not renew a lease. A successful owner-scoped mutation does. Send a
heartbeat while the controller is reasoning, waiting, or otherwise inactive for longer than its
TTL.

The MCP server keeps leases inside the connection that created each session and supplies them to
later mutations automatically. Use `spaceo_session_heartbeat` for a long idle interval. A new MCP
connection cannot recover the old connection's lease, but once the old MCP process has exited it
can **claim** the session (below) and receive a new one.

A daemon event `lease.expiring` is published once when a lease has run 80% of its TTL without
renewal, so a controller following the event stream can heartbeat before it is abandoned.

The short-lived CLI intentionally has no process-liveness identity: one CLI invocation exiting
does not immediately abandon work intended for the next invocation. Its TTL is the liveness
signal. Controllers that do supply an exact process identity can be marked abandoned when that
process disappears, without waiting for TTL expiry.

Once a live session is abandoned, owner-scoped mutations fail. After grace expires, the daemon
janitor reclaims its resources through the normal teardown path: SpaceO-launched apps are quit,
while adopted apps are released rather than treated as processes SpaceO owns.

## Claim an abandoned session

The common accident is an MCP client restarting. Its stdio server exits at end of input, the
janitor sees the controller process gone within about three seconds, and the session becomes
abandoned. Without intervention its apps are quit when the grace ends. To keep working, the new
conversation claims it:

```bash
spaceo session claim --session research     # CLI; prints a new lease
```

or calls `spaceo_session_claim` with `{"session": "research"}` over MCP, which stores the new
lease exactly as `spaceo_session_create` does.

`session.claim` needs an explicit session id and no lease. It succeeds only while the session is
abandoned and not yet reclaimed; it issues a fresh lease to the caller's controller identity,
clears abandonment, and keeps every app and window. When the previous owner id differs from the
claimant's, the response carries a warning naming the previous owner, because the windows may
have changed while the session was unowned; re-read the screen before acting. The claim is
refused with a reason when the session:

- is still owned — `owned by <label>, active Ns ago`; ask that controller, or wait;
- was already reclaimed or destroyed — the refusal says when and what teardown did;
- is a detached record from a previous daemon — no window authority survived the restart;
- does not exist.

Leases and claims coordinate clients running as the same macOS user. They are not a security
boundary: any local client could equally end the session with `--operator`.

## What happens after a daemon restart

Before accepting requests, a new daemon loads the ledger and fences every lease written by the
prior daemon instance. It clears the old credential, marks those records abandoned and detached,
and preserves an already-recorded abandonment/grace boundary.

A detached record is observer-only. Persisted display ids, tile coordinates, and DevTools
metadata are last-known diagnostics, never authority to target a current object. The new daemon
does not reconstruct old Space or window handles, recreate the session, or route input to that
placement.

After the grace boundary, recovery uses only durable app provenance and process identity:

- A dead process entry or a PID now belonging to a different process is removed without a signal.
- A SpaceO-launched app is signalled only when its recorded process identity is exact and still
  matches immediately before the signal. Recovery requests a graceful quit, waits, then requests
  a forced quit from exact survivors.
- An adopted app is never terminated during detached recovery. It is released from the record,
  and recovery does not act on old window or display handles.
- An imprecise launched identity or an exact launched process that survives both quit attempts
  remains recorded as a blocker for an operator retry.

Interrupted mutations and teardown are stored as cleanup-only work. Recovery durably records
`cleanupComplete` before pruning a record in a separate write, so a failure between those writes
leaves a safe tombstone rather than an apparently reusable session.

For a live `session destroy --keep-apps`, SpaceO records release-only intent before it starts
teardown. If the daemon exits mid-command, replacement recovery may forget those process entries
but will not terminate them or delete a temporary profile still used by a surviving app.

## How sessions end

Every ending is explained. A named `session destroy` returns a `destroySummary`: the reason
(`owner`, `operator`, `janitor_abandoned`, or `detached_recovery`), the apps quit (and which of
them needed a forced quit), adopted or `--keep-apps` apps released, private browser profiles
removed, whether the session clipboard was cleared, the duration, and the recording path, action
count, or the error that stopped the recording from being finalized. The same reason is in the
`session.destroyed` event, and the daemon log records `session.destroyed` with a one-line summary.

The janitor logs `janitor.reclaimed` with that summary. Detached recovery logs `recovery.cleaned`
for every transition (terminated, released, and already-exited apps, survivors, blockers, and
the outcome) and publishes `session.destroyed` with reason `detached_recovery` when a record is
cleaned up.

## Sleep, wake, and display changes

The daemon observes wake from sleep and CoreGraphics display reconfiguration (public API only).
After either, it re-validates every session's virtual display and sweeps window containment. A
session whose display is gone is marked `lifecycleReason: display_lost`, its agent input is paused
with the reason `display lost after wake/reconfiguration`, and a `session.display_lost` event is
published once. Such a session cannot be repaired in place; destroy it and create a new one.

## Observe and retry recovery

Use either interface to inspect recovery state:

```bash
spaceo session list
spaceo session destroy --session SESSION_ID
```

The CLI and MCP list output distinguish a detached recovery record from a live target and show
its prior owner, age, last activity, abandoned/reclaimable state, recorded apps, and blockers.
SpaceO Viewer shows the same records under **Recovery**; they have no selectable display target.

Wait until the recorded grace boundary before retrying a named destroy. A new `--keep-apps`
choice cannot be applied after a session is already detached because prior-daemon window
authority is gone. Release-only intent that was durably recorded by an interrupted live
`--keep-apps` command is still honored automatically. Adopted apps are always protected from
termination by their provenance. `spaceo session destroy --all` also reports failure while any
detached record remains unresolved.

Common blockers are:

| Blocker | Operator action |
|---|---|
| `restart_grace_not_elapsed` | Wait for the reported grace boundary, then retry the named destroy. |
| `interrupted_mutation` or `cleanup_only` | Treat the record as cleanup-only; retry the named destroy after grace rather than trying to reuse the session. |
| `launched_process_survived` | Close or terminate the exact named process, verify it has exited, then retry the named destroy. |
| `imprecise_process_identity` | SpaceO refuses to signal a bare or ambiguous PID and cannot resolve the record automatically. Preserve it for operator investigation rather than guessing an identity. |
| `cleanup_complete` | No destructive action is needed. A later durable pass can prune the completed record. |

Do not edit or delete the ledger to silence a blocker. That discards the provenance and exact
identity needed to distinguish a SpaceO-launched process from an adopted one.

## Storage and failure behavior

The default ledger lives under:

```text
~/Library/Application Support/SpaceO/SessionState/
```

Its filename is namespaced by the normalized daemon socket path, so separate daemon sockets have
separate recovery state. SpaceO requires the directory to be owned by the current user with mode
`0700`, writes ledger files with mode `0600`, and replaces them atomically.

Corrupt, unsafe, oversized, or unsupported ledger state fails closed. The daemon does not treat a
bad ledger as an empty one because doing so could lose the only record that says which surviving
apps SpaceO launched and which it merely adopted.
