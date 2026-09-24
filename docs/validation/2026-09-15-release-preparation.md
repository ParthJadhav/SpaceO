# SpaceO 1.0.0 release preparation — 2026-09-15

Status: **NO-GO for tagging and publication**. This is source preparation, not signed-artifact
qualification. No release tag, GitHub release, or uploaded distribution artifact was created.

## Source and notes

The release includes the transcript improvements and existing setup, Viewer, resource-accounting,
and qualification-harness changes in the working tree based on
`e95b5a02be0dd5f016b1d684fe16161a74e66140`. Preparation commit
`21e01b725cedaa6dbff6e6bd5c5ce7a6a720d5c7` contains that source and was pushed to `main`.
This follow-up record changes documentation only; candidate CI must cover the final commit.
`VERSION` and `SpaceOVersion.current` remain `1.0.0`, because no earlier release exists.

The changelog now consolidates all first-release changes under a planned `1.0.0` section with
an empty `Unreleased` section. The release date must be set only when publication is approved.
[Prepared release notes](../RELEASE_NOTES_1.0.0.md) describe the candidate contents and limitations.

## Refreshed checks

- `make verify-release`: passed; 611 Swift tests, 11 JavaScript tests, and the 23-tool MCP smoke.
- `bash Tests/ReleaseSecurityTests.sh`: passed.
- `bash Tests/LiveTestGateTests.sh`: passed; this validates the test gate, not live behavior.
- `make release-check`: passed; both version sources agree.
- `make release-dry-run`: passed; local signing identity and notarization inputs are unset.
- `swift build -c release -Xswiftc -warnings-as-errors`: passed.
- Ad-hoc Viewer build and `codesign --verify --deep --strict --verbose=2`: passed.
  This verifies development bundle structure, not notarized distribution trust.
- `git diff --check`: passed.

Local logs are retained in `.artifacts/release-preparation-2026-09-15/`. They are development
verification evidence and do not authenticate a signed release candidate. Historical September 5
live evidence does not qualify the changed display/input behavior in this source.

## GitHub state rechecked

- Remote `main`: `e95b5a02be0dd5f016b1d684fe16161a74e66140` before preparation.
- Latest CI on that prior commit: [run 33791682593](https://github.com/ParthJadhav/SpaceO/actions/runs/33791682593), successful.
- CI on the preparation commit: [run 35004771204](https://github.com/ParthJadhav/SpaceO/actions/runs/35004771204),
  failed before executing any steps. GitHub's check annotation reports recent account payment
  failures or an Actions spending limit that needs increasing. This is not a test failure and
  cannot be counted as a passing CI run. Billing changes were not made.
- No version tags or releases exist.
- All six documented signing/notarization secret names exist in the `release` environment;
  values were not accessed and credential validity remains untested.
- No self-hosted runners or repository variables are configured. An eligible local login remains
  an alternative under the release policy.
- `release-publication` has no protection rules. An attempt to configure the repository owner
  (`ParthJadhav`) as required reviewer returned HTTP 422: the billing plan does not support required
  reviewers. No billing or repository-visibility change was made.

## Remaining gates

1. Resolve the GitHub Actions payment/spending-limit blocker and pass CI on the final commit.
2. Obtain a supported required-reviewer configuration or implement and review an equivalently
   protected publication mechanism. Until then, a tag push could publish without artifact review.
3. Reserve an idle graphical login, check host prerequisites, and retain complete no-skip
   `make test-live-full` and `make computer-use-check-full` results for the current behavior.
   The owner authorized this Mac on September 16. The subsequent suite and matrix failed;
   [diagnostic evidence](2026-09-16-live-qualification.json) records launch isolation and Cursor
   startup failures. An unrelated daemon appeared during testing, so the login was not
   demonstrably undisturbed. No passing live qualification is claimed.
4. Resolve or document evidence-based dispositions for remaining release-relevant P0/P1 findings
   and BUG-9/BUG-10 under the release policy, including current capture and Viewer behavior.
5. After pre-tag requirements and owner authorization, construct the immutable workflow candidate,
   verify its publisher, notarization, staples, Gatekeeper, checksum, and provenance, then qualify
   that exact downloaded payload, including install/uninstall and zero-resource cleanup.
6. Retain the candidate evidence and obtain explicit owner GO before publication.

The [release handoff](../RELEASE_HANDOFF_1.0.0.md) and [policy](../RELEASE_POLICY.md) remain authoritative.
