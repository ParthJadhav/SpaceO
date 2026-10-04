# SpaceO 1.0.7 publication record

SpaceO [1.0.7](https://github.com/ParthJadhav/SpaceO/releases/tag/v1.0.7) was published as latest,
non-draft and non-prerelease on October 4, 2026. Its initial public notes matched the committed
[release notes](../RELEASE_NOTES_1.0.7.md), including the qualification exception and open incident.

## Owner decision and limits

After reviewing the merged fixes and being told the earlier ColorSync spike remains open, the
owner instructed **"Create a new release"**. The [policy](../RELEASE_POLICY.md#current-status)
and [preparation record](2026-10-04-release-1.0.7.md) record this as GO for 1.0.7 with missing
full live-suite/matrix and new exact-artifact behavior qualification disclosed, conditional on
all source, signing, notarization, provenance and distribution checks. The exception applies
only to 1.0.7 and does not close RA-057 or #38, bypass runtime refusal, or qualify the affected Mac.
The focused modified-build native workflow is separate evidence; no experimental waiver ships.

## Immutable candidate

| Field | Value |
|---|---|
| Source on `main` | `a247246a9ad722170e0aeae04b13e7d863f5a81e` |
| Release preparation | [PR #43](https://github.com/ParthJadhav/SpaceO/pull/43) |
| Included fix PRs | [#41](https://github.com/ParthJadhav/SpaceO/pull/41), [#42](https://github.com/ParthJadhav/SpaceO/pull/42) |
| Annotated tag | `v1.0.7` |
| Tag object | `1e725059fef2503dc976bd6551e163af2a412b8f` |
| Candidate/publication workflow | [37177699599](https://github.com/ParthJadhav/SpaceO/actions/runs/37177699599), attempt 1, successful |
| Actions artifact ID | `11294300095` |
| Artifact archive SHA-256 | `b00f7eab6fce721191a8852d52c4b0f0f29da60f15e5547e81b9fd3dcce8797a` |
| DMG | `SpaceO-1.0.7-macOS-arm64.dmg` |
| DMG bytes | `13455620` |
| DMG SHA-256 | `1c0370df5fc0876d271ad8856e6281a4be004a0f67f05b97980d67d85d04df20` |
| GitHub release ID | `402846311` |

## Verification

- Local release gates passed with 1,762 deterministic Swift tests, 20 Python host-health tests,
  supporting safe harnesses, 35-tool MCP smoke, configuration/dry run, release-security/live-test
  gates, public privacy/whitespace checks, strict ad-hoc Viewer signature/version and optimized
  warnings-as-errors build. Local Xcode was 27.0 / Swift 6.4 on arm64.
- Both [PR CI](https://github.com/ParthJadhav/SpaceO/actions/runs/37177015039) and
  [merged-source CI](https://github.com/ParthJadhav/SpaceO/actions/runs/37177351640) passed on
  pinned Xcode 26.3 / Swift 6.2 before tagging. The merged tree matched the tested head.
- The protected `release` approval enabled candidate construction. Its signed 17-field provenance
  record binds source, tag object, workflow/run/attempt and distribution digests. The archive was
  downloaded by immutable artifact ID; its SHA-256 and exact five-file bounded contents matched
  GitHub metadata before extraction.
- Independent verification authenticated candidate provenance, publisher/checksum signatures,
  notarization staples, Gatekeeper assessments, embedded CLI/Viewer 1.0.7 versions and fresh-mount
  distribution on arm64 macOS 27.2 build 26B5091g. No Viewer or session was launched.
- The separate protected publication approval named the exact source, tag object, artifact
  ID/digest and qualification exception. Its credential-free job reverified the same artifact,
  checked the immutable tag and published the retained bytes without rebuilding. Neither
  protected environment was bypassed.
- All five assets were downloaded through unauthenticated public release URLs. Every digest
  matched both the retained candidate and GitHub asset metadata. Full candidate/distribution
  verification passed again, and latest/stable status and initial notes were checked.
- Public source/merge and annotated tag metadata use GitHub noreply identities. The original
  checkout's unrelated history was preserved. Version 1.0.6 remains available for rollback.

## Reporter replies

The concise replies were read back and matched their intended text. Reports remain open for
confirmation on reporter hosts; publication does not close the incident or full qualification.

| Report | Follow-up |
|---|---|
| #34 host health | [Try 1.0.7](https://github.com/ParthJadhav/SpaceO/issues/34#issuecomment-5976734096) |
| #36 absent ColorSync service / old latch | [Try 1.0.7](https://github.com/ParthJadhav/SpaceO/issues/36#issuecomment-5976734346) |

Private logs, approval receipts, archive metadata, signed candidate and public-download comparisons
are retained under the ignored owner-only `.artifacts/release-1.0.7/` directory. No new live workload,
host installation, safety-state reset, profile deletion or service reset was performed for this release.
