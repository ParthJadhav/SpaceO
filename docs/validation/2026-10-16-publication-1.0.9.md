# SpaceO 1.0.9 publication record

SpaceO [1.0.9](https://github.com/ParthJadhav/SpaceO/releases/tag/v1.0.9) was published as latest,
non-draft and non-prerelease on October 16, 2026 (09:58 UTC). Its public notes match the
committed [release notes](../RELEASE_NOTES_1.0.9.md), including the qualification exception,
with the relative safety-guide link rewritten to its `v1.0.9` URL.

## Owner decision and limits

The owner granted administrator access on the development Mac and instructed **"do everything
which is needed"** and **"do not log out though"**. The [policy](../RELEASE_POLICY.md#current-status)
and [preparation record](2026-10-16-release-1.0.9.md) record this as GO for 1.0.9. The exception
covers:
- live checks that ran only under the testing-host override, because normal admission refuses
  for the rest of the boot after the 01:13 WindowServer watchdog report;
- the missing normal-admission run, full live suite and computer-use matrix;
- missing signed-artifact behavior qualification.

It is conditional on all source, signing, notarization, provenance and distribution checks. The
exception applies only to 1.0.9 and does not close RA-057 or #38.

## Immutable candidate

| Field | Value |
|---|---|
| Source on `main` | `6094a8781f0e6d8b880115e40ee6e806a47988e6` |
| Release preparation | [PR #60](https://github.com/ParthJadhav/SpaceO/pull/60) |
| Included fix PR | [#59](https://github.com/ParthJadhav/SpaceO/pull/59) |
| Annotated tag | `v1.0.9` |
| Tag object | `a963b58603a5be7862f002f01f2e655cc7d7ea8d` |
| Candidate/publication workflow | [38881841629](https://github.com/ParthJadhav/SpaceO/actions/runs/38881841629); candidate attempt 2, publication attempt 2, successful |
| Actions artifact ID | `12038473036` |
| Artifact archive SHA-256 | `fa70c7481788f9b526eeeb861eeb7910edaa31753e636a8dedf3e143971a0df0` |
| DMG | `SpaceO-1.0.9-macOS-arm64.dmg` |
| DMG bytes | `13854995` |
| DMG SHA-256 | `86f0ff654e154878e23ce1eb3a78d4bfb830e83d482ed180ad04bf0d2c7bb511` |
| GitHub release ID | `414798439` |

## Verification

- **Local release gates** passed on the release source:
  - release configuration and dry run;
  - release-security and live-test gate tests;
  - `make verify-release`: 1,925 deterministic Swift tests with supporting harnesses, the optimized
    build and the 35-tool MCP smoke check;
  - the optimized warnings-as-errors build;
  - the public privacy and whitespace checks;
  - an ad-hoc Viewer bundle reporting 1.0.9 that passed strict signature checks.

  Toolchain: Xcode 27.0 / Swift 6.4 on arm64.
- **CI before tagging.** [PR CI](https://github.com/ParthJadhav/SpaceO/actions/runs/38879986519) and
  [merged-source CI](https://github.com/ParthJadhav/SpaceO/actions/runs/38881012775) passed on
  pinned Xcode 26.3 / Swift 6.2. The merged tree matched the reviewed head.
- **Candidate attempt 1** built, signed and notarized the bundle. `stapler validate` then failed on
  a transient Apple CloudKit network error (`NSURLErrorDomain -1005`, exit 68). Re-running only
  the failed job on the same immutable tag (attempt 2) produced the retained candidate, under a
  second protected `release` approval.
- **Independent verification.** The archive was downloaded by immutable artifact ID. Its SHA-256
  and five-file contents matched GitHub's metadata. `verify-candidate` from the tag checkout then
  authenticated:
  - candidate provenance (commit, tag object, run and attempt);
  - publisher and checksum signatures;
  - notarization staples;
  - Gatekeeper and fresh-mount distribution on arm64 macOS 27.2 (26B5091g).

  No Viewer or session was launched.
- **Publication.** The protected `release-publication` approval named the exact source, tag
  object, artifact ID and digests, and the exception. The publication job reverified the
  retained candidate and published it without rebuilding. Neither protected environment was
  bypassed.
- **Public downloads.** All five assets were downloaded through unauthenticated public release
  URLs, and each was byte-identical to the retained candidate. Full candidate and distribution
  verification passed again on the public bytes. The latest-release status and the published
  notes were checked.
- Source, merge and annotated-tag metadata use GitHub noreply identities. Version 1.0.8 remains
  available for rollback.
- **Development Mac.** It now runs 1.0.9 from a source install of the tag (`make install`), and its
  idle daemon was restarted onto 1.0.9.

Private logs, approval receipts, the downloaded candidate and public files, and verification
output are kept under the ignored owner-only `.artifacts/release-1.0.9/` directory. No screenshots, Accessibility content or credentials are committed.
