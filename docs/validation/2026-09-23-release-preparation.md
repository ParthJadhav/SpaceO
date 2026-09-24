# SpaceO 1.1.1 release preparation — 2026-09-23

Status: source preparation; **NO-GO for tagging and public publication** until the remaining
release gates are satisfied. No release tag or distribution artifact is created by this record.

## Source

The preparation includes the agent efficiency work through AE-210, recording/capture and
transport lifecycle fixes, agent recovery output, and Viewer simplification. Both VERSION and
SpaceOVersion.current are 1.1.1. CHANGELOG.md records the candidate as planned, and
docs/RELEASE_NOTES_1.1.1.md contains the prepared release notes.

The starting local and remote main were cec7173cdd3d920e4ff16ae359caca87e851055e.
The preparation commit containing this record identifies the final source; CI must cover it.

## Current GitHub state

- GitHub has a published, source-only v1.1.0 prerelease with no binary assets. Historical
  1.0.0 handoff statements that no tags/releases exist are superseded by this observation.
  That prerelease does not qualify a signed distribution of this candidate.
- CI passed on the starting main: run 35261462771. Final preparation CI remains required.
- The spaceo-mac self-hosted Apple Silicon runner is online. Its status alone does not establish
  an idle graphical login, TCC access, or current live qualification.
- The release-publication environment still has no protection rules. Publishing a tag can
  start the signing/publication workflow without a required-reviewer stop. No tag was pushed.
- Local release dry-run reports unset signing identity and notarization inputs. Secret values
  were not accessed; no conclusion about remote credential validity is inferred.

## Validation

- make verify-release passed: 1301 Swift tests, Viewer installer checks, 11 Node tests,
  and the 32-tool MCP smoke check.
- ReleaseSecurityTests.sh and LiveTestGateTests.sh passed. The latter validates skip detection,
  not live behavior.
- make release-check and make release-dry-run passed for 1.1.1.
- Optimized warnings-as-errors build passed.
- Ad-hoc Viewer bundle build and deep/strict codesign verification passed. This is development
  signature validation, not Developer ID/notarized distribution qualification.
- git diff --check passed.

Local logs are retained under .artifacts/release-preparation-2026-09-23/
(ignored; not distribution evidence).

The release security test initially rejected the committed self-hosted workflow's newer Xcode
path. Its exact toolchain expectations now match the workflow pins; old Swift and Xcode versions
are rejected, and all existing signing/publication checks are retained.

## Remaining publication gates

1. Green CI on the final preparation commit.
2. Required publication reviewers or a reviewed equivalent protected publication mechanism.
3. An eligible idle graphical login and retained, complete current live suite and computer-use
   matrix results; evidence-based closure of remaining release-relevant safety findings.
4. An immutable signed, notarized, stapled candidate, authenticated distribution verification,
   intended-distribution qualification, and successful cleanup/uninstall.
5. Release-owner GO after review of that exact candidate's evidence.

No live GUI test, host installation, signing/notarization upload, or publication is performed
by this source-preparation pass. docs/RELEASE_POLICY.md remains the distribution policy.
