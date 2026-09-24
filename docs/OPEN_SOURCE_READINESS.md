# Open-source readiness

Preparation date: 2026-09-24. **Source is public. Binary release qualification is pending.**
This record describes preparation, not authorization to publish or evidence that all defects
have been eliminated.

## Completed source preparation

- README with a synthetic Viewer screenshot, display/session flow, architecture, source setup,
  truthful binary availability, and links to the detailed reference.
- MIT license retained, contribution guide and CODEOWNERS added. The Swift package contains no
  external package dependencies or vendored third-party framework binaries. The source's private
  API declarations and runtime discovery are documented; Apple SDKs are not redistributed.
- HTML planning documents converted to Markdown. Private integration names and local paths
  removed from public summaries. Safety findings and failed qualification evidence retained.
- Local agent configuration, marketing experiments, build/capture evidence, signing keys,
  and DMGs excluded from source control. Generated marketing assets are not distributed.
- CI and both signing/publication jobs use disposable GitHub-hosted Apple Silicon runners
  (`macos-15`, Xcode 26.3, Swift 6.2). No contributor PR runs on the maintainer's workstation.
- Actions pinned by SHA; Gitleaks binary pinned by version and SHA-256. Read-only tokens by
  default and no persisted checkout credentials. Weekly dependency-update configuration is
  prepared with PR creation paused until visibility review, preserving the single-commit launch.
- Signing stays in the `release` environment; the publication job has no signing secrets and
  verifies the retained, signed candidate before uploading the exact DMG to GitHub Releases.
- DMG container signing added alongside payload signing, notarization, stapling, signed
  checksums, publisher validation, and Gatekeeper checks. Temporary signing files are created
  with `umask 077`; the generated keychain password is masked and cleanup remains trapped.
- Release preflight requires configured reviewers and tag-only environment restrictions. Both
  release and live workflows are disabled in GitHub; their repository enable switches are false.
- Optional live automation additionally requires a reviewed environment, main-only dispatch,
  and a dedicated `spaceo-live` host. The personal `spaceo-mac` label is explicitly refused.

## Security and privacy review

Gitleaks 8.30.1 scanned all 223 locally reachable historical commits. Eighteen historical
matches were the same synthetic password in `ChromiumFieldStateTests.swift`; the exception
matches that exact value and exact file only. With that reviewed exception, no credential
findings remained. No credential values were printed or added to the repository.

All 49 GitHub Actions runs were inventoried; logs were downloadable for 48. The available logs
had no Gitleaks findings. The unavailable log cannot be assessed. No retained workflow artifacts
or binary release assets were present at audit time. Six expected signing/notary secret names
exist in the `release` environment; their values, validity, and expiration were not inspected.

This is a scoped repository and automation audit, not proof of absence of all secrets,
security defects, or third-party rights claims. The owner must confirm rights to contributed
source and brand assets. A rewritten branch does not erase GitHub pull-request refs, cached
commit views, old logs, or other people's clones. Never make those surfaces public on the
assumption that squashing `main` purges them.

## GitHub configuration

Applied while private: description and topics, squash-only merges, automatic merged-branch
cleanup, disabled wiki/projects, read-only workflow tokens, disabled workflow PR approval,
SHA-pinning enforcement, and GitHub-owned actions only. The personal runner was unregistered;
no self-hosted runner remains registered with this repository.

After the owner explicitly authorized open sourcing, the repository was made public on
2026-09-24. GitHub now confirms both rulesets are active. Required owner reviewers and no admin
bypass are configured on `release`, `release-publication`, and `live-qualification`. Release
environments allow only `v*` tags; live qualification allows only `main`. All external contributors
require approval before fork workflows run. Private vulnerability reporting, secret scanning,
and secret push protection are enabled. The earlier private-plan restrictions are resolved.

Hosted CI was restarted after the visibility change and is running on GitHub-hosted runners;
its secret scan has passed. The workflow result, not this status note, is the build evidence.
Binary publication still requires qualification and explicit owner GO under the release policy.

## Validation

- `make verify-release`: 1,582 Swift tests, Viewer install transaction tests, 14 Node tests,
  and the 34-tool MCP smoke check passed.
- Release security tests (including rejection of a wrong-publisher DMG), live skip-gate tests,
  release configuration check, and release dry run passed.
- `actionlint` and documentation file-link checks passed.
- Optimized warnings-as-errors build, ad-hoc Viewer build, and deep/strict codesign verification passed.
- Final staged-source export scan found no credentials after the same exact fixture exception.
- GitHub-hosted CI was attempted on the squashed root. Both jobs failed before starting:
  "The job was not started because an Actions budget is preventing further use." This is not
  hosted build/test evidence; billing must be resolved or CI rerun after authorized publication.

No full live suite or computer-use matrix was run on the active desktop. The screenshot task
attempted a fixture-only background preview; its window discovery failed on Accessibility
permissions, and its temporary session was cleaned up. The README uses an inspected existing
fixture capture instead. This is not live qualification or signed-distribution evidence.

## History cleanup

`main` was replaced with one parentless initial commit using an exact force-with-lease against
its previous tip. All eight older remote branches, the historical `v1.1.0` tag, the source-only
prerelease, and the empty `v1.1.1` draft were removed. No binary assets existed to remove.
Local archived refs and a verified recovery bundle remain in ignored private audit storage;
never push them. Closed pull requests and GitHub cached commit views can still refer to old
history. That history was scanned, but is not purged by the rewrite. Existing historical audit
records retain old commit identifiers as evidence identifiers, not current checkout instructions.

## Remaining binary-release work

1. Review the single-commit source and remaining closed pull-request refs/cached historical
   views and old Actions logs. Keep recovery history private and local. If historical content
   must be purged from GitHub caches, coordinate with GitHub support before visibility changes.
   No credential leak was found that would justify rotation from this scan.
2. Retain successful hosted CI on the final source. Visibility and repository protection
   configuration are complete; local success does not prove the hosted image can build it.
3. Protect `release` and `release-publication` with the release owner as required reviewer,
   disable admin bypass, and restrict deployments to **tags** matching `v*`. Keep signing
   credentials solely in `release`. Approving your own deployment is intentional for a solo
   release owner; it is separate from initiating a tag push.
4. Resolve current release-relevant audit findings and perform complete live qualification on an
   eligible idle host. Historical failed/partial records do not qualify a new artifact.
5. After explicit authorization, enable candidate construction, obtain a signed/notarized DMG,
   validate the exact downloaded candidate and intended-install/uninstall behavior, and retain
   the evidence required by `RELEASE_POLICY.md`.
6. Record release-owner GO and approve `release-publication`. The workflow then uploads the DMG,
   checksum, signature, and provenance record to the GitHub Releases page. A tag alone is not GO.

Public visibility was explicitly authorized and completed. Binary release approval remains a
separate decision after candidate verification; this preparation record is not a release GO.
