# Private API host support

SpaceO treats private API compatibility as an evidence decision, not an availability check.
Resolving a symbol or finding an Objective-C class proves only that a name exists. It does not
prove a record layout, selector surface, calling convention, return ownership rule, or behavior.

Every private surface is therefore disabled unless the running process exactly matches a
capability-specific registry entry on all three axes:

- macOS major, minor, and patch version
- Darwin build (`kern.osversion`)
- process architecture (`arm64` or `x86_64`)

The registry in `SpaceOPrivate.m` is intentionally empty. In particular, the current macOS 27
development host is **not supported or qualified**. No tuple should be added merely because the
project builds, its symbols resolve, or a test happened to pass in the developer's primary login.

## Surfaces requiring independent evidence

| Capability | Private behavior or layout | Current qualified tuples |
|---|---|---|
| `virtual-display` | `CGVirtualDisplay` descriptor, mode, settings, lifetime, and teardown behavior | none |
| `focus-without-raise` | Three `SLPSPostEventRecordTo` records, including the assumed `0xf8` byte layouts and restoration behavior | none |
| `space-query` | SkyLight connection, managed-display spaces, window spaces, active Space, and WindowServer bounds calls | none |
| `per-pid-events` | Resolved `CGEventPostToPid` calling convention and delivery behavior | none |
| `ax-window-id` | Private `_AXUIElementGetWindow` calling convention and window-ID result | none |

Qualification is per row. Evidence for `space-query` on a host does not enable virtual displays,
focus records, per-PID events, or private AX lookup on that same host.

## Evidence required before adding an entry

Run the checks in a disposable macOS login or disposable VM snapshot. The primary developer login
is not an acceptable verification environment for display or input mutations.

Record an artifact containing:

1. The exact `sw_vers` output, `sysctl -n kern.osversion`, and process architecture.
2. Hardware/VM identity and whether the login can be discarded without data loss.
3. The exact SpaceO commit and compiler/Xcode version.
4. A result for every behavior covered by the capability entry, including failure and teardown.
5. Before/after evidence that the user's physical displays, active Space, frontmost application,
   key route, pointer route, and cursor were recovered or remained unaffected as applicable.
6. Repetition sufficient to exercise asynchronous teardown and partial-failure paths.
7. The artifact's durable repository path or URL.

For `virtual-display`, evidence must include creation, bounds publication, repeated teardown, and
post-crash/orphan inspection. For `focus-without-raise`, it must include a failure injected after
each record and verified route restoration. For `space-query`, validate every grouped SkyLight
call and returned ownership/type assumption. For per-PID events and AX-window lookup, validate both
successful delivery/lookup and a rejected or unavailable target.

## Adding a qualified tuple

After review of the recorded artifact, add one `SPOHostQualification` entry for one capability in
`SPOQualifiedHostRegistry()`. Its `SPOHostTuple.evidenceReference` must be non-empty and point to
the artifact. Copy the exact version, build, and architecture from that artifact; do not use
ranges, prefixes, or inferred compatibility with adjacent builds.

Then run:

```bash
swift test --filter HostCompatibilityTests
swift test --filter UnitTests
swift build
swift build --target SpaceOKit -Xswiftc -swift-version -Xswiftc 6
```

An OS update, Darwin build change, or architecture change produces a different tuple and fails
closed until independently qualified.

## Runtime and doctor behavior

`SpaceOPrivate` checks the tuple again at each Objective-C mutation/query boundary. Swift callers
cannot bypass it by invoking a symbol directly: per-PID event delivery also goes through the shim.
`spaceo doctor` prints the observed tuple, registry count, qualified surfaces, and a reason for
each unavailable capability. An empty missing-symbol list does not change unsupported status.
