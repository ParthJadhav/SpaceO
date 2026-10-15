# SpaceO 1.0.8 publication record

SpaceO [1.0.8](https://github.com/ParthJadhav/SpaceO/releases/tag/v1.0.8) was published as latest,
non-draft and non-prerelease on October 15, 2026 (19:43 UTC). Its public notes match the
committed [release notes](../RELEASE_NOTES_1.0.8.md), including the qualification exception.

## Owner decision and limits

The owner instructed **"Fix the issues which came up as well and release the new version. Do
everything autonomously"**. The [policy](../RELEASE_POLICY.md#current-status) and
[preparation record](2026-10-16-release-1.0.8.md) record this as GO for 1.0.8. The exception
covers the incomplete full live suite, the matrix not repeated on the exact release source, and
missing signed-artifact behavior qualification. It is conditional on all source, signing,
notarization, provenance and distribution checks. The exception applies only to 1.0.8 and does
not close RA-057 or #38.

## Immutable candidate

| Field | Value |
|---|---|
| Source on `main` | `42e3214adcb78c325a9f98942b987a9c4d4d4b92` |
| Release preparation | [PR #57](https://github.com/ParthJadhav/SpaceO/pull/57) |
| Included fix PRs | [#46](https://github.com/ParthJadhav/SpaceO/pull/46), [#48](https://github.com/ParthJadhav/SpaceO/pull/48), [#49](https://github.com/ParthJadhav/SpaceO/pull/49), [#50](https://github.com/ParthJadhav/SpaceO/pull/50), [#51](https://github.com/ParthJadhav/SpaceO/pull/51), [#52](https://github.com/ParthJadhav/SpaceO/pull/52), [#55](https://github.com/ParthJadhav/SpaceO/pull/55), [#56](https://github.com/ParthJadhav/SpaceO/pull/56) |
| Annotated tag | `v1.0.8` |
| Tag object | `69b8fcad7468ecbf8b61f6d477542451bf0af501` |
| Candidate/publication workflow | [38793327819](https://github.com/ParthJadhav/SpaceO/actions/runs/38793327819); candidate attempt 2, publication attempt 3, successful |
| Actions artifact ID | `12000819416` |
| Artifact archive SHA-256 | `ab66a4739124b035be002dd783fa9b19cfa121d6519920d14d3259ac66afb644` |
| DMG | `SpaceO-1.0.8-macOS-arm64.dmg` |
| DMG bytes | `13674190` |
| DMG SHA-256 | `2ee657dc217905d96f21b0e28fbd935ad19828942ab6528ba8f4a5e04da56d64` |
| GitHub release ID | `414204551` |

## Verification

- Local release gates passed: release configuration and dry run, release-security/live-test
  gates, 1,880 deterministic Swift tests plus supporting harnesses, the optimized
  warnings-as-errors build, the 35-tool MCP smoke check, the public privacy and whitespace
  checks, and an ad-hoc Viewer bundle reporting 1.0.8 that passed strict signature checks.
  Toolchain: Xcode 27.0 / Swift 6.4 on arm64.
- [PR CI](https://github.com/ParthJadhav/SpaceO/actions/runs/38791214916) and
  [merged-source CI](https://github.com/ParthJadhav/SpaceO/actions/runs/38792321522) passed on
  pinned Xcode 26.3 / Swift 6.2 before tagging. The merged tree matched the tested head.
- **Candidate attempt 1** built, signed and notarized the bundle. `stapler validate` then failed on
  a transient Apple CloudKit network error (`NSURLErrorDomain -1005`, exit 68). Re-running only
  the failed job on the same immutable tag (attempt 2) produced the retained candidate, under a
  second protected `release` approval.
- **Independent verification.** The archive was downloaded by immutable artifact ID. Its SHA-256
  and five-file contents matched GitHub's metadata. `verify-candidate` from the tag checkout then
  authenticated candidate provenance (commit, tag object, run and attempt), publisher and checksum
  signatures, notarization staples, Gatekeeper and fresh-mount distribution on arm64 macOS 27.2
  (26B5091g). No Viewer or session was launched.
- **Publication.** The protected `release-publication` approval named the exact source, tag
  object, artifact ID and digests, and the exception. The publication job's own re-verification
  hit the same transient CloudKit error once. Its re-run (attempt 3) reverified the same artifact,
  confirmed the tag had not moved, and published the retained bytes without rebuilding. Neither
  protected environment was bypassed.
- **Public downloads.** All five assets were downloaded through unauthenticated public release
  URLs. Every digest matched the retained candidate and GitHub's asset metadata, and full
  candidate/distribution verification passed again on the public bytes. The latest-release
  status and the published notes were checked.
- Source, merge and annotated-tag metadata use GitHub noreply identities. Version 1.0.7 remains
  available for rollback.

Private logs, approval receipts, the downloaded candidate record, verification output and the
retained live-run logs are kept under the ignored owner-only `.artifacts/release-1.0.8/`
directory. No screenshots, Accessibility content or credentials are committed.
