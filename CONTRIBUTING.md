# Contributing to SpaceO

Start with [AGENTS.md](AGENTS.md) and the [navigation map](docs/NAVIGATION.md), then read the
relevant [architecture](ARCHITECTURE.md) section. Small, focused pull
requests are easiest to review. Explain the concrete problem, behavior change, and validation.

Use your GitHub noreply address for public commits. Enable **Keep my email addresses private**
and **Block command line pushes that expose my email** in [GitHub email settings](https://github.com/settings/emails).
Local Git configuration alone does not govern GitHub-generated squash commits. Maintainers must
select the intended author's noreply address explicitly when merging and check the resulting
metadata; see [the privacy guidance](SECURITY.md#public-identity-and-private-credentials).

Run `make verify-release` and `git diff --check` before opening a pull request. Changes to
release automation also require `bash Tests/ReleaseSecurityTests.sh`,
`bash Tests/LiveTestGateTests.sh`, and a warnings-as-errors release build.

Keep tests deterministic. Never run live display/input tests on an actively used desktop;
follow [the live-test guide](docs/LIVE_TESTS.md). Preserve fail-closed capability checks and
truthful partial/unconfirmed results. New private APIs belong only in `SpaceOPrivate`.

Do not attach real screenshots, Accessibility contents, typed text, controller leases, signing
keys, or unredacted logs. Use synthetic fixtures and sanitized diagnostics. Report security
issues through [SECURITY.md](SECURITY.md), not public issues.

Contributions are licensed under the repository’s MIT license. Submit only code and assets you
have the right to contribute; identify any third-party source and retain its license notices.
