# SpaceO 1.0.0

Status: prepared notes; release qualification and publication are pending.

SpaceO gives agents a headless macOS display for working with native applications through the
CLI, MCP, and SpaceO Viewer. This first release includes session ownership, scoped controller
leases, recovery, Chromium target binding, and explicit isolation reporting.

## Improvements in this candidate source

- Preserve normal window sizes, place full-display panels without an offset, and expose explicit
  preserve, fit, and cover placement with observed geometry receipts.
- Support menu-bar applications, bounded window readiness waits, launch arguments, timed drags,
  exact-label Accessibility selection, and stale snapshot/geometry errors.
- Expose structured readiness and errors, optional strict isolation assertions, memory-only MCP
  screenshots, and automatic controller lease renewal across 23 MCP tools.
- Pause actions on known isolation breaches and report partial or unknown evidence explicitly.
  Launch no longer blindly restores the previously foreground application.
- Improve Viewer session creation, Human Control arbitration, pause/resume, and recovery behavior.
- Improve guided setup, permission diagnostics, daemon shutdown, offline help, resource limits,
  and bounded presentation diagnostics.

See the [full changelog](../CHANGELOG.md) and
[transcript workflow contract](TRANSCRIPT_WORKFLOWS.md) for behavior and integration details.

## Platform and limitations

The intended distribution targets Apple Silicon and macOS 14 or later, subject to private-API
capability checks and per-release qualification. Intel is not supported for this release.
SpaceO isolates attention; applications retain the logged-in user's files, credentials, and
sessions. An attempted input action, submitted GPU frame, or missing presentation callback is
not proof of delivery or display cadence. External external controller integration remains unqualified.

## Installation and release artifacts

The planned payload is a Developer ID-signed, notarized and stapled DMG containing the CLI and
Viewer, accompanied by a signed SHA-256 checksum and signed candidate provenance record.
Follow [installation and verification instructions](INSTALL.md), including rollback/uninstall.
No downloadable artifact is qualified or published by these notes.
