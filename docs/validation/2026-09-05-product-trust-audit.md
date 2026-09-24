# Product trust audit — 2026-09-05

**Status: deterministic checks, all 16 live XCTest tests, and the clean 36-check signed MCP
matrix pass on this development host. Release artifact qualification remains incomplete.**

Base commit: `e95b5a02be0dd5f016b1d684fe16161a74e66140`. The fixes described here are working-tree
changes after that commit. This is a product and implementation review, not an independent
qualification of a signed release or a claim that every possible defect has been eliminated.

## Product decision

Keep SpaceO positioned as a development preview for trusted agents on a Mac the operator controls.
The useful promise is background app operation with observable outcomes and explicit limitations.
Private API availability, a green build, or an empty-session screenshot cannot establish that
arbitrary apps will accept input or preserve the user's attention on every macOS build.

The next milestone is a reproducible first session, successful native/Chromium/Electron workflows,
recoverable failures, and verified cleanup on a qualified host. More features should follow that
milestone. Retain the attention-versus-security distinction and existing release approval policy.

| Product layer | Assessment | Evidence or decision |
|---|---|---|
| Observed user behavior | Assumed | The repository contains engineering regressions, not measured first-time-user setup studies. |
| Domain | Strong | App processes, displays, Spaces, tiles, capture, input, and TCC are distinguished. |
| User needs | Partial | The main job is clear: let an agent work without taking over the desktop. Setup success and acceptable app coverage still need user validation. |
| Strategy | Partial | Preview support fits the evidence. Broad public reliability claims would exceed it. |
| Conceptual model | Strong with limits | Sessions own leases and tiles; launched/adopted apps have different cleanup rules. All participants still share one macOS user's privileges. |
| Interaction flow | Improved, partially verified | Fixed broken setup and Viewer transitions. Real permission, takeover, recovery, and upgrade flows remain to be exercised. |
| Surface | Improved, partially verified | Quick start now includes PATH and a read-only check. Documentation distinguishes prerequisites, session self-test, and qualification; visual/VoiceOver checks remain. |

The product research gap is the lowest unverified layer. It does not prevent fixing demonstrated
implementation bugs, but it prevents calling setup “top notch” based solely on unit tests.

## Findings fixed

| Ticket | Failure | Result and evidence |
|---|---|---|
| SPAO-180 | Setup omitted the daemon's required controller identity and ignored destroy failures. | Unique owned test session, lease propagation, validated PNG, private temporary storage, checked cleanup, actionable failure/unknown outcomes. `SetupTests` exercises the request sequence and failure branches without a display. |
| SPAO-181 | Caller permissions could mask daemon problems; unknown daemon health/provenance could pass doctor; configuration paths were interpolated unescaped. | Setup checks the serving daemon, doctor fails unknown running-daemon state, and shell/JSON/TOML paths round-trip through regression tests. |
| SPAO-182 | An invalidated display retained after failed retirement was allocated again; reports read mutable occupancy outside its lock. | Reproduced invalid reuse with a stuck-display fake; new allocation skips it and keeps the failure visible. Occupancy is copied under the lock. |
| SPAO-183 | Per-display validation did not protect aggregate framebuffer arithmetic. | Representability checked before allocation; exact-boundary and overflow regressions pass. This adds no product-policy resource cap. |
| SPAO-184 | Blocked Viewer admission fell through into enablement; delayed pause replies could outlive grants or race a later takeover; failed takeover hid resume rollback failures. | Reproduced blocked enablement and suppressed rollback errors. Admission returns on refusal, delayed completion rechecks state, and a new takeover waits for earlier human pause/resume work. Failed rollback identifies affected sessions and gives recovery guidance. |
| SPAO-185 | Overlapping Viewer polls could rewind state and drop a freshly created session lease. | One active poll plus one coalesced follow-up; older responses cannot overwrite completed mutations. Delayed-transport tests prove lease retention. |
| SPAO-186 | The matrix could accept JSON-RPC errors, missing screenshot pairs, or partial isolation; early child exit could hang; fixed fixture paths collided. | Evidence helpers and app-free subprocess tests reject false passes; bounded shutdown, private unique fixtures, and stable report labels. |
| SPAO-187 | A prolonged transport failure was treated as proof the daemon exited, silently dropping Viewer-owned agent pauses. | Reproduced the missing resume request. Disconnect attempts resume for pauses placed by the Viewer, reports failures with affected sessions, and never claims a failed resume succeeded. Live outage/reconnect qualification remains pending. |
| SPAO-188 | Repeated local CLI builds used a hash-based ad-hoc identity, undermining continuity of direct privacy grants. | `make signed` produces stable-path Developer ID CLI and Viewer artifacts, rejects ad-hoc fallback and CLI identity drift. Real signing and repeat-signature checks pass. Signing alone has not removed this host's Accessibility denial. |

Documentation also no longer promises that element clicks cannot miss, that Viewer Control solves
all synthetic-input limitations, or that error logs are automatically safe to share. Teardown
errors can contain window titles and paths even though direct request payloads are omitted.

## Verification

The baseline passed 570 safe Swift tests and the 19-tool MCP smoke despite the setup and Viewer
admission defects. The new regressions demonstrate why those passes alone were insufficient.

Source checks passed on this working tree (counts updated after the Viewer follow-up below):

- `git diff --check`;
- `make verify-release`: optimized build, **597 safe Swift tests**, Viewer install-transaction
  shell tests, **7 app-free matrix tests**, and the **19-tool MCP smoke**;
- `swift build -c release -Xswiftc -warnings-as-errors`;
- `SPACEO_CODESIGN_IDENTITY=- make viewer` and strict nested `codesign` verification;
- `bash Tests/ReleaseSecurityTests.sh` and `bash Tests/LiveTestGateTests.sh`;
- `make release-check` and `make release-dry-run` (the dry run reports absent local Developer ID
  and notarization inputs, as expected).

The initial read-only doctor check confirmed unchanged user display inventory, zero SpaceO/orphaned
displays, and the same pre-existing daemon instance. No live app input occurred. The ad-hoc Viewer
signature proves local bundle integrity only, not public distribution trust.

The strict live attempt ran on the user-authorized Mac and was **rejected**: all 16 integration
tests skipped because Accessibility was unavailable. Zero live tests executed. The XCTest suite's
“passed” label is not evidence; `make test-live-full` correctly returned failure through its skip
gate. At that initial checkpoint the full matrix and interactive Viewer checks had not run; the
follow-ups below supersede that status.

Host preflight:

- macOS 27.0 build 26A5406e, arm64;
- Xcode 26.6 / Swift 6.3.3, different from the release pin of Xcode 26.0.1 / Swift 6.2;
- one online, active, unmirrored user display; zero initial SpaceO/orphaned displays;
- Screen Recording available, Accessibility unavailable for the caller and existing daemon;
- the existing daemon does not match the source-built CLI; it was not stopped or replaced.

The updated `setup --no-prompt --no-self-test --json` successfully emits machine-readable failure
rows for caller Accessibility, daemon input, and daemon build, plus an explicit skipped self-test.
It does not create a test display or change host configuration.

## Review coverage and limits

Reviewed the start-to-finish journey against README/setup/install/update/recovery/support/release
policies, the existing audit/backlog, and representative implementation paths in CLI setup/doctor,
daemon transport and dispatch, session ownership/persistence/reclamation, display allocation and
retirement, capture exclusion, AX references and placement, native/Chromium/Electron delivery,
Viewer polling/control, diagnostics, and test/release automation. All safe test suites run as a
whole; targeted failure scenarios cover the changes above.

This is not an exhaustive line-by-line security audit. Passing deterministic tests does not prove
private macOS ABI compatibility, rendering isolation, real input delivery, crash cleanup,
Gatekeeper/notarization, or first-time-user usability. Historical live records do not qualify this
working tree. GitHub runner availability, environment protection, and final-commit CI were not
rechecked in this pass; the handoff's external-state table is dated evidence, not current proof.

## Follow-up: permissions and live results through cmux

The user enabled the signed CLI and Viewer in Settings. The signed CLI still reports
Accessibility denied when launched by this task's existing T3 Code process, but the identical
binary reports both input and capture prerequisites available from cmux. This isolates a launcher
attribution difference; it is not evidence that the user failed to grant access. No further
permission toggles or global privacy resets are warranted on the evidence available.

Through cmux, the single display lifecycle test passed, followed by `make test-live-full`:
**16 tests executed, zero failures, zero skips**, in 198.392 seconds. The strict skip gate returned
zero. This covers native/Chromium workflows, rendering, shared displays, late-window containment,
and per-test display cleanup. [Retained test outcomes](2026-09-05-live-cmux-results.json).

The full MCP matrix then used `.build/signed/spaceo` and a unique socket with a newly started,
matching, permission-ready daemon. It returned **exit 1: 32 passed, 3 failed, 1 blocked, 0 skipped**
across 48 tool calls. [Retained action report](2026-09-05-signed-matrix-actions.json).

- Native and web action checks passed.
- Electron published zero windows and a one-line Accessibility outline, so containment and tree
  readability failed. Screenshot rendering passed. Renderer scroll remained blocked (SPAO-179).
- The audit pool reached zero sessions/displays, but the global topology check failed: user
  online IDs changed from `[1, 2]` to `[196, 197]`, retaining a mirrored pair, and display `198`
  appeared as an orphaned SpaceO display. It persisted in a subsequent read-only doctor check.
- The audit daemon stopped successfully. The pre-existing daemon was preserved and reported an
  empty pool. The user subsequently confirmed logging out/switching users during this run. This
  invalidates the run for app reliability qualification. After the original login became active
  again, user displays returned to `[1, 2]` and no SpaceO/orphaned display remained. No display
  recovery or unrelated daemon shutdown was performed. A fresh matrix run followed.

The uninterrupted rerun used another unique socket and the same signed CLI, returning
**exit 0: 36 passed, 0 failed, 0 blocked, 0 skipped**, across 47 tool calls. Electron containment,
AX readability, rendered capture, pointer scroll, and covered isolation checks all passed.
User online IDs remained `[1, 2]`, active `[2]`, mirrored `[1, 2]`; no SpaceO or orphaned displays
remained. The isolated daemon stopped successfully. This resolves SPAO-189 as an interrupted-run
qualification problem, not a demonstrated SpaceO defect.
[Retained clean action report](2026-09-05-signed-matrix-clean-actions.json).

Raw logs remain private under `/tmp/spaceo-cmux-live-full*` and
`/tmp/spaceo-matrix-2u6f2d5c/` (interrupted) and `/tmp/spaceo-matrix-kxaolb4z/` (clean); they are not committed. The structured records omit screenshots,
Accessibility content, controller leases, and raw tool responses. Earlier permission-blocked
attempts above remain historical evidence and are superseded by these results.

## Remaining acceptance work

1. **Finish Viewer interaction qualification.** The post-unlock native typing check now passes;
   retained evidence confirms human/agent arbitration and the named type event. SPAO-191 tracks
   unconfirmed native command-shortcut behavior. Detached-daemon recovery-row actions and the
   full activity/interaction flow still need final-candidate qualification.
2. **Qualify the exact distribution.** The local CLI and Viewer are Developer ID signed, but
   a validated notarization credential path, the pinned Xcode 26.0.1 / Swift 6.2 environment, final-commit
   CI, protected publication approval, the immutable candidate, distribution-path verification,
   and installation/uninstall evidence are still required. No release tag or publication was
   performed. The authorized existing login may perform qualification; no separate tester is required.
3. **Disposition intermittent historical observations.** BUG-9 did not recur in the clean full
   suite, expanded matrix, or native fixture launch. This does not establish its historical root
   cause. The audit reproduced external tool-driven Viewer relaunch after querying a quit app,
   but cannot retroactively attribute BUG-10's older process replacements without a matching trace.

The dedicated capture-isolation proof, safe route-proxy verification, expanded matrix, setup
walkthrough with existing grants, and Viewer control/recovery checks are now recorded below.
They do not establish zero possible bugs or qualify a future distribution automatically.

## Owner qualification-policy change — 2026-09-05

The owner explicitly requested all remaining qualification in this login and removed the
separate-tester/clean-login restriction. `RELEASE_POLICY.md` and the handoff now permit implementer
qualification here with retained pre/post-state evidence. Historical references above to an
independent tester or three-person fresh-user study describe the previous plan, not current gates.
The remaining setup work is a documented first-run walkthrough and failure-path verification; it
will not be represented as observed research with fresh human users. Exact-artifact signing,
notarization, Gatekeeper, installation/uninstall, isolation, cleanup, and publication approval
requirements still apply.

## Interactive Viewer follow-up — 2026-09-05

The Developer ID-signed Viewer was exercised on an isolated audit socket. Verified offline
Start Daemon, daemon permission/provenance health, creation, live stream, Human Control pause,
Control–Command–Escape release/resume, confirmed destruction, and daemon cleanup. Quitting during
Control reaped a Viewer-owned session; a separate quit with an externally owned session preserved
that session and confirmed `inputPaused: false` afterward. No default daemon was replaced.

The test exposed SPAO-190: Resume Agent could unpause a session while Human Control remained
enabled. The model now refuses that transition and the toolbar disables it until Control is
released and pending handoffs finish. The targeted regression and rebuilt live UI pass.
The new central New Session action appears in the accessibility tree; Command–Shift–N creates a
session. This is accessibility-tree and keyboard verification, not an auditory VoiceOver study.

After these changes, `make verify-release` passed 596 Swift tests, seven harness tests, the Viewer
install transaction tests, and the 19-tool MCP smoke. Release security tests, live skip-gate tests,
the strict optimized build, and nested Developer ID Viewer signature verification also passed.

## Rendered capture and setup follow-up — 2026-09-05

SPAO-148 now has a live pixel-level proof: an 1800-point fixture window crossed from its
1280-point tile into its neighbor. The unfiltered positive control contained 743,606 magenta
pixels; the public CLI's protected neighboring screenshot contained zero. The source session
returned a failed health audit naming the drift. The fixture exited, the audit daemon stopped,
and no SpaceO/orphaned displays remained; the single physical display was unchanged. Retained
[structured evidence](2026-09-05-capture-isolation.json) includes image digests; raw PNGs remain
private. The tested binary and fixture sources are identified in the record and reproduction
instructions are in `Tests/LiveFixtures/README.md`.

The same live report confirms SPAO-163's safe public Accessibility proxy: key/text-route checks
are explicitly `inferred`, with evidence that does not claim a specific key window or text field.

Guided `setup --no-prompt --json` then passed all eight checks in 1.341 seconds on a new isolated
socket with existing TCC grants. It started a matching daemon, created and captured its unique
self-test session, and confirmed session destruction. No session remained; stopping the audit
daemon returned the same physical/SpaceO display inventory. This does not time installation or
the user's first permission grants. Denial, stale-daemon, malformed capture, and failed teardown
paths remain covered by deterministic tests and the earlier real denied-launcher check.

## Final Viewer recovery and verification follow-up

[Viewer recovery evidence](2026-09-05-viewer-recovery.json) records a 35-second suspension of only
the audit daemon: Control was released, the stream reconnected, the external session remained,
and daemon state confirmed input resumed. A forced Viewer exit preserved the paused external
session; after relaunch the operator's Resume Agent action unpaused it. Normal menu release and
physical-display view-only admission also pass. A direct relaunch through the task host correctly
showed missing Accessibility and disabled Control; permission attribution still depends on the
launcher, even with stable signed binaries. No new permission grant was requested during these recovery checks.

The attempted Viewer-native typing action was blocked by external lock controller's lock overlay; the document
remained unchanged. This is retained as blocked, not passed. Both audit Viewer processes exited,
the fixture and isolated daemon were stopped, and display inventory returned to baseline.

SPAO-159 is fixed: the native menu advertises the locally reserved release chord during Control.
The canvas also hides its Capture Input invitation whenever the toolbar's prerequisites fail.

The checked-in capture runner was rebuilt and repeated from a fresh private directory. It again
returned 743,606 positive-control pixels and zero protected pixels, with explicit source health
failure and clean teardown. The [repeat record](2026-09-05-capture-isolation-repeat.json) includes
fixture source hashes and image digests. [Guided setup evidence](2026-09-05-guided-setup.json)
records all eight passes and cleanup.

After the final Viewer edits, `make verify-release` again passed all 596 Swift tests, seven harness
tests, install transaction checks, and the 19-tool MCP smoke. Release security/skip-gate scripts,
the warnings-as-errors optimized build, strict nested signed-Viewer verification, and diff whitespace
checks pass. The exact release candidate remains unqualified and publication remains NO-GO.

Final concurrency review also found that a manual Resume already in flight could race a new
Human Control request. SPAO-190 now serializes both directions: pending manual pause/resume
blocks takeover and another manual change, and transition counters publish UI updates
immediately. The delayed-transport regression passes. The earlier live results predate this
additional race fix; its evidence is deterministic and the rebuilt signed bundle must be used
for remaining interaction qualification.

The final suite after that concurrency fix passes **597 deterministic Swift tests**, seven harness
tests, Viewer install checks, and the 19-tool MCP smoke. The optimized warnings-as-errors build,
release security tests, live skip-gate tests, and rebuilt Developer ID Viewer signature also pass.
Only the pre-existing installed SpaceO processes remain; all audit Viewer, marker, native fixture,
and isolated daemon processes have exited. No install, tag, or publication was performed.

## Notarization credential discovery

A metadata-only search of this login's Keychain, the data-protection Keychain, environment, and
shell profile configuration found no existing local notarytool profile. No password or private-key
data was requested or exposed. A local profile name should therefore not be requested from the owner.

GitHub's `release` environment already contains `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`,
and `NOTARY_API_ISSUER_ID`. The existing release workflow passes those API-key credentials
directly to `scripts/release.sh candidate`; it does not use `SPACEO_NOTARY_PROFILE`. Secret-name
presence is confirmed, but credential validity has not been tested against Apple. GitHub does not
return stored secret values for local reuse; use the existing credentialed workflow when its
candidate and publication gates are ready. No release workflow, tag, or publication was triggered
by this discovery. A local notarization run would still require locally provisioned credentials.

## external lock controller unlocked — native input follow-up

The owner unlocked external lock controller normally. A fresh isolated daemon and the final signed Viewer launched
TextEdit with a private synthetic document. Two text markers entered through the Viewer appeared
in the application's Accessibility data. Escape returned the Viewer to view-only mode and
resumed the session. A lease-authenticated type request was explicitly refused while Human
Control was active, then accepted and verified in AX after release. The Viewer Events panel
showed the named `type` action. [Structured result](2026-09-05-viewer-unlocked-input.json).

This closes the external lock controller blocker for native typing. It does not close SPAO-191: Command–A did not
produce full-document replacement, and Command–S persistence was not reliably confirmed.
The first marker appeared on disk, but subsequent markers were only verified in AX, so a Save
success is not inferred from attempted delivery. The initial batch interrupted by user activity
was excluded; subsequent checks used freshly observed Viewer state. The fixture, Viewer, and
audit daemon were closed, with display inventory restored to the run's baseline.
