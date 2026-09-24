# Contributing to SpaceO

Start with [AGENTS.md](AGENTS.md) and [ARCHITECTURE.md](ARCHITECTURE.md). Small, focused pull
requests are easiest to review. Explain the concrete problem, behavior change, and validation.

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
