# October 3 user issue fixes for 1.0.6

## Scope and authorization

Started from current remote main `a858236`, preserving unrelated local history in the original
checkout. Four reports were open: #29 screenshot output directories, #30 native text replacement,
#34 and #36 absent ColorSync service admission and false persistent unknown latches.

The release owner instructed: "fix all the issues you can" and "create a new release with those
fixes and reply to the users as well", and authorized this computer for testing and deployment
with no follow-up questions. This is recorded as release-specific owner direction for 1.0.6,
with the missing behavior qualification and RA-057 disclosed. It does not authorize bypassing
runtime admission, weakening signing/distribution gates, or claiming the incident resolved.

## Implementation evidence

Both health reports identify an absent on-demand ColorSync service. The native and Python
parsers required both services, so a successful listing without them threw unknown. New logic
requires verified launchd idle/never-started state and unchanged launch counts before admitting
absence as zero. Exactly one new launch can use its whole CPU total; hidden relaunches, exits,
restarts, duplicate identities and malformed/unavailable data still refuse. The process list is
reconciled with launchd observations, and launch counts are read again after the final process
snapshot so a launch/exit between reads cannot disappear. All sampling work shares a deadline. This adopts
the verified idle-evidence approach from Muness Castle's PR #37 while excluding its headless
Stage/window changes. Issue #38 remains open for live qualification.
The startup decision waits 15 seconds, covering two bounded samples five seconds apart.

The old journal is never reset automatically. Explicit operator recovery locks it in place,
refuses active owners, pending mutations/live cases or other failure classes, checks no SpaceO
display and passing current observations, archives the latch and preserves rolling budgets.
Recovery persists a blocking marker before publishing a complete, pre-synced receipt by
exclusive rename. A deadline abort exclusively claims the same decision path, preventing a
late commit from replacing a confirmed abort. If both filesystem operations stall, the result
is explicitly undecided and the worker retains the lifecycle lock until completion. Doctor
stays read-only and reports that undecided state as unknown; fresh health admission is still
required for subsequent creation. Archives, receipts and rolling budgets are retained.

Native synthetic Command-A was never checked before typing. The fix uses exact-window native
Accessibility selection and selected-text mutation with full bounded readback, UTF-16 range
validation and no duplicate fallback after a write. Web/secure/editor mirrors are excluded.
Collapsed-caret typing retains key delivery. Unsupported replacement refuses before typing.
Qualification, ancestry, target checks and edits share one three-second Accessibility budget.
Target changes and budget exhaustion refuse rather than falling back to synthetic typing.
This is deterministic implementation evidence; TextEdit behavior on reporter hosts remains
subject to their verification.

Screenshot output creates its parent chain only after timely capture/encoding and geometry
validation. Parent creation errors name the parent path. Existing capture timeout and late-write
protections remain covered.

The secondary permission-remediation report in #34 also reproduced in source: `doctor --fix`
chose the daemon's missing grant, then named the caller's app after opening Settings. It now
uses the daemon's reported attribution; unavailable or silent-daemon attribution stays unknown
rather than falling back to Terminal. Deterministic tests cover a launchd executable, missing
attribution, an old/silent daemon and an absent daemon.

## Host and release boundaries

The read-only preflight on macOS 27.2 build 26B5091g, Apple Silicon, refused
`recent_windowserver_diagnostic` (one report; normal memory pressure, no new swap, zero bounded
system-service timeout matches). No live display creation or input followed that refusal.
This is not passing qualification. Local compiler is Xcode 27 / Swift 6.4; hosted CI and
candidate workflows pin Xcode 26.3 / Swift 6.2 separately.

RA-057 remains open. No new live suite, computer-use matrix, physical Viewer control, Chromium
motion or exact-artifact behavior pass is claimed. Release 1.0.6 is owner-directed with those
limits disclosed; future versions retain the default release gates.

## Verification status

After the hosted review fixes, `make verify-release` passed all 1,745 deterministic Swift tests,
the supporting Python, shell and Node checks, and MCP smoke for 35 tools. The revised focused
suites passed 114 Swift tests and 18 Python health tests. Guard-removal checks in the earlier
health implementation caused the relevant suites to fail and were restored.
`Tests/ReleaseSecurityTests.sh`, `Tests/LiveTestGateTests.sh`, release configuration/dry-run,
public-file privacy checks and `git diff --check` passed. Local dry-run credentials are absent;
signing and notarization remain confined to the protected hosted workflow.

The optimized warnings-as-errors build passed. The ad-hoc Viewer bundle built and passed strict
deep signature verification without being launched. Hosted review identified persistence,
Accessibility deadline/focus, CLI exit-status and late ColorSync churn defects; the follow-up
fixes passed the fresh complete source gate. Opus 5.5 reviewed the high-risk recovery and native
paths; its final requested outcome-reporting and focus checks are implemented with regressions
for both commit/abort orders, owner exclusion and focus moving during qualification. Hosted CI, signed candidate construction,
publication and public-download verification are tracked by the subsequent completion entry.
Screenshots, process lists, Accessibility content and raw host logs remain private.

## Publication and replies

PR #39 merged as `7617109` after both required checks passed. Immutable tag `v1.0.6` names that
source; the protected candidate/publication workflow succeeded. The retained signed candidate
and all five unauthenticated public downloads passed exact provenance and fresh-mount
distribution verification. Version 1.0.6 is published as latest, and the reporter replies were
posted and read back. Screenshot issue #29 is closed; #30/#34/#36 await reporter confirmation,
while #38 and RA-057 remain open. See the [publication record](2026-10-03-release-1.0.6.md) for
immutable artifact identifiers and reply links.
