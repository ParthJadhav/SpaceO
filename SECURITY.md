# Security policy

## Reporting a vulnerability

Please use GitHub's private **Report a vulnerability** form in the
[SpaceO security advisories](https://github.com/ParthJadhav/SpaceO/security/advisories) rather
than a public issue. Include the affected commit or version, macOS version and architecture,
required permissions, impact, reproduction steps, and any proof of concept.

If private reporting is unavailable, open a public issue containing only a request for a private
contact channel. Do not include exploit details, secrets, screenshots, process data, or other
sensitive material in that issue.

Maintainers aim to acknowledge a complete report within three business days and provide an
initial assessment within seven. These are response targets, not guarantees. Please allow a
reasonable remediation and release window before disclosure; the reporter and maintainer should
coordinate disclosure when users have a verified update.

Good-faith research that avoids privacy violations, persistence, service disruption, and access
to data beyond what is needed to demonstrate the issue is welcome. Do not test against systems or
accounts you do not own or have explicit permission to use.

## Supported versions

Security fixes are provided for the latest qualified public release. Older releases and
unreleased source snapshots may receive fixes at maintainer discretion. The current
release is [latest signed SpaceO release](https://github.com/ParthJadhav/SpaceO/releases/latest); see the
[release policy](docs/RELEASE_POLICY.md).

## Security boundary

SpaceO is an attention-isolation tool, not an OS sandbox or hostile multi-tenant boundary.
Agent-controlled applications run as the logged-in macOS user and retain that user's effective
file, network, keychain, application-session, and notification access. Session identifiers and
controller leases coordinate ownership but are not authorization credentials.

The daemon and every MCP client for the same macOS login share privileges and local state. Screen
content, Accessibility trees, typed text, screenshots, application paths, and recovery records
can be sensitive. Grant Accessibility and Screen Recording only to trusted launchers, protect
the local account, and do not expose the daemon socket or MCP transport across a trust boundary.
Use a separate macOS account or virtual machine for mutually untrusted workloads.

SpaceO discovers undocumented display, Space, event-delivery, and window APIs at runtime. Symbol
availability does not prove ABI or behavioral compatibility, and an OS update can change these
surfaces without notice. `spaceo doctor`, fail-closed runtime errors, and the release
qualification process reduce this risk but do not turn private APIs into a platform guarantee.
Never disable SIP or bypass Gatekeeper to make SpaceO work.

Examples of issues that should be reported privately include:

- capture or input escaping the intended session tile or process;
- a path that changes the user's active Space, focus, pointer, or physical display unexpectedly;
- unauthorized control of the daemon or another controller's session;
- unsafe process termination or recovery-ledger manipulation;
- disclosure of screenshots, Accessibility data, clipboard data, credentials, or local paths;
- a signing, notarization, update, or artifact-verification bypass.

## Public identity and private credentials

Developer ID signatures contain the certificate holder's identity and Apple Team ID. These are
public publisher metadata, not authentication secrets; the installer pins the expected publisher
to reject another developer's signed software. Removing the check would weaken verification and
would not conceal identity already present in downloaded signatures. Signing private keys,
certificate-export passwords, notarization keys, and GitHub tokens must remain private.

Use a GitHub-provided noreply address for Git commits. Source edits do not remove personal email
addresses from previous commit objects, old pull-request diffs, cached content, or existing clones.
History removal needs a coordinated rewrite and, for a released commit, a replacement provenance
plan. Never publish a mailmap containing the email being removed as a privacy fix.

GitHub-generated squash commits can use an account email even when every local commit uses
noreply metadata. Enable **Keep my email addresses private** and **Block command line pushes
that expose my email** in [GitHub email settings](https://github.com/settings/emails).
For CLI merges, use `gh pr merge NUMBER --squash --author-email GITHUB_NOREPLY_ADDRESS`, choosing
the intended author's GitHub noreply address, and inspect the resulting remote author and
committer metadata without printing personal values. Do not infer web/API merge privacy from
`git config user.email`. Repository metadata restrictions require an eligible GitHub Enterprise
organization; ordinary branch protection and content scans do not enforce this setting.

`python3 scripts/check-public-privacy.py` checks tracked text and private file types without
printing matched values. CI also scans history with Gitleaks. These checks do not prove that all
personal data is absent: visually review media and inspect public logs, artifacts, discussions,
and release metadata. Live qualification retains raw evidence privately on the dedicated runner;
only reviewed, redacted summaries may be made public.
