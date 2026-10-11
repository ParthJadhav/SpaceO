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
apps, or touching the clipboard. Full post-fix verification is pending.
