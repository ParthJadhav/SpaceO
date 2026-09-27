# Privacy maintenance release qualification

Version: `1.0.1`. Status: **NO-GO: interactive Viewer qualification pending**.

The owner authorized history rewriting and a replacement release, and reserved this Mac for
live qualification on September 28, 2026. This is implementer qualification on the owner's
existing graphical login, not independent or fresh-user testing. Existing applications and the
pre-existing daemon were preserved. Publication has not been approved.

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

## Pending interactive check and recovery

The candidate Viewer connected to the isolated daemon and showed a live stream. Taking Control
paused the selected session, and an agent input attempt was refused with `session_paused`.
An external lock controller covered the virtual display. A synthetic text attempt through the
background automation route did not appear in the test document; this is **unconfirmed**, not
passed Viewer input. Normal unlocked typing, the local Control-Command-Escape path, and the
subsequent hand-back still require qualification. The owner was asked to unlock normally;
no lock, TCC, or Gatekeeper protection was bypassed.

The blocked check was stopped and inspected. The candidate Viewer exited gracefully; both test
sessions and their displays were destroyed, and the isolated daemon stopped. Postflight showed:

- zero SpaceO displays and zero orphan displays;
- lifecycle safety state ready and unchanged physical display topology;
- the pre-existing daemon and all pre-existing regular application processes preserved;
- no additional regular application processes;
- unchanged foreground process, physical pointer position, and pasteboard change count.

Only the remaining Viewer stage may continue after the owner unlocks and a fresh preflight
confirms readiness. The passing live suite and matrix must not be silently replaced by a rerun.
Publication remains gated until the missing results are retained and the release-owner directive
can be fulfilled with all required evidence.

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
