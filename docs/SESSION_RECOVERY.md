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
| **idle** | No successful owner activity since the reported last-activity time. Idle is an observation, not a separate lifecycle state. |
| **abandoned** | The lease expired or a controller with an exact process identity disappeared. The old lease can no longer be renewed. |
| **grace** | A 30-second safety interval beginning at abandonment, or at restart fencing when no earlier boundary exists. |
| **reclaimable** | Grace elapsed and no blocker prevents resource cleanup. This does **not** transfer the session to another controller. |

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
connection can observe the session but cannot recover the old connection's lease.

The short-lived CLI intentionally has no process-liveness identity: one CLI invocation exiting
does not immediately abandon work intended for the next invocation. Its TTL is the liveness
signal. Controllers that do supply an exact process identity can be marked abandoned when that
process disappears, without waiting for TTL expiry.

Once a live session is abandoned, owner-scoped mutations fail. After grace expires, the daemon
janitor reclaims its resources through the normal teardown path: SpaceO-launched apps are quit,
while adopted apps are released rather than treated as processes SpaceO owns.

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
