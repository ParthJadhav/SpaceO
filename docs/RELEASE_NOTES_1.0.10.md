# SpaceO 1.0.10

This maintenance update stops an old WindowServer report from blocking SpaceO for the rest of
the boot, and carries an internal cleanup with no intended behavior change.

- **Past WindowServer reports no longer block display creation.** Earlier versions refused to
  create displays until the Mac restarted once a WindowServer crash or watchdog report had been
  written during the current boot. With display identities bounded and leftover ColorSync state
  removable since 1.0.9 (RA-057), the owner retired that check: neither the daemon nor the
  live-test preflight reads DiagnosticReports any more, and host-health reports drop
  `windowServerDiagnosticReports` and the `recent_windowserver_diagnostic` reason. Current
  ColorSync load, memory pressure, swap and creation budgets still refuse.
- **Clearing an old latch.** A `recent_windowserver_diagnostic` latch recorded by 1.0.9 or
  earlier stays until cleared. After updating, stop all display owners and run
  `spaceo safety clear-host-health --operator`.
- **Internal cleanup ([#67](https://github.com/ParthJadhav/SpaceO/pull/67)).** Each MCP tool is
  now defined in one place, and request limits and vocabularies are defined once on the type
  that enforces them. The MCP `tools/list`, accepted arguments, refusal messages, CLI help and
  the daemon protocol are unchanged. Unused members of the internal `SpaceOKit` module were
  removed; that module is built into the CLI, daemon, MCP server and Viewer and is not
  distributed or supported as a library.

If 1.0.9 left your Mac needing ColorSync cleanup, `spaceo doctor` still says so; see
[display identity residue](https://github.com/ParthJadhav/SpaceO/blob/v1.0.10/docs/DISPLAY_SAFETY.md#display-identity-residue).

## Validation and limits

The release source passed the deterministic suite, the optimized warnings-as-errors build, the
MCP smoke check, the release-security and live-test gate tests, and hosted CI. A
normal-admission live run on the cleaned development Mac met RA-057's closing condition after
the report check was retired, on a source build that predates the #67 cleanup.

This is an owner-directed maintenance release with a qualification exception. After #67
merged, the owner instructed: "merge, deploy and create a new version". The release was
prepared from an agent session on the owner's active desktop, where the live suite and the
computer-use matrix must not run, so the full live suite, the computer-use matrix and
signed-artifact behavior qualification are missing for 1.0.10. None of them is relabeled as
passed.

Supported scope remains native applications and managed Chromium, with Viewer on a physical
display. Managed Electron is refused before launch.
[Issue #38](https://github.com/ParthJadhav/SpaceO/issues/38) remains open for
empty/inactive-display qualification. Runtime health refusal, creation budgets and owner
retention remain enforced. Version 1.0.9 remains available for rollback.
