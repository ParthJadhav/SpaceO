# Privacy maintenance release qualification

Version: `1.0.1`. Status: **GO — owner approved the disclosed scope and confirmed normal host postflight; protected publication pending**.

The owner authorized history rewriting and a replacement release, and reserved this Mac for
live qualification on September 28, 2026. This is implementer qualification on the owner's
existing graphical login, not independent or fresh-user testing. Tester: the Codex implementer
agent operating for GitHub account `ParthJadhav`; release owner: `ParthJadhav`. Existing applications and the
pre-existing daemon were preserved. The owner renewed the reserved-host authorization and directed completion of the remaining
release work after normal unlock. Publication uses the protected workflow and the exact candidate
identified below; the tag and artifact have not changed.

## Candidate identity

| Field | Value |
|---|---|
| Source commit | `7f80fc756a664daadd7ed8d8fb422fe28e65cb01` |
| Immutable tag | `v1.0.1` |
| Tag object | `7970665e11bafa44170a0e40947392c25d0564a7` |
| CI | [36346722098](https://github.com/ParthJadhav/SpaceO/actions/runs/36346722098), passed |
| Candidate workflow | [36347116087](https://github.com/ParthJadhav/SpaceO/actions/runs/36347116087), signing passed; publication waiting |
| Immutable Actions artifact | `10941066931` |
| Artifact archive SHA-256 | `7cb509da4ce1f02676247e1fb5c38b98c2f7e43206497d79f611348fdd999487` |
| DMG SHA-256 | `7e595ef101bcd1bc9e35efc5624322a78593cda2d6e757463178dd63b9044bee` |
| Host | Mac17,9, Apple M5 Pro, arm64; macOS 27.2 build 26B5091g |
| Physical displays | One online and active, no mirroring; unchanged after testing |
| Permissions | Accessibility and Screen Recording granted; no permission changes made |

The downloaded archive matched GitHub's immutable artifact digest. The signed candidate record
was authenticated and bound to the exact commit, tag object, workflow repository, run, and
attempt. CLI and Viewer were copied from that verified DMG into a private staging prefix and
verified again. No normal installation was replaced. The test daemon used its own private socket
and matched the candidate's version and build identity.

Relative to the pre-migration main branch, runtime source changes only the embedded version.
Relative to 1.0.0, it also includes the previously committed fix that refuses to overwrite
unreadable MCP client configuration. Display, input, and session implementation is unchanged.

## Completed checks

| Check | Result |
|---|---|
| `git diff --check`, public-file privacy checks and regression fixtures | Passed |
| Rewritten source history and candidate build-log credential scans | No credentials detected |
| Release security-policy and live completeness-gate tests | Passed |
| Release configuration check and dry run | Passed |
| `make verify-release` | 1,625 deterministic Swift tests, shell/Python/Node fixtures, 34-tool MCP smoke passed |
| Optimized warnings-as-errors build | Passed |
| Signed candidate and distribution verification | Publisher requirements, signed checksum, notarization staples, Gatekeeper, embedded version, fresh mount, and provenance passed |
| Packaged-file privacy check | No personal email, personal home path, or historical signing-name documentation example |
| Full supervised live WindowServer suite | **16/16 passed, zero failures, zero skips**, 1,472 seconds; completeness checker passed |
| Full computer-use matrix against the exact signed candidate | **36/36 passed**, zero failures, blocked results, or skips; Electron pre-launch refusal included |
| Matrix cleanup | No sessions, virtual displays, or orphan displays; physical topology unchanged |
| Staged rollback | Previous signed 1.0.0 CLI/Viewer restored and verified in the private test prefix; candidate restored afterward |

The live suite ran against the candidate source tree. The matrix ran against the downloaded
candidate, not a local development build. It exercised native and Chromium placement,
Accessibility, input, capture, isolation reporting, cleanup, and enforced Electron refusal.

## Pre-mutation preflight

Preflight was also retained before the earlier phases; the final focused snapshot is not used
retroactively as their baseline:

| Phase | Retained pre-mutation result |
|---|---|
| Direct live XCTest suite | Host readiness and lifecycle safety `ready`, drive/capture available, one physical display, no mirrored/SpaceO/orphan displays. Overall doctor `ok` was false because installed clients and the pre-existing 1.1.1 daemon did not match the 1.0.1 CLI; that daemon was not used by the direct XCTest suite. Per-case display/TCC admission and cleanup passed in the retained full live log. |
| Exact-candidate matrix, before the initial Viewer attempt | Isolated daemon 1.0.1 matched CLI; `ok`, drive, capture all true; readiness and lifecycle safety ready; one physical display and no mirrored/SpaceO/orphan displays. |
| Resumed nested Viewer attempt | Fresh isolated-daemon doctor before session creation reported the same clean candidate state and inventory. |

Private evidence SHA-256 values:

- pre-live host diagnostic: `d2f40f4727b836301c0df343182843910500b5ef9a2ad1cf289fbfb2fca1ef64`;
- clean candidate pre-matrix diagnostic: `49d137a81487f836dbefae3867ab12b7c3fe73ee490358a92735553d17b30bbe`;
- clean resumed-Viewer diagnostic: `3741c88d7b23a4d255db0cc9d4caa6b413f756589453c9d4778e18995ae95f67`.

The retained `spaceo doctor --json` result was obtained using the exact candidate CLI and its
isolated candidate daemon **before creating the focused qualification session**. It reported
`ok: true`, `canDrive: true`, `canCapture: true`, daemon version `1.0.1`, and
`daemon.matchesCLI: true`. Readiness was `ready` with no blockers; lifecycle safety was `ready`.
The display inventory contained one physical display, online and active, no mirrored user display,
zero SpaceO displays, and zero orphan SpaceO displays. Accessibility and Screen Recording were
granted; no grants or host configuration were changed. The default pre-existing daemon was left
untouched. Private preflight SHA-256: `a63eb994a03f7d76f9c2275d6772cb7a2787f0d90f89e4b7023432ac42dd095f`.

## Interactive qualification and recovery

The initial check was blocked by an external lock controller. It was stopped and cleaned up;
the owner later unlocked normally and reserved the Mac again. No authentication or permission
protection was bypassed.

The resumed check confirmed Viewer typing in a synthetic TextEdit document, agent refusal with
`session_paused`, local Control-Command-Escape, hand-back, and subsequent agent typing. An initial
nested arrangement placed Viewer on another virtual display and showed intermittent stream
staleness. A later absolute automation click did not match the relative virtual pointer used
while host input is captured; the UI named Finder and no keys were sent to that target. Those
observations were retained, the test was stopped, and all test resources were cleaned up before
further diagnosis.

A metadata-only ScreenCaptureKit diagnostic received 25 complete frames and 414 valid idle
samples over approximately 15 seconds. No image contents were saved by that diagnostic. Source
inspection identified the distinction between absolute background automation and captured
relative-pointer input. This does not qualify the nested Viewer arrangement or claim a runtime
fix for its stream behavior.

A focused qualification then used the normal arrangement: the exact signed Viewer, launched
with `--background` and moved through the standard Window menu to the built-in display, with
only the synthetic TextEdit target on an exclusive virtual display. The target window was fitted
to its display before control. Results:

- the stream stayed live before, throughout 44 seconds of control, and after hand-back;
- the UI identified TextEdit as the keyboard destination before any text was sent;
- Viewer-typed synthetic text was confirmed independently in Accessibility and live pixels;
- agent input during human control was refused and its marker was absent;
- Control-Command-Escape opened the hand-back sheet locally;
- Skip resumed the agent, and subsequent agent text was confirmed in the target document.

The earlier full live suite and exact-candidate matrix were not rerun. Source, scripts, workflows,
and tests remain unchanged from the signed candidate. Viewer-on-virtual-display nesting is formally excluded from the owner-approved 1.0.1 supported scope
and disclosed in release notes and user guidance; no runtime fix is claimed. Publication remains
approved by the owner on September 28, 2026, with normal host postflight subsequently confirmed. Use Viewer on the physical display for human control.

Final cleanup left zero SpaceO displays, zero orphan displays, lifecycle safety ready, and the
same physical display topology. All pre-existing regular applications and the pre-existing daemon
were preserved, with no additional regular app processes. Foreground application and pasteboard
change count matched the focused check's baseline. Physical pointer position changed during the
interactive Viewer test; it is not claimed unchanged. Control was released, the capture breadcrumb
was cleared, and the test Viewer and isolated daemon exited. The earlier full matrix separately
verified agent-side pointer/focus isolation.

When explicitly asked to confirm normal local input after testing, the owner reported that
Command–Tab switches applications but focus or keyboard input feels wrong. This is a failed host
postflight, regardless of the individual checks above. Read-only inspection found no remaining
test processes, virtual/orphan displays, capture breadcrumb, or held modifier keys. A single call
to the existing system-shortcut restoration function returned success; that return value does
not establish recovery. The owner subsequently withdrew the concern as unrelated to this testing. Attribution to SpaceO
is therefore not established. When explicitly asked whether the Mac’s pointer, keyboard, and app focus were behaving normally,
the owner answered “Yes, all behaving normally.” This completes the required host postflight.
No additional live tests, display creation, or synthetic input were performed during recovery.

## Privacy migration and retention

The public main history was rewritten with a private recovery bundle retained. Personal owner
email metadata now uses the GitHub noreply address, and historical personal signing examples
were removed. The current source tree was verified byte-for-byte identical across the rewrite.
The temporary administrator exception needed for the authorized force push was removed
immediately; the original branch protection was restored and verified.

The withdrawn 1.1.2 candidate artifact was removed after preserving and validating a private
recovery copy. The existing 1.0.0 release remains available while the replacement is gated. Its
release, old tag, and candidate artifact will be retired only after the replacement download is
verified. GitHub retains 19 old read-only pull-request head refs and cached historical views;
a private Support request is prepared. Rewriting main cannot remove those refs or third-party
clones. Publisher name and Team ID remain necessary public certificate metadata.

Raw evidence stays in an owner-only local directory, `.artifacts/privacy-migration/`, and is not
uploaded as a public artifact. Retained evidence hashes:

- full live log SHA-256: `4aa96a50e41bc231eba08d029d89d9e1a6e65e24488e33eb82f1d95a21c3e9d5`;
- exact-candidate matrix report SHA-256: `81a51e6bbf6977f44dae740e517da38df0e29ad614c3e851dc724ab0e1f22cfc`.

- focused Viewer result SHA-256: `21fdc4333c45f1d2659da4ff692a600c77685280ebb07fb7bc612551e8f4729b`.

## Owner publication decision

On September 28, 2026, after reviewing the physical-display Viewer qualification and the
unresolved nested-Viewer limitation disclosed in PR #22, the release owner explicitly directed:
“Approve this scope and publish v1.0.1.” This records approval of the disclosed scope and publication of the exact candidate above,
conditional on the release gates. After withdrawing the Command–Tab concern as unrelated, the
owner explicitly confirmed normal pointer, keyboard, and app focus behavior. Host postflight is
complete and the publication approval remains in force. The
existing signed release stays available until all replacement public downloads are verified;
retirement of the superseded release and history references follows that verification.

## Public release metadata

Candidate construction necessarily predates exact-artifact qualification. The immutable tag and
signed artifact stay unchanged; the completed qualification and owner GO are linked by the exact
post-tag documentation commit. This follows the release policy's committed-or-immutably-linked
evidence model rather than relabeling an already-qualified binary.

The protected publication job creates the release with generic notes. As part of completing this
publication, the release body is replaced with the owner-approved scope, the explicit unsupported
nested-Viewer warning, and immutable links to this qualification record and installation guidance.
The replacement is not treated as verified, and the old release is not retired, until both the
public notes and all five public asset bytes are verified. No candidate bytes or tag are changed
by release-note finalization.
