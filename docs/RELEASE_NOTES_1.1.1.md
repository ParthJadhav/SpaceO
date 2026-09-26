# SpaceO 1.1.1

Status: draft native-app and Chromium preview; publication is blocked by incomplete live and
signed-artifact qualification. Managed Electron launches are explicitly refused.

This maintenance release improves agent usability, bounds background work and memory, and
simplifies the Viewer controls. It preserves explicit partial/unknown isolation results and
controller ownership rules.

## Changes

- Contain display-service failures with bounded lifecycle waits, shared creation limits and a
  persistent failure latch. Stop live suites after the first failure. The blanket macOS 27+
  quarantine is removed; display-configuration guards remain.
- Use verified display snapshots while a lifecycle mutation is busy, retain backings after
  failed cleanup preflight, and report lifecycle health without journal I/O in ordinary replies.
- Open reused Chromium files in background targets and return partial-completion receipts when
  some opens fail, preserving evidence needed to avoid duplicate retries.
- Contain Chromium startup windows before DevTools readiness, bound diagnostic journal reads,
  and report both persistent creation-rate limits even with resource overrides.
- Reject empty or mismatched focused live runs and suspend live children on terminal hangup.
- Preserve failed-case cleanup before latching and suspend owners whose cleanup is unverified;
  distinguish browser failures before sending from uncertain delivery.
- Use a dedicated vector template mark for the Viewer's menu-bar item.
- Reduce temporary allocations in MCP handling, Accessibility observations, event framing,
  capture, recording reports, and Viewer updates; bound queues, buffers, and retained work.
- Apply monotonic deadlines across transport, browser discovery, waits, and capture admission;
  improve cancellation, callback cleanup, and teardown recovery.
- Preserve truncation, failed-step, capture-freshness, and input-delivery evidence in agent output.
- Report retained sessions after failed MCP create-and-open operations so agents can recover
  without another discovery call; keep controller leases private.
- Implement bounded before/after frames for opt-in recording, with explicit timeout, failure,
  and capacity statuses. Images can contain visible user content; actions-only mode writes no images.
- Simplify the Viewer around Take Control and Pause/Resume Agent, preserve preferences, and
  improve event delivery and stream resource handling.
- Harden daemon diagnostic bounds, log rotation, telemetry conversion, and clock handling.

The full change history and measured limitations are recorded in CHANGELOG.md and
docs/AGENT_EFFICIENCY.md. Synthetic benchmarks are not production latency or RSS guarantees.

## Qualification

The current source passes 1,624 deterministic Swift tests, six supervisor tests,
15 Node tests and the 34-tool MCP smoke. Release-security and live-gate fixtures also pass.

The latest full live run passed 13 cases, failed the two-session TextEdit Accessibility case,
and skipped the final two cases after the failure. Its follow-up MCP matrix was not run. No
WindowServer restart or panic was observed, but the failure latch remains set. These results do
not complete live qualification. Earlier complete passes belong to an earlier source commit.
See [the September 26 evidence](validation/2026-09-26-display-containment.md).

The intermittent TextEdit Accessibility blackout and Apple's underlying display-driver defect
remain unresolved. The containment changes do not guarantee prevention of kernel panics.

No signed, notarized, stapled, or live-qualified binary is attached to this draft. Public
publication requires the gates in docs/RELEASE_POLICY.md, including protected approval,
current live evidence, exact-candidate verification, and release-owner GO.

Apple Silicon only; macOS 14 or later subject to runtime checks and release qualification.
SpaceO isolates attention, not security: applications retain the logged-in user's access.
