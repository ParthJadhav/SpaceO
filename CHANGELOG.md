# Changelog

All notable user-visible changes are recorded here. SpaceO follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses the structure from
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- MIT open-source license.
- Responsible-disclosure, security-boundary, support, and release-governance policies.
- Separate safe and live test runners: `make test` excludes `IntegrationTests`, `make test-live`
  runs them against the real WindowServer with no opt-in environment variables.
- Fail-closed Developer ID DMG packaging, notarization, stapling, checksum signing, and
  distribution verification automation.
- Installation, upgrade, rollback, and uninstall guidance for verified release artifacts.

### Fixed

- A `spaceo daemon stop` that reports incomplete teardown no longer disables the daemon. It
  previously latched shutdown before running teardown, so every later command — including `ping`,
  `session list`, and cleanup retries — was refused and the janitor stayed stopped, leaving
  `kill -9` (which abandons the surviving apps and displays) as the only exit. Shutdown state and
  the janitor are now restored on every failed stop; a successful stop remains terminal.

### Security

- Public release now requires independent qualification of the exact signed artifact and explicit
  approval after all security and display-safety gates pass.
- Release packaging fails closed outside `arm64`.

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
