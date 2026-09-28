# SpaceO 1.0.3

> **Retained draft; public release withdrawn.** Qualification remains on hold for Viewer pointer
> evidence and the Chromium soak diagnostic. Version 1.0.1 remains latest stable. The text below
> records the candidate scope; it does not indicate current public availability.

This release supersedes the unpublished 1.0.2 candidate and includes corrected, version-checked
installation instructions. This performance maintenance release reduces unnecessary Viewer capture work and bounds
logging-settings memory use. Native apps and Chromium browsers on Apple Silicon remain the
supported scope; managed Electron application launches remain unsupported.

- Stop capture when no console or Mini Monitor consumes frames; resume when a surface returns.
  A remaining Mini Monitor keeps the shared stream running.
- Bound logging-settings reads before allocation and reject special files.
- Avoid redundant empty-layer transactions and provide a fixed virtual-pointer shadow path.
- Add opt-in CPU, memory and frame telemetry, Instruments signposts, and supervised profiling tools.
- Distinguish unavailable and duplicate Accessibility window identities without accepting
  incomplete window lists.

A short matched hidden-view comparison measured Viewer CPU at 2.00% versus 0.94% of one core.
The five-minute daemon workload passed 400 captures with bounded sampled memory. These are
workload-specific results, not whole-app or GPU percentage improvements.

Use Viewer on a physical display while the controlled app runs on a SpaceO virtual display.
Hosting Viewer on a virtual display remains unsupported. A synthetic Chrome animation workload
did not produce changing captured pixels; its cause remains unresolved. An intermittent Chrome
Accessibility identity failure also remains under investigation; discovery continues to fail
closed. See [performance evidence](https://github.com/ParthJadhav/SpaceO/blob/v1.0.3/docs/validation/2026-09-28-performance-followup.md).

Download the DMG, signed checksum and signed candidate record, then follow
[verification and installation instructions](https://github.com/ParthJadhav/SpaceO/blob/v1.0.3/docs/INSTALL.md). The previous 1.0.1 release remains
available for rollback. Qualification and publication status are tracked in the
[release record](https://github.com/ParthJadhav/SpaceO/blob/main/docs/validation/2026-09-28-release-1.0.3.md).
