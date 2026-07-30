# Private API runtime support

SpaceO enables each private surface from the classes and symbols available in the running
process. It does not use an operating-system version, Darwin-build, architecture allowlist, or a
host qualification registry.

| Capability | Runtime requirement |
|---|---|
| `virtual-display` | `CGVirtualDisplay`, its descriptor/mode/settings classes, and the selectors SpaceO uses |
| `space-query` | SkyLight connection, managed-display Space, window-Space, active-Space, and bounds symbols |
| `per-pid-events` | `CGEventPostToPid` |
| `ax-window-id` | `_AXUIElementGetWindow` |
| `focus-without-raise` | intentionally unavailable; incompatible private focus-record getters remain removed |

Availability is independent per row. A missing requirement disables only that capability and
produces a readable runtime error. TCC grants and application behavior can still affect an
operation after API discovery.

`spaceo doctor` reports the runtime inventory, TCC state, display graph, and a reason for every
unavailable capability. Runtime errors from CoreGraphics, SkyLight, Accessibility, or
ScreenCaptureKit are returned normally; SpaceO does not claim that an absent API works.

## Validation

Host validation records under `docs/validation/` document configurations that have been exercised.
They are evidence for maintainers, not admission entries, and do not gate other macOS versions,
builds, architectures, user logins, normal use, or the test suite.

Run the complete suite with:

```bash
make test
```

Run the focused WindowServer suite with:

```bash
make test-live
```

Live tests run in the current graphical login. A case may skip only when a technical prerequisite
such as an absent API, missing TCC grant, or unavailable target application prevents the tested
operation.
