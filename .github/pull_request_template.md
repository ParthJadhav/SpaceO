## Problem

<!-- The concrete problem this change solves. Link issues with "Fixes #123". -->

## Change

<!-- Behavior change, including any CLI, daemon protocol, MCP schema, or limit changes. -->

## Validation

- [ ] `make verify-release`
- [ ] `git diff --check`
- [ ] Release automation changed: `bash Tests/ReleaseSecurityTests.sh`, `bash Tests/LiveTestGateTests.sh`, warnings-as-errors release build
- [ ] Viewer changed: bundle built and `codesign --verify --deep --strict` passes
- [ ] User-visible behavior: `CHANGELOG.md` updated

<!-- Live tests create displays and synthesize input. Only run them on an idle, reserved host
     (docs/LIVE_TESTS.md) and say so here. Do not attach real screenshots, Accessibility content,
     controller leases, or unredacted logs. -->
