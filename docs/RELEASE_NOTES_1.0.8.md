# SpaceO 1.0.8

This update keeps agents from disturbing your desktop when an agent app takes focus. It also
fixes stale-window failures and makes recovery from a busy host less disruptive.

- **Focus stays with you.** When an agent app activates itself, for example Chrome showing a
  page's popup window, SpaceO hands activation straight back to the app you were using, usually
  within tens of milliseconds. It uses public activation only, and counts a return only when the
  menu bar, front process and active Space have observably left the agent. Agents see a warning
  in their receipt or an `isolation.activation_restored` event. Anything SpaceO cannot return
  is still reported as a breach and pauses the session
  ([#53](https://github.com/ParthJadhav/SpaceO/issues/53)).
- **No more session-wide "known window owner is unavailable".** The owner of an ordered-out
  window (such as a closing sign-in popup) is now resolved, and `session.list` keeps working when
  one session's window discovery is incomplete: that row keeps its last-known windows and says
  so ([#47](https://github.com/ParthJadhav/SpaceO/issues/47)).
- **A slow display read no longer latches the safety circuit.** A geometry or Space query that
  outlives its one-second deadline keeps the last verified snapshot. A display change that
  cannot run still opens the circuit at its own deadline
  ([#54](https://github.com/ParthJadhav/SpaceO/issues/54)).
- Host-health and janitor fixes from contributors: an expiry reader can no longer mistake a
  concurrent fresh observation for clock reversal (#49), and the timed janitor stops retrying a
  sticky health refusal every three seconds (#48).
- Report-driven reliability fixes (#46): structured lease guidance, bounded report inputs,
  exclusive recovery of idle pressure/swap latches, explicit diagnostic testing-host overrides,
  identity-checked screenshot targets, and more robust launch readiness and snapshot lookup.
- `doctor` reports a running LaunchAgent correctly, and MCP no longer warns about a daemon
  version that has already been replaced.

## Validation and limits

Every fix passed the deterministic suite (1,880 Swift tests on the final activation-guard
source), the optimized warnings-as-errors build, the 35-tool MCP smoke check and hosted CI. Live
reproductions confirmed each issue fix on an Apple Silicon Mac running macOS 27.2. In repeated
runs, focus returned to the person's app in 10–500 ms, including apps without Accessibility
focus such as Electron apps. The full computer-use matrix passed 42/42 steps on the
activation-guard branch shortly before its final refinements. These live runs used the
explicit testing-host override.

This is an owner-directed maintenance release with a qualification exception. On October 15,
2026 the owner instructed: "Fix the issues which came up as well and release the new version.
Do everything autonomously". The full live suite stopped after 4 of 15 passing cases: a
1-second live-harness display read timed out while ColorSync ran at about 100% CPU, and the
safety supervisor suspended the run as designed, leaving no SpaceO display behind. That
sustained ColorSync load is the open RA-057 symptom. A complete live suite, the matrix on the
exact release source and signed-artifact behavior qualification remain missing.

Supported scope remains native applications and managed Chromium, with Viewer on a physical
display. Managed Electron is refused before launch. The WindowServer/ColorSync freeze (RA-057)
remains unresolved, and [issue #38](https://github.com/ParthJadhav/SpaceO/issues/38) remains
open for empty/inactive-display qualification. Runtime health refusal, creation budgets and owner
retention remain enforced. Version 1.0.7 remains available for rollback.
