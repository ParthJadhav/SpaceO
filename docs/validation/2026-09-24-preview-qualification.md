# Native + Chromium preview qualification

The release owner selected this scope on September 24, 2026: native applications and
Chromium browsers, with managed Electron launches refused before process startup.
Cursor's startup focus issue remains open for future Electron support (SPAO-193).

This is implementer qualification on the owner-authorized existing graphical login,
not independent testing or qualification of a signed distribution. The Mac was reserved
for these live checks. Tests used an isolated daemon socket and synthetic documents;
unrelated applications and the user's default daemon were retained.

## Source evidence

- `make verify-release`: 1,588 deterministic Swift tests, 14 Node tests, and the 34-tool
  MCP smoke test passed.
- Focused Chromium and Electron launch tests: 57 passed, including refusal before
  Accessibility access or process creation.
- Release security-policy and live-test gate tests passed.
- [Full preview action matrix](2026-09-24-preview-matrix.json): 34/34 passed, zero failures,
  blocks, or skips. Native input, Chromium page actions, both isolation reports, Electron
  pre-launch refusal, session destruction, and final display cleanup were exercised.
- The matrix retained its binary SHA-256 and host architecture/kernel in the linked record.
  Both physical online displays and the active/mirrored topology remained unchanged;
  no SpaceO or orphaned SpaceO displays remained.

The harness now gives CLI inspection 15 seconds, exceeding the display-retirement
operation's existing 10-second bound. Earlier cleanup probes timed out at that same
10-second boundary. The final matrix passed the unchanged zero-display and topology
assertions; increasing this client timeout does not forgive a leaked display.

## Distribution status

No signed DMG is qualified by this record. Before publication, the exact immutable
Developer ID candidate must pass the signature, notarization, Gatekeeper, Viewer,
live-action, cleanup, and uninstall checks in [release policy](../RELEASE_POLICY.md).
The owner must record publication approval after reviewing that artifact evidence.
