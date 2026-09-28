# Candidate performance follow-up — 2026-09-28

Working-tree candidate on the same reserved Apple Silicon host as the first performance report.
The old default daemon had no sessions and was stopped normally. Tests used a private socket
and matching optimized candidate daemon; the real ad-hoc Viewer launched with `--background`.
Private artifacts are retained under `.artifacts/performance-followup/`.

## Completed baseline

The first supervised workload completed 1,033 operations in 206.96 seconds, with 30 logical
session create/destroy cycles, four sessions sharing one display, and 160 in-memory screenshots
(including 20 each at 1× and 2×). Physical display topology was restored, with no virtual displays.

| Metric | Observed |
| --- | ---: |
| Idle daemon CPU, one core = 100% | 0.010% |
| Idle daemon footprint | 19.78 MiB |
| Capture latency p50 / p95 | 96.31 / 121.98 ms |
| Capture soak daemon CPU | 2.514% |
| Capture soak footprint start / end | 22.55 / 21.05 MiB |
| Capture soak footprint peak | 22.89 MiB |
| Post-teardown idle footprint | 21.13 MiB |

These are single-run baselines, not measured before/after improvements or proof of no leaks.
The soak covers roughly 70 seconds of process samples. Baseline sampler offsets were recovered
from file birth times because that initial harness did not persist monotonic start offsets.
The harness now saves those offsets explicitly. Subscriber connections were opened, but the
initial harness did not validate their admission replies; no 16-subscriber capacity claim follows.

## Viewer evidence gap and failed second run

The initial harness created four sessions before launching Viewer. Its newest-session default
selected an empty tile instead of the populated Chrome session. Therefore its animated/scrolling
Viewer CPU samples and short GPU trace are not valid evidence of those rendering workloads.
No GPU savings are claimed. The fixture now starts Viewer with only the populated session,
adds other sessions afterward, and requires actual FPS during animation. This correction has
not been live-verified; the failed run was not retried.

The second run added bounded Viewer health telemetry. During its capture soak, Chrome
Accessibility discovery reported an unavailable or repeated window identity. Screenshot returned
`operation_failed`; session teardown returned `teardown_incomplete`. The supervisor correctly
suspended the retained owner rather than killing it and detaching the display. This is a failed
live run, even though prior operations succeeded. Root cause remains unresolved; the existing
fail-closed identity validation was preserved.

The operator explicitly approved controlled recovery. Only the retained daemon was resumed;
`daemon.stop` with operator scope succeeded normally. Doctor then reported ready safety,
physical display online/active unchanged, and zero virtual/orphan displays. The non-owning
suspended harness/sampler were then removed and the default candidate daemon restarted.
No journal reset, SIP/TCC change or forced display-owner termination was used.

## Remaining work

Resolve the Chrome discovery failure before another live qualification attempt. Confirm the
corrected Viewer fixture produces frames, then collect matched CPU/GPU before/after traces;
extend retained-memory duration and cover Mini Monitor and human-control pointer rendering.
The current evidence does not establish whole-app CPU/GPU savings or long-duration stability.

## Deterministic checks

The process sampler's CPU calibration passed against `getrusage`; four report tests passed,
covering phase boundaries, CPU/footprint/percentiles, failed-run propagation, empty health data,
unknown roles and oversized input. Viewer was built ad-hoc with signature verification.
`make verify-release` passed: 1,626 Swift tests, supporting checks and the 34-tool MCP smoke
check. `git diff --check` and strict/deep Viewer signature verification passed. Focused
performance runs never replace full live and computer-use release qualification.

## Explicitly authorized fresh attempt

After recovery, the operator authorized one fresh supervised attempt. The corrected harness
validated subscriber admission and started Viewer with only the populated session. It received
initial frames (maximum reported 1.5 FPS), then no frames during the animated phase. Health
reported a running stream, a frame sink and an unoccluded window throughout 39 samples, while
sample age increased. The stricter rendering check failed; the run did not reach capture scales
or the extended 360-capture soak. This is evidence of missing frame delivery, not GPU efficiency.

Cleanup completed normally with verified topology restoration and zero virtual/orphan displays.
The default candidate daemon was restarted. A five-second Metal trace was retained privately in
`fresh/viewer-gpu.trace`. No automatic rerun followed. The earlier combined AX identity error
has now been split into unavailable versus repeated cases, with deterministic assertions for
both; neither branch accepts a partial result. The root cause of the previous Chrome error is
still unknown.

Viewer health now also counts windows on physical, SpaceO and unknown displays, without
recording IDs or titles. This diagnostic has been built but not live-verified; it addresses an
important evidence gap because Viewer-on-SpaceO streaming is an existing unsupported topology.
A future live attempt requires fresh authorization after this failed run.

## Authorized physical-display diagnostic

The operator subsequently authorized one focused Viewer diagnostic. Its health log confirmed
two visible windows on physical displays and zero on SpaceO/unknown displays. Initial frames
arrived, but the animated phase again had zero FPS and rising sample age. The rendering check
failed before scrolling. Cleanup completed normally, doctor confirmed ready safety and no
virtual/orphan displays, and the default candidate daemon was restored. No failed run was retried
without a separate operator decision.

Physical placement is now established; the source of missing updates is not. The fixture did
not measure Chrome's own animation activity, so these results cannot distinguish capture
staleness from browser background rendering suppression. The harness now records a bounded,
content-free loopback heartbeat (fixture mode, document visibility and animation-frame count)
to establish that distinction in a future authorized attempt. This heartbeat is not yet live
verified. A late external screenshot probe was refused and yielded no pixel evidence.

Final deterministic release verification passed again after the identity diagnostic and Viewer
placement telemetry changes (1,626 Swift tests and supporting checks). The final ad-hoc Viewer
bundle passed strict signature verification. The heartbeat addition passed Python compilation
and diff checks; it does not establish that the live rendering workload passes.

## Authorized heartbeat diagnostic

The next separately authorized run again failed Viewer animation delivery and cleaned up normally.
Doctor confirmed ready safety and zero virtual/orphan displays; the default candidate daemon was
restored. Chrome reported `visible` in all 20 static and 20 animated heartbeat samples. Static
animation callbacks advanced from 61 to 1,201, while animated callbacks advanced from 4 to 23.
Chrome's event loop therefore continued, at a reduced callback cadence during animation. These
counts do not prove that changing pixels reached the captured region, and they do not establish
a ScreenCaptureKit defect by themselves.

Two offline JavaScript-fixture tests and five report tests passed. The existing Metal presentation
fixture compiled successfully; a supervised harness mode is prepared to isolate Viewer delivery
from Chromium. It remains unverified pending a fresh operator decision.

## First authorized Metal diagnostic

The operator authorized the native probe. Viewer received no sustained new frames, and the run
failed its check. Cleanup completed normally with topology restored. A short GPU trace was
retained privately. This attempt has a fixture limitation: the probe was positioned on the
agent display but not adopted into the session's managed Space. Also, the failed Viewer check
terminated the probe before its final GPU report was emitted. It cannot establish a capture
defect or GPU efficiency.

The harness now adopts the probe through the normal leased session API and waits for its bounded
GPU completion report before failing Viewer delivery. These corrections are pending live
verification at that point; subsequent continuing authorization and results are recorded below.
No production isolation policy was loosened.

## Continuing authorization and corrected native evidence

The owner granted continuing authorization for performance tests and controlled recovery,
explicitly asking not to repeat permission prompts. Subsequent runs still kept lifecycle gates,
inspected failures before proceeding, and verified cleanup.

Native harness corrections exposed fixture problems rather than production failures: the
borderless cover window refused tile resizing; then the placement check queried `session.list`
without its controller lease and received intentionally redacted window details. The initial
readiness signal also preceded window creation, so it was moved after window creation and
adoption now requires a window. Readiness and placement are distinct from merely knowing a PID.
None of these failed harness attempts is counted as a passing live workload. Their cleanups
restored topology. The earlier suspicion of wrong managed-Space placement was not established.

The corrected `native5` workload passed with verified on-stage placement, changing in-memory
capture pixels, physical-display Viewer hosting, GPU completion evidence, and restored topology.
It completed in 59.31 seconds including idle and cleanup phases. The 15-second native fixture
reported 822 submissions, 822 GPU completions, zero GPU failures and 822 presentation callbacks.
Viewer health recorded a maximum 27.5 FPS. Sixteen process samples during the native phase showed
Viewer CPU at 4.015% of one core and footprint 55.95 → 55.75 MiB (peak 56.13 MiB). The generating
probe separately consumed 6.304% CPU and about 97 MiB; these costs are not attributed to Viewer.
This is a baseline, not a before/after speedup or long-duration memory result.

A short GPU trace from `native4` captured actual Viewer work despite that run's later harness
placement-check failure: 152 frame events, 152 matched surface-submission intervals and two idle
events. Surface submission wall time was p50 0.1143 ms, p95 0.2618 ms, totaling 18.74 ms across
those intervals. This is CPU-side wall time, not GPU duration. The GPU table contains 6,440
system-wide Active intervals; attribution and overlapping channels prevent calling their sum
exclusive SpaceO utilization. Raw traces and derived timing summaries remain private. The
subsequent successful native run above supplies independent rendering/cleanup evidence.

A 360-capture daemon-only soak is tracked separately from the unresolved Chrome animation case.
Read-only WindowServer process-resource sampling was attempted but unavailable; it is not
reported as zero and no privilege or host-security change was made to obtain it.

## Completed daemon load and longer bounded soak

The separate `soak360` workload passed in 300.82 seconds. It validated admission of 16 event
subscribers, ran 1/4/8-client read batches, used four logical sessions on one display, completed
30 logical create/destroy cycles and 400 captures (40 scale checks plus 360 soak captures).
All captures succeeded; topology was restored with no virtual/orphan displays. The matching
candidate default daemon was restarted after postflight.

| Metric | Observed |
| --- | ---: |
| Idle daemon CPU | 0.014% of one core |
| Idle daemon physical footprint | 20.20 MiB |
| Capture p50 / p95 wall latency | 123.52 / 150.37 ms |
| Capture p99 wall latency | 157.29 ms |
| Soak daemon CPU | 2.177% of one core |
| Soak sampled footprint start / end | 30.34 / 22.56 MiB |
| Soak sampled footprint peak | 30.36 MiB |
| Post-teardown idle footprint | 22.06 MiB |
| Ping p50 / p95 under mixed load | 0.548 / 1.180 ms |

The soak contains 223 one-second process samples after phase-boundary exclusion. This supports
bounded retained memory over this run, not a general absence of leaks. The fixture's static page
continued its heartbeat callbacks, so its browser work is not part of daemon CPU attribution.
This is not directly comparable to the earlier capture latency baseline: the fixture telemetry
and workload mix differ. There is no Viewer/GPU claim from the daemon-only run.

The earlier `make verify-release` passed with 1,626 Swift tests, supporting checks and the 34-tool MCP
smoke check. The two JavaScript-fixture tests, five report tests, process-counter calibration,
strict/deep Viewer signature verification and `git diff --check` passed. The native fixture
compiled with the explicit macOS 14 deployment target. The p99 report addition passed the report
tests after the release check. No full live release qualification or GPU percentage improvement
is claimed.

## Capture follows visible consumers

Viewer previously continued capturing roughly 25–27 frames per second while Settings replaced
the canvas and no frame sink remained. Capture now retires after the last sink disappears and
resumes through the existing serialized teardown/start barrier when a sink returns. Deferred
reconciliation coalesces same-update surface replacement; a remaining Mini Monitor sink keeps
capture running. Deterministic coverage includes a late start completing after consumer removal.

Supervised `no-consumer-before3` and `no-consumer-after3` both passed native rendering, GPU
completion and cleanup checks. During samples 7–11, both stayed in Settings with zero sinks.
The old Viewer kept capturing at 25–26.5 FPS; the candidate stopped capture throughout this
interval. Viewer CPU across those four seconds fell from 2.005% to 0.940% of one core (53.1%
lower in this short interval). On returning to the canvas, the candidate reached 24.5 FPS.
This is a scoped CPU observation; it does not establish an overall speedup, memory reduction,
or quantitative GPU utilization reduction.

`no-consumer-before2` passed rendering/cleanup but unexpectedly left Settings at sample 9,
invalidating its intended hidden-view CPU comparison. It is excluded. The sidebar selection
binding can close Settings, but telemetry does not establish the trigger in that run. The
initial `no-consumer-after` run also failed its aggregate checkpoint because it sampled frame
health too soon after reopening; the harness now waits for the bounded probe completion before
checking final health. Failed runs are not counted as passing evidence.

The separate `consumer-mini` run passed: with Settings open and Mini Monitor as the sole sink,
capture continued at 24–26 FPS. Closing Mini Monitor reduced sinks to zero and stopped capture;
returning to the canvas resumed frames. All these completed runs restored physical-only topology.
The immutable old bundle, executable digests and raw telemetry remain in ignored private
artifacts. No production display-placement or isolation policy changed.

Final verification after the consumer change: `make verify-release` passed with 1,628 Swift
tests and the 34-tool MCP smoke check; the five report tests, two fixture tests, strict/deep
Viewer signature check and `git diff --check` passed. The matching candidate daemon was
restarted normally. Postflight reported ready host/display safety, one active physical display,
and zero SpaceO or orphan displays. No installation, publication or full release qualification
was performed.
