# Atomic host-health expiry

A full deterministic run on Xcode 27 exposed a scheduling-dependent false health refusal in
`testFreshQuietAssessmentWakesSettlingWaiter`. The expiry reader captured its clock before taking
the state lock. A concurrent producer could publish a newer observation before that reader
compared timestamps, making the older captured time appear to move backwards.

The fix reads the monotonic clock under the same state lock used for the expiry comparison.
Three-second in-flight deadlines, ten-second freshness, actual clock reversal, unknown evidence,
sticky failures, and diagnostic lookback policy remain unchanged.

A synthetic barrier-controlled regression pauses the reader's clock snapshot while a producer
attempts to publish the next quiet assessment. The original implementation fails its ready and
settled assertions. The fixed implementation serializes the snapshot and update. The test uses
inert observations and bounded waits, without querying WindowServer, creating displays, driving
apps, or touching the clipboard.

The regression failed both health assertions with the original implementation and passed after
the fix. All 36 focused health/settling tests then passed on Xcode 27.0 / Swift 6.4.
The independent patch at `eae511c` passed local `make verify-release`: 1811 deterministic Swift
tests, 15 Node tests, supporting Python/shell checks, and the 35-tool MCP smoke check.

Combined with the independent janitor-admission fix at
`a4e3c3e076eba121aa25a75cb9f90690c5547e43`, local `make verify-release` passed all 1812
deterministic Swift tests and the remaining checks. That revision also passed
[CI on Xcode 26.3 / Swift 6.2](https://github.com/jimmyxu-code/SpaceO/actions/runs/38114677652),
including release build, Viewer bundle/signature verification, MCP smoke, and privacy checks.
`git diff --check` passed. No live display/input qualification or underlying macOS defect fix is
claimed.
