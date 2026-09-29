# Measuring SpaceO performance

Use optimized builds and compare the same workload, dimensions, frame rate, OS, and hardware.
Keep CPU time, wall latency, memory, GPU work, and correctness separate. A smaller framebuffer or
lower frame rate is a quality tradeoff, not automatically a performance improvement.

## Synthetic benchmarks (no desktop access)

```sh
swift build -c release --product SpaceOPerformance
.build/release/SpaceOPerformance hash 100
.build/release/SpaceOPerformance png 30
.build/release/SpaceOPerformance events 1000
.build/release/SpaceOPerformance metrics 1000
.build/release/SpaceOPerformance settings-legacy 100
.build/release/SpaceOPerformance settings 100
```

Each invocation emits one JSON record with p50/p95 wall latency, throughput, process user/system
CPU time, RSS, physical footprint, and lifetime peak RSS. Run each workload in a fresh process;
repeat at least five times, alternating old/new order. Record the commit, dirty diff, build
configuration and machine/OS privately beside results. Avoid competing builds and profilers.
There are no timing pass/fail thresholds: noisy hosts must not turn correctness CI flaky.

Hash and PNG use a synthetic 1920×1080 image; events performs 100 publications and one replay per
iteration. Metrics measures sampling overhead. Settings compares the old full-file read with the
production bounded reader on an invalid, sparse 64 MiB file. This is an oversized-file regression
benchmark, not a claim about ordinary settings or whole-app speed. Scratch files are private and
removed. Workload count is bounded to 1000. Setup and one warm-up are excluded from latency/CPU
measurement; peak RSS includes them. End-of-run RSS cannot detect every transient allocation or
prove the absence of a leak. Use Allocations for lifetime analysis.

## CPU, allocation and GPU attribution

The `com.spaceo.performance` subsystem emits payload-free Instruments signposts:

| Name | Meaning |
| --- | --- |
| `Daemon.Request` | Handler and request logging; excludes socket encoding/write |
| `Capture.Screenshot` | ScreenCaptureKit screenshot call, including errors/cancellation |
| `Capture.PNG` | PNG encoding, including output budget checks |
| `Capture.Hash` | Pixel materialization and hash |
| `Viewer.Frame` / `Viewer.Idle` | Complete or idle capture callback |
| `Viewer.FrameCoalesced` | Pending frame replaced while the main actor is busy |
| `Viewer.SubmitSurface` | CPU-side zero-copy layer submission |

Use **Time Profiler** with **os_signpost**, **Allocations**, and **Metal System Trace** in separate
runs, attaching to the exact candidate PID. Signposts contain no session IDs, image pixels,
Accessibility content, typed text, paths or credentials. Apple documents the interval semantics
in [OSSignposter](https://developer.apple.com/documentation/os/ossignposter).

GPU completion, GPU busy time, bandwidth and compositor cost require the GPU/Metal timeline.
A layer submission's CPU duration is **not GPU time**, and a successful capture is not proof of
physical presentation. Core Animation and ScreenCaptureKit may bill work to WindowServer;
process-local CPU/memory counters omit that work. GPU memory on unified-memory Macs overlaps
system accounting: do not add it to RSS and call the result total memory. If Instruments cannot
collect a counter, report it as unavailable rather than zero. Retain raw traces privately; they
can contain system metadata even when SpaceO's own signposts do not.

Start GPU recordings immediately before the workload, after any live-test pacing interval.
Keep a five-second recording window initially: even process-attached Metal traces can collect
substantial system-wide driver data. Bound disk/memory use and cancel an oversized profiler;
never terminate a live display owner to stop a trace.

Example (replace the PID; never launch Viewer without `--background`):

```sh
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
  --attach PID --time-limit 30s --output /private/path/cpu.trace
xcrun xctrace record --template 'Metal System Trace' \
  --attach PID --time-limit 5s --window 5s --output /private/path/gpu.trace
```

## Live workload matrix

Follow [LIVE_TESTS.md](LIVE_TESTS.md) and [DISPLAY_SAFETY.md](DISPLAY_SAFETY.md) first. A reserved
host, explicit opt-in, pre/post topology, compatible permissions, and the supervised wrapper are
required. Never repeat a failed live run automatically. Confirm binary provenance: the daemon
already running may differ from the newly built CLI.

Measure idle daemon; one static session; capture at 1× and 2×; repeated PNG/hash; Viewer static
and animated content; Mini Monitor; multiple subscribers; and teardown/idle recovery. Record
CPU ms/action and sustained CPU, p50/p95/p99 latency, frame/idle/submission counts, GPU busy time
and durations, physical footprint/peak allocations, outstanding surfaces, wakeups, and cleanup.
Compare throughput at equal quality, and verify isolation and dropped/stale frames alongside
resource reductions. Long-running retained-memory behavior needs a soak, not a one-shot capture.

Start with the focused capture check:

```sh
SPACEO_LIVE_TESTS=1 scripts/test.sh live --case=testCaptureOfAgentScreenIsActuallyRendered
```

For daemon workloads use existing `SPACEO_LOG_METRICS=1` or explicit diagnostic metrics and
`scripts/metrics-report.mjs`. Request CPU deltas are process-wide and overlap with concurrent
requests; they cannot be summed as exclusive per-command costs. Full release qualification still
requires both complete live gates; a focused performance run does not replace them.

## Bounded process sampling and Viewer health

Compile the read-only sampler and validate its CPU units against `getrusage`:

```sh
swiftc -O scripts/process-resources.swift -o .build/process-resources
.build/process-resources --self-test
.build/process-resources PID 120 1 > /private/path/resources.jsonl
```

It records CPU, RSS, physical footprint, wakeups and page-ins, checks process identity on every
sample, and refuses runs exceeding 600 samples or 30 minutes. libproc CPU counters use Mach
absolute ticks; the sampler applies the host timebase rather than assuming nanoseconds.

Launch the built Viewer with `SPACEO_VIEWER_METRICS_FILE=/private/new-file.jsonl` and
`--background` to opt into one-second health samples for at most ten minutes. The file must not
exist; it is created owner-only. Samples include permission state, visible/unoccluded window
counts, counts hosted on physical/SpaceO/unknown displays, frame sinks, FPS and sample age,
plus process CPU/memory. No pixels, window titles,
session IDs or input are recorded. A bounded mailbox coalesces writes when storage is slow;
sequence gaps indicate lost telemetry. Window visibility alone does not establish frame delivery.

After the reserved-host prerequisites above and successful builds:

```sh
SPACEO_LIVE_TESTS=1 python3 scripts/performance-live.py /private/new-report-directory
python3 scripts/performance-summary.py /private/new-report-directory
python3 Tests/PerformanceReportTests.py
```

The entry point invokes the existing external supervisor with a 650-second deadline. It starts
a matching candidate daemon on a private socket, validates 16 subscriber handshakes, exercises
1/4/8-client reads, four logical sessions on one display, 1×/2× captures, 30 logical session
create/destroy cycles, and 360 repeated captures. Chrome serves only a generated loopback fixture.
The Viewer starts while only the populated session exists; physical-display placement and
animated-phase FPS are required. Set `SPACEO_PERF_VIEWER_ONLY=1` for a focused static/animated/
scrolling diagnostic that skips subscriber/load/capture/churn work. After inspecting a failed
phase, `SPACEO_PERF_VIEWER_MOTION=animated` or `scrolling` can select one motion path; the default
`both` runs both. Every selection keeps the static baseline and requires changing capture pixels
and sustained Viewer frames for its motion phase. Provenance and summary record the requested
Viewer modes; a focused pass does not cover the omitted mode. The selector is refused for
daemon-only and native-probe workloads. This still creates a virtual
display and launches Chrome and Viewer; all live authorization and cleanup rules still apply.
Existing virtual displays cause preflight refusal. The run retains private logs and reports,
uses controller leases only in memory, and verifies teardown/topology. On unverified cleanup,
the supervisor suspends the process group for operator recovery; do not retry or resume it
without that decision. The `--supervised-worker` argument is internal to this entry point.

This is an experimental performance harness, not release qualification. Its corrected Viewer
Chrome-animation workload has not passed; the native Metal diagnostic has passed. See the
[follow-up evidence and stopped soak](validation/2026-09-28-performance-followup.md).

The browser fixture emits a bounded loopback heartbeat with only mode, document visibility and
animation-frame count. `fixtureEvidence` summarizes this separately from Viewer frame delivery;
running JavaScript is not proof that changing pixels reached the captured region. Validate the
fixture without desktop access with `python3 Tests/PerformanceFixtureTests.py`.

For a separately authorized native rendering diagnostic, compile the existing live-only probe:

```sh
swiftc -parse-as-library -target arm64-apple-macos14.0 \
  Tests/LiveFixtures/TranscriptProbe.swift -o .build/performance-metal-probe
SPACEO_LIVE_TESTS=1 SPACEO_PERF_NATIVE_PROBE=1 python3 scripts/performance-live.py /private/new-native-report
```

This mode runs the synthetic resizable Metal window for 15 seconds on the explicitly created agent
display, without Chrome. It records probe CPU/memory and GPU completions, and requires Viewer
frames on a physical display. It adopts the probe into the session through the leased API;
display coordinates alone do not establish managed-Space placement. The probe never owns the virtual display. It has no physical-display
fallback and never activates its window. GPU completions alone do not establish captured freshness
or physical presentation. A completed native run verified changing in-memory capture pixels,
GPU completions, Viewer frames and topology restoration.

`SPACEO_PERF_DAEMON_ONLY=1` runs the load, subscriber, session-churn and 360-capture soak phases
without Viewer. Its results establish daemon/capture behavior only; they cannot substitute for
the independent Viewer rendering checks. Do not combine this flag with native-probe mode.

For a native capture-demand comparison, also set `SPACEO_VIEWER_PERF_LIFECYCLE=1`: the opt-in
Viewer telemetry opens Settings at second six and returns to the canvas at second twelve.
`SPACEO_VIEWER_PERF_MINI=1` additionally opens Mini Monitor at second three and closes it at
second ten. Check actual `settingsVisible`, `frameSinks` and `streamRunning` samples before
comparing intervals; a route change invalidates a nominally hidden interval. The first/last
consumer now starts/stops capture, while Mini Monitor can keep the shared stream alive.
`Viewer.StopCapture` measures teardown wall time; `Viewer.StopCaptureFailed` records failure
without content. Neither is a GPU utilization measurement.

`SPACEO_PERF_VIEWER_BINARY` selects an explicitly retained baseline Viewer executable for A/B
testing; the harness records its SHA-256 digest. Keep the daemon, fixture and other conditions
matched. Short CPU intervals are workload-specific observations, not whole-app speedup claims.
