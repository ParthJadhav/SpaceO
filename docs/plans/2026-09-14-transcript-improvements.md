# Transcript review implementation plan

Source: internal integration review, 14 September 2026.
Private transcript paths and external product names are omitted from this public summary.

The review is historical evidence, not a reproduction. Implement the SpaceO contract and
deterministic regressions here; retain explicit unknowns for platform evidence and document
the application/controller integration responsibilities. Do not modify external controller or run live
display/input tests on the active desktop.

| Finding | Implementation and acceptance |
|---|---|
| S01 | Expose required isolation dimensions; refuse unknown strict requirements before effects; report and pause on breaches. Adopt and repark must report isolation as well as placement. Never blindly restore a previous foreground app after launch. |
| S02 | Share preserve/fit/cover placement across launch, adoption, watcher and repark. Preserve ordinary window size by default and remove inset for display-sized panels. Report requested/observed frames and overflow accurately. |
| S03 | Add daemon/session/display geometry receipts and reject stale coordinate generations. Explain that application capture source and physical pointer are independent of window destination. |
| S04 | Add structured permission mismatch/readiness and precise permission, exited-process and pending-window errors. Recovery must account for all sessions. |
| S05 | Report presentation as unverified with null FPS and capture freshness separately; provide bounded, synthetic probe reporting without treating missing callbacks as drops. |
| S06 | Expose unknown visibility rather than equating captured pixels with usability; document pause/unlock/refresh transitions and external lock integration. |
| S07 | Allow explicit no-initial-window launch/adoption with exact process ownership and existing late-window watchers; bounded waits and argument forwarding. No bundle-ID-wide automatic adoption. |
| S08 | Offline help at every command depth, versioned command schema, structured CLI failures with recovery/help hints. |
| S09 | Return and optionally require AX snapshot IDs; maintain stale refusal, geometry receipts, lifecycle/readiness reasons and explicit action evidence. |
| S10 | Bounded stop-completion and ready waits, tied to daemon identity; never describe acknowledgement as completed shutdown. |
| S11 | Reuse existing controller lease cache, pause/resume and scoped destroy; document renewal and handoff semantics, expose session generation and teardown state. |
| S12 | Preserve operation success while adding readiness/verification assertions; empty sessions and unknown isolation cannot satisfy requested requirements. |
| S13 | Add in-memory capture to daemon/MCP, retain explicit exports and provenance, no desktop pixels in support diagnostics. |
| S14 | Enforce practical default budgets and configured limits with checked allocation arithmetic; describe deliberate unrestricted override accurately. |

Implementation order: (1) placement and offline discovery, (2) response/readiness/identity
contracts, (3) lifecycle/input/capture integration, (4) regressions and controller/probe
documentation, (5) `git diff --check` and `make verify-release` plus applicable workflow checks.

Live qualification remains separate: synthetic physical/virtual marker fixtures, 1x/2x panel
placement, foreground sentinel, permission grant/revocation, external lock controller transitions, Metal callbacks,
controller reconnect and stop/display-removal tests. Skipped live cases are not passing evidence.

## Implementation ledger

| Finding | Result in this checkout | Remaining live/integration evidence |
|---|---|---|
| S01 | Known-breach preflight and automatic pause; strict/named observed-dimension assertions; current failures retained even when adoption leaves the foreground PID unchanged; no blind launch focus restoration. | Physical sentinel and each external/SpaceO/CUA route on a qualified host. |
| S02 | Shared preserve geometry and exact full-display origin; explicit fit/cover; requested/observed/edge receipts; identical watcher refusals do not trigger endless retries. | Retina, sheets, fixed panels and app-specific frame constraints. |
| S03 | Stable runtime display/session identity, topology/scale and window receipts; stale geometry refusal; independent-window versus display-region capture sources. | external controller must select and attest its internal capture source; synthetic physical/virtual marker comparison. |
| S04 | Permission preflight on adoption, structured process/window failures, client/daemon mismatch and explicit interactive doctor readiness. | Manual grant/revocation and coordinated restart on the target macOS build. |
| S05 | Compilable bounded Metal fixture and tested evidence classifier; no invented FPS/drops from absent callbacks. | Run physical/virtual and visible/occluded cases; captured freshness stays unknown without separate evidence. |
| S06 | Readiness/capture visibility explicitly unknown; controller pause/resume and documented lock transitions. | No reliable external lock controller state API is established; manual unlock and fresh synthetic observation remain required. |
| S07 | Running-without-windows launch/adopt, bounded PID-scoped window waits, launch arguments, existing exact-process late-window watchers. | Signed app lifecycle test. Use canonical SpaceO launch; automatic bundle-wide adoption is intentionally unsupported. |
| S08 | Offline help at all depths, versioned command schema and structured CLI errors; smoke coverage checks every advertised command. | None for offline discovery. |
| S09 | Fresh snapshot UUIDs, optional snapshot/geometry binding, fresh exact-label selection with ambiguity refusal, target/route/completion receipts. | Controlled toolbar/window replacement scenarios; unknown disappearance causes stay unknown. |
| S10 | CLI waits for the identified stopping process; bounded daemon-ready polling; stopping/unavailable errors remain distinct. | Live display-removal qualification and permission-bearing restart. |
| S11 | MCP automatic renewal, stale-reply fencing, pause/resume and scoped keep-apps release; runtime generations and lifecycle reasons. | Controller must persist the user's latest display choice across compactions; reconnect/monitor-detach live matrix. |
| S12 | Separate command, readiness and verification-assertion results; empty windows and inferred/unknown required dimensions cannot satisfy assertions. | Platform coverage is not upgraded by deterministic tests. |
| S13 | MCP memory PNG delivery and explicit CLI memory route, bounded bytes, provenance and no routine pixel bundle. | Use explicit synthetic fixture-window exports when retaining evidence; existing user files are preserved. |
| S14 | Practical default counts, area/byte/edge/tile budgets; locked admission and failed-attempt rate limiting; explicit unrestricted override. | Eligible-host resource stress/partial-creation testing remains live qualification. |

Section 4's controller/harness recommendations are documented in `docs/TRANSCRIPT_WORKFLOWS.md`:
discovery, one input route per experiment, timed hold/postcondition evidence, latest-user-mode state,
separate source/render/presentation assertions, bounded probes, causal timelines, run-local evidence
claims and respecting excluded pixel-parity work. SpaceO cannot rewrite another application's
capture policy or an external agent's task memory; those boundaries are explicit.

Validation results are recorded after the final checks below. A skipped or unexecuted live test
is never counted as a passing qualification result.

## Final validation — 14 September 2026

- `make verify-release`: passed; 611 deterministic Swift tests, 11 JavaScript tests and the
  MCP smoke test covering 23 tools plus offline help/schema/error behavior.
- Final verification used a `SWIFT` wrapper that adds `-Xswiftc -warnings-as-errors` to `swift build`
  only. The optimized production build passed; tests retained the repository's normal flags.
- `bash Tests/ReleaseSecurityTests.sh`: passed.
- `bash Tests/LiveTestGateTests.sh`: passed.
- Viewer bundle rebuilt with explicit ad-hoc signing; `codesign --verify --deep --strict --verbose=2
  ".build/SpaceO Viewer.app"` passed for the bundle and embedded helper.
- `TranscriptProbe.swift` compiled for arm64/macOS 14 with warnings as errors. It was not executed.
- `git diff --check`: passed.

Existing uncommitted work was preserved. No source install, host setup, live input/display
qualification, tag, publication or release-owner GO was performed. The live/integration evidence
column remains open and must not be represented as established by these deterministic checks.
