# Changelog

All notable user-visible changes are recorded here. SpaceO follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses the structure from
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- MIT open-source license.
- Responsible-disclosure, security-boundary, support, and release-governance policies.
- Bounded session, display, framebuffer, tile-size, and creation-rate admission with fail-closed
  display-graph checks before and after virtual-display attachment.
- Explicit safe and live test runners; live qualification records the exact commit and fails on
  missing prerequisites or skipped integration tests.
- Fail-closed Developer ID DMG packaging, notarization, stapling, checksum signing, and
  distribution verification automation.
- Installation, upgrade, rollback, and uninstall guidance for verified release artifacts.

### Security

- Public release now requires independent qualification of the exact signed artifact and explicit
  approval after all security and display-safety gates pass.
- Release packaging requires a passing live qualification record for the exact `arm64` commit.

`VERSION` currently contains `1.0.0`, but that number is not a claim that 1.0.0 has been publicly
released. This section remains unreleased until the gates in
[docs/RELEASE_POLICY.md](docs/RELEASE_POLICY.md) are satisfied and a maintainer approves a tag.

## Release-notes process

Every user-visible pull request should update `[Unreleased]` under `Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, or `Security`. Release notes describe observable behavior and
migration or rollback implications; they are not generated solely from commit titles.

For an approved release:

1. confirm the target version matches `VERSION` and `SpaceOVersion.current`;
2. move the accumulated entries into `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD`;
3. leave a new empty `[Unreleased]` section;
4. link the notes from the GitHub release and retain the qualification record; and
5. if a security issue is under embargo, add the public detail only when coordinated disclosure
   permits it.

Do not create a dated release section, call an artifact supported, or mark a signing/notarization
ticket complete until the exact public artifact has passed the release policy.
