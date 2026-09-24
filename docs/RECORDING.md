# Action recording

Create a session with `--record actions` to save action receipts or `--record actions+frames`
to add before/after images. MCP accepts the same values in `spaceo_session_create.record`.
Recording is off by default. Files live under
`~/Library/Application Support/SpaceO/recordings/<session-and-start-time>/`.
Use `spaceo report <recording-directory>` to render the timeline.

Receipts omit typed text and key-chord payloads; they retain UTF-8 lengths and structured
outcomes. Opt-in images contain visible screen content and may include typed text. Recordings
are not automatically included in support bundles.

Images capture the session's tile with the screenshot path's foreign-window exclusions. They
are requested at thumbnail resolution (at most 480 pixels on either side), encoded with a
1 MiB limit per PNG, and omit the cursor. No full-display image is captured and cropped later.
An action can add two capture waits, each capped at two seconds. If a native capture ignores
cancellation, subsequent frame requests return `capture_busy` until it finishes; its late
result is discarded. Receipts remain available even when frames are unavailable.

Before each frame, foreign-window exclusion discovery has a separate shared budget across
neighbours: 256 window entries, 2048 AX calls, 2 MiB accounted data, and two seconds. It skips
titles and refuses incomplete exclusions. Uncooperative native AX calls can exceed their
messaging timeout; these budgets do not establish a hard end-to-end action latency bound.

Every individual recorded action has before/after frame status in frame mode:

- `captured`: the referenced PNG was written.
- `capture_unavailable`: capture, isolation checks, exclusion discovery, or encoding failed.
- `capture_timeout` / `capture_busy`: the capture deadline or pending-work limit prevented evidence.
- `stale_geometry`: the session tile or display changed during capture; pixels were discarded.
- `cancelled`: the request was cancelled.
- `capacity_exhausted`: images were omitted to preserve room for the receipt.
- `not_attempted`: the command was rejected before the capture boundary.
- `step_evidence`: a batch summary; use its individual step receipts for images.

Older recordings may have no status fields. A blank old field does not prove capture occurred.
Foreign or skipped batch actions do not create receipts or trigger frame capture. Nested launch
commands have their own receipts. Capture/omission warnings reach the agent response, including
batch responses. Frame availability does not prove delivery or an application postcondition.

The recording capacity remains 500 MiB by default, shared across active recordings under the
same root. Receipts take precedence over optional frames. A writer failure stops recording,
clears its active mode, and warns the owner without changing the command outcome; avoid
repeating an action solely because its evidence is missing.

Deterministic tests inject synthetic images and delayed/failing providers. Native display,
ScreenCaptureKit, privacy-permission, and image-content qualification still requires the idle-host
procedure in `LIVE_TESTS.md`; deterministic tests do not establish native capture compatibility.
