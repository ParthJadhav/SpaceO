# SpaceO 1.0.9

This update addresses the WindowServer/ColorSync slowdowns and freezes that heavy SpaceO use
could cause (RA-057). After updating, run `spaceo doctor`; if it asks for cleanup, follow the
steps below once.

- **Display identities are bounded.** Earlier versions gave every virtual display a new random
  serial. macOS keeps a ColorSync device registration, a display profile and WindowServer
  mappings for every serial it sees and never removes them, and ColorSync re-reads that
  registry for each display request. On a heavily used Mac every display change got slower until
  ColorSync saturated and WindowServer's watchdog ended the login session. Serials now come from
  a bounded, deterministic set per display size, so re-creating a display reuses its identity
  and adds nothing to the registry. An identity macOS restores into an unusable state is rejected
  and retired for good.
- **Cleanup for what earlier versions left.** `spaceo doctor` reports leftover SpaceO display
  identities. `spaceo safety clean-display-identities --operator` lists them, and
  `sudo spaceo safety clean-display-identities --apply --operator` backs up and removes only
  SpaceO's ColorSync registrations and profiles. Quit SpaceO, the Viewer and MCP clients first,
  run it from Terminal on the Mac itself, and log out and back in afterwards. See
  [display identity residue](DISPLAY_SAFETY.md#display-identity-residue).
- **The testing-host override keeps the ColorSync gate.** Live tests under
  `SPACEO_LIVE_TESTS=1 SPACEO_TESTING_HOST=1` no longer waive measured ColorSync load: display
  changes wait for ColorSync below 25%, measured after the previous change.
- A display whose mode settings macOS refuses is now kept and rejected instead of being released
  implicitly.

## Validation and limits

The release source passed the deterministic suite (1,925 Swift tests), the optimized
warnings-as-errors build, the MCP smoke check and hosted CI. The cleanup itself was verified
against a simulated ColorSync and then applied on the development Mac (Apple Silicon, macOS 27.2):

- It removed 525 SpaceO registrations and 763 SpaceO profiles. No registration remained, the four
  physical and Sidecar profiles were untouched, and the registry shrank from 1.2 MB to 5 KB.
- Before cleanup ColorSync served about two display requests a second at about 95 ms of CPU
  each (19% of a core). Right after it, the requests stopped and both ColorSync processes
  stayed at 0% CPU, without logging out.
- Two live session lifecycles on the release source, under the testing-host override, passed.
  The second display reused the first one's identity without writing the ColorSync registry.
  Each produced three ColorSync requests (attach, session, removal) and left no polling behind.

This is an owner-directed maintenance release with a qualification exception. After the fix
merged, the owner instructed: "do everything which is needed" and "do not log out though". The
development Mac recorded a WindowServer watchdog report earlier in its current boot, so normal
admission correctly refuses display creation until it restarts. The live checks therefore used
the testing-host override, which still enforces the ColorSync gate. A normal-admission live run,
the full live suite, the computer-use matrix and signed-artifact behavior qualification remain
missing, and RA-057 stays open until a normal-admission run is retained.

Supported scope remains native applications and managed Chromium, with Viewer on a physical
display. Managed Electron is refused before launch.
[Issue #38](https://github.com/ParthJadhav/SpaceO/issues/38) remains open for
empty/inactive-display qualification. Runtime health refusal, creation budgets and owner
retention remain enforced. Version 1.0.8 remains available for rollback.
