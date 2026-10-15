# Off-screen retained-window owner lookup (#47)

Issue #47 reported that every window read in a session, including `session.list` for every
client, failed for 30–60 seconds with `known window owner is unavailable` after Chrome opened
or closed a sign-in window.

## Cause

Retained-window discovery keeps a window that accessibility omitted only when the WindowServer
still has its geometry and names its owner. The owner came from
`CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)`. A bounded, read-only probe
against a managed Chrome on macOS 27.2 (26B5091g) showed that this query returns no entry for
ordered-out windows. For the same window IDs, SkyLight still reported bounds, the full
`.optionAll` listing named the Chrome process, and `CGWindowListCreateDescriptionFromArray`
given a raw-ID array named the same owner. The earlier boxed-number call returned nothing for
any window. Only counts and window numbers were recorded, without titles or screenshots.

## Change

- `liveOwnerPID` builds a one-element CFArray of the raw window number (no callbacks) and asks
  `CGWindowListCreateDescriptionFromArray`. It still requires exactly one matching window and
  a positive PID representable by `pid_t`.
- `session.list` no longer fails when one session's refresh is incomplete. That row keeps its
  last-known windows and reports `windowDiscoveryFailure`. Window commands, mutations and
  teardown still refuse incomplete discovery. All sessions in one listing share a four-second
  discovery budget; a session reached after it is exhausted keeps its cached row and says so.
  The Viewer's sidebar and inspector mark windows that may be out of date.
- `doctor` reads only the service's own `state`/`pid` from `launchctl print`; nested endpoint
  and event-source blocks no longer report a running LaunchAgent as not running.
- The MCP server re-checks a pending drift warning against the daemon answering now, so a
  restart that replaced the daemon between calls does not report the old version.

## Verification

A fixture app with two windows orders one out after eight seconds without closing it. It ran
in one session on a throwaway daemon using the explicit testing-host override, on an otherwise
unchanged source build:

- Before the fix, `windows` and `session list` both failed with
  `known window owner is unavailable`, and `session destroy` refused with incomplete discovery
  until an operator daemon stop.
- With the fix, `windows` succeeded, `session list` returned both windows without a failure,
  the isolation audit passed, and `session destroy` completed. Physical display 1 remained the
  only online display afterwards.

Deterministic tests cover the raw-ID array, the listing contract and its redaction, nested
`launchctl` states, and drift revalidation. This is diagnostic live evidence under the testing
override, not release qualification.
