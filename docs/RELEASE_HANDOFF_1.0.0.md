# SpaceO 1.0.0 release handoff

Prepared: 2026-08-29  
Last updated: 2026-09-16
Repository: `ParthJadhav/SpaceO`  
Version: `1.0.0`  
Last verified implementation head: `f30d22b0f9f5c754ab262dc13dab518cc7a4d00b`
Last verified implementation tree: `45fe6b8935afdf002bbe9a458dd458e0af5532eb`

## Status: NO-GO

The source release is assembled and its deterministic gates pass, but it is not ready to publish.
Do **not** push `v1.0.0` yet. A tag push starts candidate signing and, with the repository's current
configuration, the publication job has no required-reviewer protection and could publish as soon
as the candidate job succeeds.

This document update is not part of the implementation head named above. Bind all remaining
evidence and the tag to the final commit after this update and any other release-preparation
changes are committed and pushed; do not tag `f30d22b` by assumption.

## Preparation refresh — 2026-09-15

The transcript improvements and preceding setup/Viewer fixes are being prepared together for the
first release, `1.0.0`; GitHub still has no release or version tag. The sections below retain the
historical handoff. Their old commit and test counts do not qualify the current source.

Current preparation and remaining gates are recorded in
[the September 15 preparation record](validation/2026-09-15-release-preparation.md).
The consolidated [changelog](../CHANGELOG.md) and [release notes](RELEASE_NOTES_1.0.0.md)
remain planned until publication is approved. Neither version source needs a bump.

Publication protection remains blocked: adding the repository owner as a required environment
reviewer returned HTTP 422 because the repository billing plan does not support the rule.
Do not push a release tag while publication is unprotected. An owner decision about the GitHub
plan or an equivalently protected mechanism is required; this preparation does not change billing
or repository visibility.

## What is complete

September 16 follow-up: owner-authorized live testing remains **NO-GO**. The full live suite
failed Chromium launch isolation (15/16 tests passed, zero skips). The complete matrix attempted
all three suites and recorded 15 passes and 4 failures; Chrome and Cursor launch failures left
their later actions unexercised. Test daemon shutdown and display cleanup passed, but an unrelated
default-socket daemon appeared during testing and was preserved. SPAO-192/193 track the remaining
launch defects. See [the diagnostic record](validation/2026-09-16-live-qualification.json);
it does not qualify the changed source or a signed artifact.

Commit `f30d22b` contains the current source, tests, Viewer branding, packaging changes, CI bundle
smoke test, documentation, and the planned `1.0.0` changelog section. Before this handoff update,
local and remote `main` both resolved to that commit and the worktree was clean.

On 2026-09-03 the exact committed tree passed locally:

- `git diff --check`;
- `bash Tests/ReleaseSecurityTests.sh` and `bash Tests/LiveTestGateTests.sh`;
- `make verify-release`: optimized build, 570 safe tests with zero failures, and the 19-tool MCP
  protocol/validation/mutation-safety smoke test;
- `swift build -c release -Xswiftc -warnings-as-errors`;
- an ad-hoc-signed Viewer bundle build, resource checks, and strict nested `codesign` verification;
- `make release-check`; and
- `make release-dry-run`.

The dry run correctly reported that local Developer ID and notarization inputs were absent. The
ad-hoc Viewer result proves bundle structure, not distribution trust. All six expected secret
names remain configured in the GitHub `release` environment; their values were not inspected.

Detailed exploratory evidence and the open host failures are in
`docs/validation/2026-08-29-claude-full-feature-regression.md`. That audit is deliberately marked
as **not** being a release qualification.

## Source blocker work included in the verified implementation head

The current source head resolves the repository-local implementation portions of SPAO-143,
SPAO-145, and SPAO-150, and moves SPAO-155, SPAO-158, SPAO-163, and SPAO-168 to live verification:

- Command-C, Command-X, and Command-V are refused consistently before native or Chromium
  delivery, so the user's shared pasteboard cannot be read or overwritten implicitly.
- Chromium target listing and attachment are public CLI/MCP operations; every web action verifies
  its exact binding, and a missing bridge fails closed.
- Named session teardown fences and persists its session under the command gate, then releases the
  gate before process-exit waits. Direct teardown and janitor reclamation use the same path.
- The Viewer can create and heartbeat sessions, confirm single-session destruction, retry/reclaim
  recovery rows, show recent agent actions, and pause/resume agent input. Human Control pauses the
  affected sessions before local input is enabled.
- Isolation capture uses the public Accessibility focused-application attribute as explicitly
  inferred key/text-route evidence, retaining `unknown`/`partial` when unavailable.
- The MCP surface has 19 tools, including target listing/attachment. The computer-use fixture now
  covers sliders, modifier-extended multi-select, and right-click context actions, reports a parity
  percentage, and publishes its JSON report from the live workflow.

These deterministic results do not replace the required live, signed-candidate, artifact-qualification, or
GitHub-hosted evidence below. The final source-gate results and commit ID must be refreshed again
after this handoff update and any release-note edits are committed.

## Current external state

This state was rechecked read-only on GitHub on 2026-09-03 and must be rechecked before acting:

| Item | Observed state | Required state |
|---|---|---|
| Remote `main` | `f30d22b0f9f5c754ab262dc13dab518cc7a4d00b` | Contains the final release commit after release-preparation edits |
| Local `main` | `f30d22b0f9f5c754ab262dc13dab518cc7a4d00b` before this handoff edit | Clean and pushed after release-preparation edits |
| Tags/releases | None | Immutable `v1.0.0` only after pre-tag gates pass |
| Latest CI | Run `33369358313`, attempt 2, passed all jobs on `f30d22b` after the Actions budget was restored | Green CI on the final commit |
| `release` secrets | All six expected secret names exist | Reconfirm without exposing values |
| `release` protection | No protection rules | Owner decision; credentials are otherwise usable immediately |
| `release-publication` protection | **No protection rules** | Required authorized publication reviewer(s) configured |
| Self-hosted runners | 1 (`spaceo-mac`, registered 2026-09-18; no TCC grants yet) | Runner process granted Accessibility and Screen Recording |
| Repository variables | `SPACEO_LIVE_RUNNER_LABELS` = `["self-hosted","macOS","ARM64","spaceo-mac"]` | Unchanged |

The original attempt for run `33369358313` had an empty step list because an Actions budget blocked
it. Attempt 2 passed in 2m30s after the budget was restored. Preserve its URL and result, then run
CI again for the final commit containing this handoff update and any release-note edits. The green
run emitted a non-blocking Node.js 20 deprecation annotation for the pinned checkout action.

## Remaining blockers before tagging

### 1. Resolve release-policy findings

`docs/RELEASE_POLICY.md` forbids approval while a critical/high display-safety, input-safety,
data-loss, security, signing, or distribution finding remains open. The backlog currently includes
the following P0/P1 qualification items:

- SPAO-115 — signed, notarized, versioned distribution (P0; completed only by this release);
- SPAO-148 — live rendered-pixel proof completed on 2026-09-05; bind candidate evidence to the final artifact;
- SPAO-155 — Viewer lifecycle/recovery controls need live interaction verification (P1);
- SPAO-158 — activity and pause/resume arbitration need live interaction verification (P1);
- SPAO-163 — granted-host proxy verification completed in the 2026-09-05 capture record; and
- SPAO-168 — expanded matrix passed 36/36 on 2026-09-05; final-candidate CI/runner evidence remains separate.

SPAO-148 described context leakage; the retained 2026-09-05 rendered-pixel proof closes its
implementation verification. It does not qualify a future artifact automatically. SPAO-143, SPAO-145, and
SPAO-150 have deterministic implementation evidence in the current working tree but are not
release evidence until that tree is committed and all final gates pass. For every other P1, the
release owner must either meet its acceptance criteria or record evidence
that its current priority or release relevance is wrong, update the backlog and public limitations,
and rerun the affected verification. Do not lower severity merely to pass the release gate.

The audit also leaves BUG-9 (intermittent Accessibility launch blackout) and BUG-10 (unexplained
Viewer process replacement) open. Resolve them or record a defensible release-owner no-go/deferral
decision grounded in new evidence. BUG-9 was not reproduced in the 2026-09-05 clean full live
suite, matrix, or TextEdit fixture launch; its intermittent historical cause remains unconfirmed.
The current audit reproduced a harness-driven Viewer relaunch when the UI tool queried a quit
app, but this does not prove the cause of the historical BUG-10 replacements.

`CHANGELOG.md` also has changes made after the provisional 2026-08-29 `1.0.0` section under
`[Unreleased]`, while no `1.0.0` release exists yet. Before tagging, either move those entries into
the final `1.0.0` notes and use the actual release date, or select a later version and update both
version sources. Leave a new empty `[Unreleased]` section after the release notes are closed.

### 2. Make the final commit green on GitHub

After all source and documentation changes are complete:

```bash
git status --short --branch
git rev-parse HEAD
git push origin main
gh run list --repo ParthJadhav/SpaceO --branch main --limit 5
```

The final commit must be contained in remote `main`, and its CI run must execute rather than fail at
job startup. Preserve the run URL in the qualification record.

On the final tree, repeat at least:

```bash
git diff --check
bash Tests/ReleaseSecurityTests.sh
bash Tests/LiveTestGateTests.sh
make verify-release
swift build -c release -Xswiftc -warnings-as-errors
SPACEO_CODESIGN_IDENTITY=- make viewer
codesign --verify --deep --strict --verbose=2 ".build/SpaceO Viewer.app"
make release-check
make release-dry-run
```

### 3. Provision and run the live qualification host

Since 2026-09-18 the runner `spaceo-mac` is registered and `SPACEO_LIVE_RUNNER_LABELS` points at
it; all workflows run there. What remains is the TCC provisioning of that host. Follow
`docs/LIVE_TESTS.md`:

1. Keep the runner on the pinned toolchain (`DEVELOPER_DIR` in the workflows: Xcode 27.0 / Swift 6.4).
2. Use an otherwise idle, persistent graphical login.
3. Grant Accessibility and Screen Recording to the runner process that actually launches tests,
   not merely to Terminal.
4. Give it a distinctive label such as `spaceo-live`.
5. Set `SPACEO_LIVE_RUNNER_LABELS`, for example:

   ```json
   ["self-hosted","macOS","ARM64","spaceo-mac"]
   ```

Before interpreting any run, require `spaceo doctor` to report `can drive sessions: yes`,
`can capture: yes`, and that the daemon image matches the CLI. Dispatch **Live WindowServer tests**
against the final commit. The run must execute every test with zero failures and zero skips; retain
the uploaded log and run URL.

An equivalent dedicated-login local run is:

```bash
swift run spaceo doctor
make test-live-full
make computer-use-check-full
```

The owner-authorized existing login may be used under the precautions in
[the live-test guide](LIVE_TESTS.md). The suite creates displays, launches applications, and
synthesizes input into that graphical login; preserve unrelated state and repeat interrupted runs.

### 4. Retain SPAO-148 rendered evidence

The deterministic `CaptureIsolationTests` and the
[2026-09-05 live pixel proof](validation/2026-09-05-capture-isolation.json) pass. Preserve the
following acceptance sequence when validating a candidate with changed capture/display behavior:

1. Put two sessions on one SpaceO display.
2. Give session A a visually unique oversized or unmovable window that overlaps session B's tile.
3. Capture session B's tile through the public CLI or MCP surface.
4. Prove session A's marked pixels are absent from B's image. A refusal caused by an unresolved
   overlapping window is also acceptable if it is explicit and fail-closed; a successful image
   containing the pixels is not.
5. Retain the source/window identities, tile geometry, screenshots, commands, result, and teardown
   evidence.
6. Confirm zero SpaceO displays, sessions, owned apps, and daemon remain and the physical display
   topology is unchanged.

Commit or immutably link the record, then mark SPAO-148 complete only if all acceptance criteria are
actually met.

### 5. Protect publication before creating the tag

In GitHub repository settings, configure one or more authorized required reviewers on the
`release-publication` environment. Prevent self-approval where the plan allows it. Recheck that the
publication job receives no signing/notarization secrets.

If the repository's visibility or GitHub plan does not permit required environment reviewers,
publication remains **NO-GO** until the repository is moved to a plan/configuration that does, or
an equivalently protected publication mechanism is implemented and the release policy is updated.

Read-only checks:

```bash
gh api repos/ParthJadhav/SpaceO/environments/release-publication
gh api repos/ParthJadhav/SpaceO/actions/runners
gh variable list --repo ParthJadhav/SpaceO
gh secret list --repo ParthJadhav/SpaceO --env release
```

Expected release secret names:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `DEVELOPER_ID_APPLICATION_IDENTITY`
- `NOTARY_API_KEY_P8_BASE64`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`

Do not print, download, rotate, or copy secret values as part of ordinary verification.

## Candidate and artifact qualification

Proceed only after every pre-tag blocker above is cleared. Record the actual final commit first:

```bash
git fetch origin main --tags
FINAL_COMMIT="$(git rev-parse HEAD)"
test "$(git rev-parse origin/main)" = "$FINAL_COMMIT"
test "$(tr -d '\r\n' < VERSION)" = "1.0.0"
git tag -a v1.0.0 "$FINAL_COMMIT" -m "SpaceO 1.0.0"
git show --no-patch --decorate v1.0.0
git push origin refs/tags/v1.0.0
```

The tag push starts the **Signed release candidate and publication** workflow. The candidate job
must sign with the SpaceO Developer ID Application identity (Team `75LRT8TRQY`), notarize and
staple the Viewer and DMG, verify the fresh-mounted distribution, sign the checksum and candidate
record, and upload one immutable candidate artifact. Do not approve the waiting publication job.

The qualifier must download that exact candidate through the intended path. Per the owner
direction recorded in `RELEASE_POLICY.md` on 2026-09-05, the implementer may test in the authorized
existing Apple Silicon login; a separate person or clean host is not required. Record and preserve
pre-existing state, and discard runs interrupted by logout or user/display changes. From a checkout of the exact tag, run:

```bash
make verify-release-candidate \
  CANDIDATE=/path/to/SpaceO-1.0.0-macOS-arm64.candidate.txt
make verify-distribution \
  ARTIFACT=/path/to/SpaceO-1.0.0-macOS-arm64.dmg
```

They must also exercise the installed artifact, not `.build` output:

- record commit, annotated tag object, workflow run/attempt, artifact ID and digests;
- record tester identity, date, hardware, macOS version/build, architecture, display topology, and
  TCC state;
- run `spaceo doctor` before mutation;
- create a session and verify native app placement, AX reading, direct input, capture, MCP use, and
  truthful isolation reporting;
- verify Viewer streaming, Control admission, and Control-Command-Escape;
- destroy the session, stop the daemon, and confirm no SpaceO display/app/process survives;
- confirm the user's display, pointer, keyboard, and focus behavior remain normal; and
- perform a clean uninstall, because `1.0.0` has no previous supported release to roll back to.

Any skip, unknown required safety result, unexplained diagnostic, user-display disturbance, wrong
publisher, moved tag, checksum mismatch, missing staple, Gatekeeper failure, or incomplete cleanup
is a **NO-GO**. Retain the qualification record under `docs/validation/` or link it immutably before
approval.

## Publication go/no-go

The release owner may approve the `release-publication` environment only when every item is true:

- [ ] the final commit is on remote `main` and CI is green;
- [ ] `v1.0.0` resolves immutably to that commit and matches both version sources;
- [ ] deterministic, security, warning-strict, Viewer, and MCP checks pass;
- [ ] the live suite passed in full with no skips on the final display/input behavior;
- [x] SPAO-148 has retained rendered-pixel evidence (2026-09-05 working-tree development build);
- [ ] every remaining P0/P1 and BUG-9/BUG-10 has a policy-compliant disposition;
- [ ] the exact candidate passed signature, notarization, staple, checksum, candidate-record,
  Gatekeeper, embedded-version, and fresh-mount verification;
- [ ] intended-distribution qualification completed on the recorded authorized host/login;
- [ ] clean uninstall and final zero-resource cleanup passed;
- [ ] the qualification record is committed or immutably linked; and
- [ ] the release owner has reviewed all evidence and recorded an explicit GO.

After approval, the publication job must publish the already-qualified candidate by immutable
artifact ID. It must not rebuild or accept replacement local files.

## Post-publication verification and closeout

After GitHub reports the release published:

1. Download the public assets through the release page, not from the workflow workspace.
2. Re-run `make verify-release-candidate` and `make verify-distribution` on those downloads.
3. Install, run `spaceo version --json` and `spaceo doctor --json`, exercise one minimal session,
   then destroy it and cleanly uninstall.
4. Confirm the release contains the DMG, checksum, detached checksum signature, candidate record,
   and detached candidate-record signature.
5. Confirm the public tag object and release assets match the retained candidate exactly.
6. Update `docs/RELEASE_POLICY.md` Current status only after publication is verified.
7. Mark SPAO-115 complete and close signing/notarization tickets only with links to the immutable
   workflow, release, and artifact qualification record.

Useful final checks:

```bash
gh release view v1.0.0 --repo ParthJadhav/SpaceO
git ls-remote --tags origin refs/tags/v1.0.0
```

If any public asset differs from the qualified candidate, stop distribution, remove the release
from availability if necessary, preserve the evidence, and investigate. Never move or reuse the
`v1.0.0` tag; prepare a new version after fixing the issue.
