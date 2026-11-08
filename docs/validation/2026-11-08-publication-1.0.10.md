# SpaceO 1.0.10 publication record

SpaceO [1.0.10](https://github.com/ParthJadhav/SpaceO/releases/tag/v1.0.10) was published as
latest, non-draft and non-prerelease on November 8, 2026 (15:09 UTC). Its public notes match the
committed [release notes](../RELEASE_NOTES_1.0.10.md), including the qualification exception.

## Owner decision and limits

After #67 merged, the owner instructed **"merge, deploy and create a new version"**. The
[policy](../RELEASE_POLICY.md#current-status) and
[preparation record](2026-11-08-release-1.0.10.md) record this as GO for 1.0.10. The exception
covers:
- the missing full live suite and computer-use matrix on the release source;
- missing signed-artifact behavior qualification.

It is conditional on all source, signing, notarization, provenance and distribution checks. The
exception applies only to 1.0.10.

## Immutable candidate

| Field | Value |
|---|---|
| Source on `main` | `571c0c34ca3c9cb20b967798a7c898df9e42c8db` |
| Release preparation | [PR #68](https://github.com/ParthJadhav/SpaceO/pull/68) |
| Included PRs | [#62](https://github.com/ParthJadhav/SpaceO/pull/62), [#63](https://github.com/ParthJadhav/SpaceO/pull/63), [#67](https://github.com/ParthJadhav/SpaceO/pull/67) |
| Annotated tag | `v1.0.10` |
| Tag object | `fd0916ee7138f05707ae8cd93415922f24f91d1f` |
| Candidate/publication workflow | [42490130296](https://github.com/ParthJadhav/SpaceO/actions/runs/42490130296); candidate attempt 4, publication attempt 4, successful |
| Actions artifact ID | `13622206891` |
| Artifact archive SHA-256 | `6d23fffd55199d7a4843d114132f78673e994830fd95216084690da3a0d063c9` |
| DMG | `SpaceO-1.0.10-macOS-arm64.dmg` |
| DMG bytes | `13887715` |
| DMG SHA-256 | `1bb51a104de34615b27401b7c4f1c1dcec60e80e8189a7c5e119357d1b3c4207` |
| GitHub release ID | `438322305` |

## Verification

- **Local release gates** passed on the release source; see the
  [preparation record](2026-11-08-release-1.0.10.md#deterministic-evidence).
- **CI before tagging.** [PR CI](https://github.com/ParthJadhav/SpaceO/actions/runs/42488845862)
  and [merged-source CI](https://github.com/ParthJadhav/SpaceO/actions/runs/42489408920) passed on
  pinned Xcode 26.3 / Swift 6.2. The merged tree matched the reviewed head.
- **Candidate attempts 1–3** built and tested the source, but a `stapler` call failed each time
  on a transient Apple CloudKit network error (`NSURLErrorDomain -1005`, exit 68): twice on the
  DMG after its notarization was accepted, once on the Viewer. Nothing was retained or published.
  Re-running only the failed job on the same immutable tag (attempt 4), under a further
  protected `release` approval each time, produced the retained candidate. The same error
  affected 1.0.9's first attempt; a bounded stapler retry would avoid repeated re-runs.
- **Independent verification.** The archive was downloaded by immutable artifact ID. Its SHA-256
  matched GitHub's digest and it held the five expected files. `verify-candidate` from the tag
  checkout then authenticated:
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
  URLs, and each was byte-identical to the retained candidate. `verify-candidate` passed again
  on the public bytes. The latest-release status and the published notes were checked.
- **Installer.** The public `install.sh` installed 1.0.10 into a temporary home, binary and
  application directory with `--no-setup --no-clients --no-modify-path`. It verified the
  publisher, notarization and checksum; the installed CLI reported 1.0.10, and the installed
  Viewer reported 1.0.10 and passed strict signature and Gatekeeper checks. The MCP smoke check
  (35 tools) passed against the installed CLI on a throwaway socket, and no process from it
  remained. The temporary install was then removed.
- Source, merge and annotated-tag metadata use GitHub noreply identities. Version 1.0.9 remains
  available for rollback.
- **Development Mac.** Its installed CLI, LaunchAgent and running daemon were not changed and
  still run 1.0.9. Updating it is a separate host change for the owner.

No screenshots, Accessibility content or credentials are committed.
