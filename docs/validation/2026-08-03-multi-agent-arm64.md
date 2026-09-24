# Scripted live multi-agent regression (SPAO-167) — 2026-08-03, macOS 27.0 (26A5368g), arm64

Three concurrent sessions on two SpaceO displays, one app class each, driven continuously for
about 10.5 minutes in the user's active graphical login, against the release binary at commit
`131821d` (which includes the SPAO-147 lease enforcement — every scripted action authenticated
with its session's lease).

## Topology

| Session | Display | Tile | App | Class |
|---|---|---|---|---|
| a167-1 | 101 | 1/2 | TextEdit | AppKit |
| a167-2 | 101 | 2/2 | Google Chrome (private profile, DevTools) | Chromium |
| a167-3 | 102 | 1/2 | Cursor | Electron |

Daemon: release build, isolated socket, `--sessions-per-display 2`. Each session created with
its own controller identity and 3600 s lease; all reads and mutations passed `--lease`.

## Drive

201 iterations over three chunks (~10.5 min wall clock). Per iteration: typed into TextEdit,
read and scrolled the Chrome page through DevTools (`ax --full --web`, `scroll --web`), read the
Cursor accessibility tree and hovered it, and captured all three tile screenshots. Every fourth
iteration ran `verify` on all three sessions and a geometry containment audit from
`session list --operator`.

## Results

- **1,755 actions, 1,740 succeeded (99.1%).** Per-action wall-clock latency:
  `ax` p50 48 ms / p99 96 ms; `ax --web` 35/58; `move` 45/69; `scroll --web` 27/48;
  `screenshot` 124/276; `type` 372/532; `verify` 27/77.
- **Containment: 49/49 audits clean.** Every window stayed on its stage and inside its own
  tile's frame for the whole run; no off-stage window, no cross-tile geometry overlap.
  (Tile screenshots were captured throughout but asserted geometrically, not by image analysis.)
- **Isolation: 147/147 `verify` calls returned no covered failures.** Frontmost-application and
  cursor-location checks passed on every sample, so the user's session was undisturbed on every
  observed dimension; key/text input-route coverage remains "unknown" by design (SPAO-163).
- **Teardown:** the three named destroys ran concurrently and all completed; 0 sessions
  remained; `daemon stop --operator` succeeded; final `doctor` showed `spaceO: []`,
  `orphanedSpaceO: []`, user display active, no daemon process. Chrome's private profile was
  cleaned up with the session.
- **Daemon latency during concurrent teardown:** doctor probes measured p50 ≈ p99 ≈ 2.1 s
  (n=4) while the three destroys were in flight — the daemon serializes behind teardown, which
  is exactly the SPAO-150 responsiveness gap; recorded here as its baseline measurement.

## Anomaly

One ~6-second window (three consecutive iterations, mid-run) returned fast (~20–35 ms) errors
for the five non-screenshot actions on all three sessions, then recovered without intervention;
screenshots kept succeeding during the window and the missing typed iterations are visible as a
gap in the TextEdit document. Error bodies were overwritten by later successes, so the cause is
unattributed. Follow-up: the drive harness should retain per-failure response bodies; if the
window recurs it needs a ticket.

## Verdict

SPAO-167's core claim is demonstrated: three concurrent agents on two displays, three app
classes, ≥10 minutes of continuous driving, no window escape, no covered isolation breach, user
display/cursor undisturbed on every observed check, and a teardown that leaves zero SpaceO
state. Remaining deltas against the ticket's letter: screenshot cross-tile assertion was
geometric rather than image-based, and the unattributed 6-second error window above.
