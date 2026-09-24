# SpaceO 1.1.1

Status: draft; public release and signed-artifact qualification are pending.

This maintenance release improves agent usability, bounds background work and memory, and
simplifies the Viewer controls. It preserves explicit partial/unknown isolation results and
controller ownership rules.

## Changes

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

Deterministic validation is recorded in docs/validation/2026-09-23-release-preparation.md.
No signed, notarized, stapled, or live-qualified binary is attached to this draft. Public
publication requires the gates in docs/RELEASE_POLICY.md, including protected approval,
current live evidence, exact-candidate verification, and release-owner GO.

Apple Silicon only; macOS 14 or later subject to runtime checks and release qualification.
SpaceO isolates attention, not security: applications retain the logged-in user's access.
