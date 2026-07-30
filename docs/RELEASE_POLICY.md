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

The CLI and Viewer must use hardened-runtime Developer ID Application signatures with secure
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

## Required independent qualification

Before public approval, a person other than the change implementer must exercise the exact
Developer ID-signed, notarized, and stapled candidate obtained through the intended distribution
path. Qualification must run on a clean supported host or a documented clean graphical login,
not against binaries left in `.build`.

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
qualification performed only by the implementer blocks public approval until independently
resolved. Existing records under `docs/validation/` do not qualify a new artifact automatically.

## Public-release approval gates

The release owner must record a go/no-go decision only after all of the following are true:

- the intended commit is on the default branch and the immutable `vMAJOR.MINOR.PATCH` tag matches
  `VERSION` and `SpaceOVersion.current`;
- CI, optimized build, release security-policy tests, MCP smoke, and relevant live tests pass;
- no open critical/high display-safety, input-safety, data-loss, security, signing, or
  distribution finding is accepted for the release;
- `CHANGELOG.md`, installation guidance, supported-platform policy, and known limitations match
  the candidate;
- Developer ID signing, notarization, stapling, checksum signing, exact-publisher verification,
  Gatekeeper assessment, and fresh-mount verification pass for the exact candidate;
- independent qualification passes and its evidence is committed or linked immutably;
- rollback/uninstall artifacts and instructions are available; and
- the release owner explicitly approves publication after reviewing the evidence.

Tag creation is the publication trigger in the current workflow, so approval must be recorded
before pushing the tag. The protected `release` environment should require an authorized reviewer
where repository settings support that control. The credentialed workflow must fail closed; a
maintainer must not bypass a failed gate by uploading locally built artifacts or instructing users
to disable Gatekeeper or SIP.

## Current status

The repository contains the packaging and verification implementation, but no evidence in this
repository proves that a Developer ID-signed, notarized, stapled, independently qualified public
artifact has completed these gates. Version `1.0.0` therefore remains planned/unreleased. Follow
[docs/INSTALL.md](INSTALL.md) for artifact verification and maintainer commands, and do not
describe a public release as available until this section is updated with the retained approval
record.
