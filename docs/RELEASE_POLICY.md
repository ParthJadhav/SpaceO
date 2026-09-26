# Release policy

This policy separates implemented release automation from evidence that a particular artifact is
safe and approved for public use. A successful source build, local ad-hoc signature, CI run, or
notarization submission alone is not a release.

## Distribution model

SpaceO's supported distribution is a versioned disk image outside the Mac App Store. Each public
release must contain:

- the `spaceo` CLI, daemon, and MCP server;
- `SpaceO Viewer.app`;
- a SHA-256 checksum sidecar; and
- a detached SpaceO publisher signature over that checksum.

The DMG must itself carry a Developer ID Application signature. The CLI and Viewer must use hardened-runtime Developer ID Application signatures with secure
timestamps. The Viewer and DMG must be notarized and stapled, and the mounted payload must pass
the repository's exact publisher requirements and Gatekeeper assessments. The expected publisher
Team ID is `75LRT8TRQY`.

SpaceO is not distributed through or supported by the Mac App Store. Its private-API use,
background CLI/daemon model, and Accessibility and Screen Recording requirements are incompatible
with treating an App Store build as an equivalent artifact. An App Store Connect API key used
for Apple's notarization service does not make the resulting Developer ID DMG a Mac App Store
release.

## Platform and architecture

| Dimension | Public support policy | Current evidence |
|---|---|---|
| macOS | macOS 14 or later, subject to runtime capability checks and per-release qualification | `Package.swift` sets macOS 14 as the deployment target |
| Architecture | `arm64` for the first public release | The recorded live qualification is macOS 27 build 26A5368g on Apple Silicon |
| Intel | Not currently supported for public release | Release packaging fails closed outside `arm64`; no equivalent implementation or live qualification is recorded |
| Private APIs | Discovered independently at runtime; no OS-build allowlist | `spaceo doctor` reports availability; a resolved symbol is not by itself compatibility evidence |

A validation record is evidence, not a permanent host allowlist. Conversely, runtime discovery
does not make an untested host a supported release target. Expanding support to another
architecture requires its own build, signed-artifact verification, live qualification,
support-policy update, and maintainer approval. A universal DMG may be introduced only after both
slices and the combined artifact are independently verified.

## Required artifact qualification

The release owner selected a **native-app and Chromium preview** on 2026-09-24.
Managed Electron launches are outside this preview's support scope and must return
`unsupported_target` before starting a process. The full computer-use matrix must exercise
native and Chromium behavior and verify Electron refusal; refusal is an enforced product
limit, not a skipped renderer qualification. Electron support requires separate live
qualification before this limit can be removed. Publish this first DMG as a GitHub prerelease.
All signing, notarization, isolation, cleanup, and owner approval gates below still apply.

Before public approval, exercise the exact Developer ID-signed, notarized, and stapled candidate
obtained through the intended distribution path, not binaries left in `.build`. By explicit owner
direction on 2026-09-05, the implementer may perform this qualification in the owner-authorized
existing graphical login. A separate tester, clean Mac, or clean login is not required.
That desktop must be reserved for testing while the run is in progress; follow
[DISPLAY_SAFETY.md](DISPLAY_SAFETY.md).

Record existing applications, sessions, display topology, and permission state before testing;
preserve unrelated user state and verify it afterward. Do not switch users, log out, or change
display settings during a run. An interrupted run is not evidence: retain it, inspect and recover
the host before deciding whether another run is appropriate. Never automatically rerun it. Label the
result as implementer qualification on an existing login, not independent or fresh-user research.

The retained record must identify the commit and immutable tag candidate, version, artifact
SHA-256, macOS version/build, architecture, hardware class, display topology, TCC state, tester,
date, and results. At minimum it must show:

1. publisher signature, checksum, notarization staple, Gatekeeper, embedded version, and DMG
   verification using `make verify-distribution`;
2. a clean `spaceo doctor` before mutation, including physical and SpaceO display inventory;
3. CLI/MCP session creation, native app placement, Accessibility enumeration, direct input,
   capture, and truthful isolation reporting;
4. Viewer stream and control behavior, including the documented local escape path;
5. session destruction, daemon shutdown, app ownership behavior, and recovery where applicable;
6. no remaining SpaceO virtual display or daemon, and continued normal local display, pointer,
   keyboard, and focus behavior; and
7. rollback to the previous supported release or, for the first release, clean uninstall.

A skip, unknown required safety result, unexplained diagnostic, user-display disturbance, or
missing required result blocks public approval until resolved. Existing records under `docs/validation/` do not qualify a new artifact automatically.
The qualifier must download the immutable candidate produced by the workflow, verify
its candidate record and distribution, complete the intended-distribution checks above, and
retain or immutably link that result before approving publication.

## Live-test evidence

The live WindowServer suite is deliberately **not** an automated gate: commit `43a39d6`
(RELEASE_AUDIT Round 9) removed the commit-bound live record, the packaging dependency, and the
host-attestation opt-ins by owner decision, and neither CI nor `scripts/release.sh` runs or
verifies a live suite. What remains is an evidence requirement at approval time, checked by the
release owner rather than by automation: a successful, fully-run (no-skip) execution of the live
suite — a `Live WindowServer tests` workflow run, or an equivalent retained `make test-live` log —
against the release commit or a commit whose display/input behavior is unchanged since that run.
The release owner reviews that evidence at go/no-go; a missing, skipped, or failing live run
blocks approval exactly like any other unmet gate below.

## Public-release approval gates

The release owner must record a go/no-go decision only after all of the following are true:

- the intended commit is on the default branch and the immutable `vMAJOR.MINOR.PATCH` tag matches
  `VERSION` and `SpaceOVersion.current`;
- CI, optimized build, release security-policy tests, and MCP smoke pass, and the live-test
  evidence described above exists for the candidate;
- no open critical/high display-safety, input-safety, data-loss, security, signing, or
  distribution finding is accepted for the release;
- `CHANGELOG.md`, installation guidance, supported-platform policy, and known limitations match
  the candidate;
- Developer ID signing, notarization, stapling, checksum signing, exact-publisher verification,
  Gatekeeper assessment, and fresh-mount verification pass for the exact candidate;
- artifact qualification passes and its evidence is committed or linked immutably;
- rollback/uninstall artifacts and instructions are available; and
- the release owner explicitly approves publication after reviewing the evidence.

Tag creation starts candidate construction; it is not permission to publish. The credentialed
`candidate` job signs, notarizes, staples, verifies, and uploads one immutable GitHub Actions
artifact. That bundle contains the DMG, its signed checksum, and a Developer-ID-signed candidate
record binding their digests to the exact commit, tag object, workflow repository, run, and
attempt. Live-test evidence travels outside the bundle, as described above.

The separate `publication` job is gated by the protected `release-publication` environment and
must require an authorized reviewer in repository settings. It starts only after the candidate
artifact exists, downloads that artifact by immutable artifact ID, authenticates and repeats its
distribution verification, rechecks that the remote tag has not moved, and publishes those exact
files without rebuilding or using signing/notarization credentials. The existing `release`
environment may independently protect candidate signing credentials. Environment protection and
secrets are repository configuration, not claims made by this repository.

A maintainer must not bypass a failed gate by uploading locally built artifacts, rebuilding after
approval, or instructing users to disable Gatekeeper or SIP.

## Current status

The repository contains the packaging and verification implementation, but no evidence in this
repository proves that a Developer ID-signed, notarized, stapled, qualified public
artifact has completed these gates. The source version is `1.1.1`; the historical source-only
`v1.1.0` prerelease was removed during open-source history cleanup. A GitHub release draft for
`v1.1.1` holds proposed notes only: it has no tag, no binary assets, and does not qualify a
distribution. Release workflows
remain disabled pending candidate preparation and qualification. Source publication and
repository protection are complete. The additional `SPACEO_RELEASE_ENABLED`
switch defaults off, and the workflow verifies reviewer and tag restrictions before accessing
the signing environment. Follow
[docs/INSTALL.md](INSTALL.md) for artifact verification and maintainer commands, and do not
describe a public release as available until this section is updated with the retained approval
record.
