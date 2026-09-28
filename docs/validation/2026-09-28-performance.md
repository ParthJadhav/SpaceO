# Performance instrumentation and first measurements — 2026-09-28

Scope: working-tree changes based on `2573ead`, Apple Silicon, macOS 27.2, Xcode 26.6.
No release qualification or whole-application speedup is claimed.

## Oversized settings regression

Release `SpaceOPerformance`, 100 reads per process, five alternating old/new runs. Fixture:
private synthetic sparse 64 MiB invalid JSON file. Both implementations reject the file; the
legacy path reads it in full first, while production now checks and enforces a 16 KiB bound.
Medians across runs:

| Metric | Legacy | Bounded |
| --- | ---: | ---: |
| p50 read latency | 3.2981 ms | 0.0091 ms |
| p95 read latency | 3.6570 ms | 0.0103 ms |
| Process CPU per 100 reads | 332.306 ms | 0.941 ms |
| Lifetime peak RSS | 73.84 MiB | 9.78 MiB |
| End physical footprint | 66.75 MiB | 2.63 MiB |

These numbers describe malformed large settings only. Normal settings are small and cached for
five seconds. Peak includes process startup and warm-up. End footprint may include allocator
caches. Raw JSON is retained privately under `.artifacts/performance-2026-09-28/`.

## Synthetic hot-path baseline

Single optimized run after one warm-up, synthetic 1920×1080 image, no desktop or application
access. These are baselines for future comparisons, not before/after improvements:

| Workload | Iterations | p50 | p95 |
| --- | ---: | ---: | ---: |
| Full-frame hash | 100 | 2.5122 ms | 2.6172 ms |
| PNG encode | 30 | 23.8748 ms | 24.2956 ms |
| 100 events plus replay | 1000 | 0.0208 ms | 0.0227 ms |
| Process metric sample | 1000 | 0.0007 ms | 0.0008 ms |

## Live evidence and limits

The user explicitly reserved the Mac. Readiness was ready, capture/input permissions available,
and no SpaceO/orphan displays existed before the run. The existing daemon did not match this
checkout, so it was left alone and measurements used the built XCTest process.

The supervised focused `testCaptureOfAgentScreenIsActuallyRendered` passed: one executed test,
zero skips/failures, 92.490 seconds including the mandatory 90-second pacing interval. It verified
window, tile and clamped-region captures. Postflight confirmed ready display safety, identical
physical display topology and no remaining SpaceO/orphan displays. This used a debug XCTest
bundle: the attempted release test build could not import the release Viewer module for
`@testable` tests, before any live test ran. Its build failure is not a live-test failure or a
performance measurement. Release synthetic benchmarks above remain independent of that build.

Viewer now avoids issuing a layer-clear transaction when it already retains no frame. This
removes redundant compositor submissions by construction; it does not establish a measured GPU
percentage improvement. Frame, idle, coalescing and submission signposts support future Viewer
profiling without retaining pixels. The focused capture case does not exercise Viewer rendering,
animated-content throughput, concurrent sessions or long-running leaks.

A Metal System Trace attached to XCTest grew to about 9 GiB during finalization and over 4 GiB
resident memory. Stopping the profiler after the test had exited produced a readable, compacted
trace (about 1.1 GiB). The exported SpaceO signposts verify all three screenshot intervals:
75.13 ms, 29.82 ms and 32.95 ms under profiling. The trace contains 7,176 WindowServer GPU active
interval rows but none attributed to XCTest. These are shared compositor records, not exclusive
SpaceO costs; do not sum overlapping intervals or label absence of XCTest rows as zero GPU work.
There is no before/after GPU percentage. Future captures should start after pacing and retain
only a five-second window to bound profiler overhead.

The virtual pointer also now provides an explicit shadow path matching its circle plus half of
the stroke width. Its shape never changes, so Core Animation can use that outline rather than
deriving the shadow from composited alpha. This follows Apple's
[shadow-path performance guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ImprovingAnimationPerformance/ImprovingAnimationPerformance.html).
The focused capture case does not exercise the human-control pointer; GPU savings from this
change remain unquantified.

See [PERFORMANCE.md](../PERFORMANCE.md) for repeatable workloads, Instruments setup, metric
semantics and the remaining live workload matrix. Full live release gates were not run.

## Deterministic verification

`make verify-release` passed after the final source change: 1,626 Swift tests, supporting shell/
Python/Node checks, and the 34-tool MCP smoke check. `git diff --check` passed. The focused live
case above is additional capture evidence, not full release qualification.

The ad-hoc Viewer bundle built successfully and passed `codesign --verify --deep --strict`.
