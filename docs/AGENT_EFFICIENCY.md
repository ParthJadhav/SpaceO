# Agent usability and efficiency work log

Goal: improve agent usability, latency, and memory consumption without weakening isolation,
lease checks, truthful action receipts, or bounded public inputs. Record concrete inefficiencies
here as they are found, including the fix and evidence. Existing unrelated Viewer changes are
preserved.

## 2026-09-22 — Incremental observations

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-001 | Every event poll materialized the entire event ring, filtered it, then copied a page. Even a caught-up cursor scanned up to 4096 events by default. | Derive the unread offset from contiguous sequence numbers and copy only the requested page. O(page size) work and temporary storage; caught-up reads allocate no event array storage. | Implemented; targeted tests pass. |
| AE-002 | Screen diffs called controls unchanged when their indices changed, so inserting an earlier control could leave an agent targeting the wrong index. | Include index/actionability changes in `changed`, render the current index, and identify the previous index. Update the agent playbook. | Implemented; targeted tests pass. |
| AE-003 | A `since` snapshot from another window was accepted as a diff base. | Require the history entry's window to match; otherwise use the existing `diff_base_missing` full-read fallback. | Implemented; targeted tests pass. |
| AE-004 | Duplicate diff keys could collide with labels ending in a duplicate suffix, trapping dictionary construction. Finite but extreme geometry could trap integer conversion. | Suffix every occurrence, including the first; use checked integer formatting with a floating-point fallback for extreme snapped coordinates. | Implemented; targeted tests pass. |
| AE-005 | Diff generation constructed an extra current-key set and a filtered array solely to find removals. | Remove matched entries from the base lookup and render remaining entries in original order. | Implemented; targeted tests pass. |
| AE-006 | History copied every node array and capped entries/nodes but not aggregate retained string/action payload. | Share ordinary immutable arrays, account for node/action storage plus UTF-8 payloads, cap at 8 MiB/session, evict oldest entries, and omit entries that cannot fit. Byte accounting is logical payload, not an RSS guarantee. | Implemented; targeted tests pass. |
| AE-007 | Window/process removal paths do not call the history's `forget`, leaving closed-window history retained until capacity eviction or session destruction. | Prune history when a known window disappears or changes owner, preserving it across geometry updates and temporary Accessibility blackouts. | Implemented; targeted tests pass. |
| AE-008 | MCP's bounded stdin reader rescans the full accumulated line for each chunk and allocates a new 64 KiB scratch array per read. | Track the scanned prefix, reuse scratch storage within a message, and release oversized chunks while discarding through the next newline. Preserve UTF-8 checks, EOF behavior and recovery. | Implemented; targeted tests pass. |

Validation is deterministic and uses synthetic data. No live displays, applications, input,
pasteboard changes, host installation, or release publication are needed for this pass.

### Synthetic replay benchmark

Optimized (`swiftc -O`) standalone builds of the actual `EventBus.swift` before this change
(`HEAD`) and after it, using the production `DaemonEvent` value type. Each bus held 4096 synthetic
events. Results below are the median of three repetitions of 2000 polls on this host. Both
variants produced the same checksum. These measure only the replay routine, not transport,
end-to-end command latency, live desktop behavior, or process RSS.

| Poll | Before | After |
| --- | ---: | ---: |
| Caught up | 203.571 ms | 0.084 ms |
| One unread event, limit 1 | 201.002 ms | 0.190 ms |
| Full backlog, limit 32 | 305.228 ms | 2.454 ms |

### Validation

- Initial event/diff regression pass: 37 tests passed.
- Byte-budget/playbook pass: 45 tests passed.
- Expanded framing/window-lifecycle pass: 59 tests passed.
- Full `make verify-release`: passed (optimized build, deterministic Swift tests, Viewer install checks, Node evidence tests, and MCP smoke for all 32 tools). `git diff --check`: passed. Existing compiler warnings remain; no live qualification was attempted.

## 2026-09-22 — Text and screen reads

Previous goal turn: progress (eight implemented findings, retained benchmark evidence, and a
passing full deterministic release check). Current worktree rechecked before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-009 | Native `read_text` walked and retained a full interactive snapshot, paying for actions, enabled state, geometry, and element handles before extracting text. Document values were reduced to the outline's 480-byte label, often without a truncation flag. | Stream reading-order values through a text-only traversal; fall back to accessible names only when values are empty, bound characters and allocations, stop once the requested output is known to be truncated, and preserve partial-budget reporting. | Implemented; focused and full deterministic release checks pass. |
| AE-010 | An incremental screen read rendered a full outline and immediately replaced it with the diff. Its truncation check then inspected only the delta, hiding unchanged clipped values. | Render the full outline only for ordinary reads or missing bases; inspect snapshot labels for clipping even when the rendered delta omits them. | Implemented; focused and full deterministic release checks pass. |

The new text-only walker does not query secure-field values, does not retain interactive nodes,
and visits cyclic references once. Cancellation/provider failures still propagate. Its character
limit includes separators, so multiple text nodes cannot overflow `max_chars` by one character.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-011 | The snapshot and first-text walkers did not track visited elements, so cyclic/shared AX references repeated remote calls, duplicated controls, and consumed node budgets. | Track visited elements and charge retained references to the allocation budget; skip repeated nodes before further provider queries. | Implemented; focused and full deterministic release checks pass. |
| AE-012 | A snapshot stopped at `maxDepth` without marking itself truncated, inviting agents to treat omitted descendants as absent controls. | Query the bounded child count at the depth boundary and report `depth` truncation only when children were omitted. | Implemented; focused and full deterministic release checks pass. |

Synthetic text fixture: a group containing 100 static-text nodes. A 50-character read now visits
2 nodes and makes 5 provider calls; the former snapshot path visits all 101 nodes and makes 812
calls. Regression coverage checks early termination, lower allocation accounting, full values,
Unicode/separator limits, secure fields, cyclic references, depth limits, and partial budget
stops; cancellation and rejected messaging timeouts must still fail rather than return success.
The initial run exposed an overestimated baseline-call assertion (1000 versus the observed 812);
the regression now requires at least a 100-fold call-count reduction for this fixed fixture.

AE-013: the snapshot walker inserted an actionable handle before charging its node to the
allocation budget. A partial snapshot could therefore claim more actionable elements than it
returned, retaining an invisible handle. The insertion now follows successful allocation
accounting; a constrained-budget regression requires a one-to-one correspondence between
returned actionable nodes and retained handles. Implemented; focused and full deterministic release checks pass.

Validation for the text/screen-read pass: 56 focused tests passed, followed by a passing
`make verify-release` (873 Swift tests, Viewer install transaction checks, 11 Node evidence
tests, and MCP smoke covering 32 tools). `git diff --check` passed. Tests use fake providers and
synthetic text; these results establish deterministic behavior and provider-call reductions,
not live-application latency or a release qualification.

## 2026-09-22 — Waits and batch responsiveness

Previous goal turn: progress (five additional fixes and a passing 873-test deterministic release
check). Current worktree rechecked before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-014 | Batches held the global operation gate for every step, including sleeps; 16 waits could block unrelated commands for up to 80 seconds despite a comment claiming interleaving. | Enter the gate at each step/probe boundary, release it during sleeps, pin the session generation, and recheck leases, shutdown, pause state, and requested isolation evidence before further steps. | Implemented; focused and full deterministic release checks pass. |
| AE-015 | A batch counted a wait timeout/cancellation as success and proceeded to dependent input. Plain millisecond waits also reported `met` when their requested duration exceeded the deadline. | Keep standalone timeouts as normal receipts, but treat unmet batch waits as failed steps; report a deadline-shortened pause as `timeout`. | Implemented; focused and full deterministic release checks pass. |
| AE-016 | Waits used wall-clock time, started an extra expensive probe at the deadline, and accepted late successes. The standalone path bypassed common request preflight. | Use monotonic production time, check the deadline before and after probes, preserve cancellation receipts, and apply normal preflight validation. | Implemented; focused and full deterministic release checks pass. |
| AE-017 | Element waits ignored static labels and could claim `element_gone` from a truncated tree. Each window-scoped probe also refreshed windows twice. | Match exact labels across the snapshot, require a complete read before proving absence, and refresh only once per probe path. | Implemented; focused and full deterministic release checks pass. |

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-018 | A batch could outlast its client's response window, especially with multiple long actions or waits. | Apply a shared 60-second budget before starting steps; waits consume only its remainder. Already-running bounded actions finish normally. Expiration skips remaining steps even when `stop_on_failure=false`. | Implemented; focused and full deterministic release checks pass. |
| AE-019 | Batch receipts discarded find outlines and snapshot IDs; MCP and CLI error rendering then hid all step receipts on failure, encouraging redundant reads and unsafe whole-batch retries. | Preserve per-step observations with a 16 KiB UTF-8 outline cap and explicit clipping flag; show receipts on success and failure in both interfaces, preserving human handoff notes on CLI failures. Optional wire fields preserve decoding of older receipts. | Implemented; focused and full deterministic release checks pass. |

Deterministic tests suspend waits using an injected runtime while concurrently pausing or
replacing a session. They require those commands to finish before releasing the suspended wait,
and require later steps to refuse the changed state. Separate checks cover cancellation,
standalone preflight, batch time budgets, late probes, and safe absence detection. Two existing
wait tests originally encoded the old false-success/extra-probe behavior and were updated to
the corrected contract; the initial pause test used the wrong wire command and was corrected
to `session.control` before evaluating responsiveness.

The first full check for this pass passed all 886 Swift tests plus supporting release checks.
CLI usage was then aligned with interleaving, the batch budget, and timeout semantics; the
CLI failure regression also checks that a human handoff note remains first. Final verification
of those last documentation/rendering adjustments passed.

Final evidence for the wait/batch pass: 94 targeted tests passed, including the real-CLI/synthetic
socket error-rendering regression. The final `make verify-release` passed all 886 Swift tests,
Viewer install transaction checks, 11 Node evidence tests, and the 32-tool MCP smoke check.
`git diff --check` passed. No live displays or input were used; the broader usability,
performance, and memory goal remains active.

## 2026-09-22 — Capture stability and browser response memory

Previous goal turn: progress (wait/batch fixes and a passing 886-test deterministic release
check). Continued inspection found two more issues; existing Viewer changes remain untouched.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-020 | Pixel-stability waits obtained the complete provider data but inspected only a 32×32 grid, missing animations between samples and treating unreadable frames as the same zero hash. | Hash every active pixel row with SHA-256, include image layout, skip row padding, and reject invalid/unavailable provider data in stability probes. Feed row views directly without another full-frame bitmap or Data copy. Preserve the public nonthrowing helper for source compatibility. | Implemented; focused and full deterministic release checks pass. |
| AE-021 | Opening a browser tab buffered an entire HTTP response before checking its 64 KiB limit; target discovery separately appended to Data once per byte. | Share a streaming reader that rejects declared/actual oversize, cancels the underlying transfer on exit, and appends bounded 16 KiB chunks. Keep separate new-tab and target-list limits and preserve PUT requests. | Implemented; focused and full deterministic release checks pass. |

Capture geometry intentionally retains the repository's representability-only policy. This pass
does not introduce a new product cap or allocate a normalized bitmap. Full-pixel hashing does
more CPU work than sparse sampling; the purpose is to avoid false stability evidence, with
accelerated streaming hashing limiting the cost. Provider materialization can still allocate.

The 48 focused capture/browser/wait tests pass. Coverage includes changes between old grid
samples and at the final pixel, row-padding differences, matching payloads with different image
sizes, invalid/overflowing layouts, declared and unknown-length oversized HTTP responses,
exact byte limits, partial chunks, and the preserved PUT method. CoreGraphics rejected the
first undersized-image test fixture at construction; that check now exercises the same layout
validator used before creating raw buffer views.

Synthetic hash-cost measurement: an optimized (`swiftc -O`) standalone build of the actual
`CaptureFrameHash.swift`, using in-memory RGBA images, five warmups and the median of 30 timed
hashes, measured 2.549 ms at 1920×1080 and 11.077 ms at 3840×2160 on this host. This measures
hashing/provider access only, not capture latency or RSS; it is an added correctness cost over
sparse sampling, not a claimed speedup. The streaming HTTP reader bounds its accumulated body
and uses 16 KiB scratch storage; URLSession's internal buffers are outside that accounting.

Final capture/browser verification: `make verify-release` passed (895 Swift tests, Viewer
install transaction checks, 11 Node evidence tests, and MCP smoke for 32 tools).
`git diff --check` passed. No live desktop/display/input tests were run.

Next investigation: browser readiness/navigation polling currently swallows sleep cancellation;
check whether cancelled work keeps polling until its deadline. Also inspect queued DevTools
commands for cancellation retention and browser observations for avoidable repeat reads.
The broad project goal remains active.

## 2026-09-22 — Browser cancellation and retained command work

Previous goal turn: progress (two capture/browser fixes and a passing 895-test deterministic
release check). Current source and tests were re-read before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-022 | Chromium readiness, navigation readiness, and Electron readiness swallowed cancelled sleeps and kept polling until a wall-clock deadline; a late observation could also claim readiness. | Share cancellation-aware, monotonic polling; cap the final sleep to remaining time and reject late observations. Check cancellation before and after Electron's bounded blocking transport. | Implemented; focused and full deterministic release checks pass. |
| AE-023 | Queued DevTools commands held nonthrowing continuations until earlier work completed, retaining cancelled callers and allowing their commands to run later. | Reuse the existing cancellation-aware FIFO operation gate and check cancellation again after target verification before sending. | Implemented; focused and full deterministic release checks pass. |
| AE-024 | Callback-backed DevTools reply waits ignored task cancellation; cancelled timeout work items could retain cleanup captures until their original deadline. | Race callback, cancellation, and timeout through one completion gate; retire transport before resuming, propagate cancellation, and cancel/release a dispatch timer on completion. Use a monotonic reply deadline. | Implemented; focused and full deterministic release checks pass. |

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-025 | A DevTools command could wait in the queue or suspend during target verification, then silently execute against a newly rebound page. | Pin its original socket/target identity and refuse changes at both await boundaries before sending. Preserve that binding across multi-event gestures, element lookup/click, and navigation polling. | Implemented; focused and full deterministic release checks pass. |
| AE-026 | The ten-second DevTools deadline covered replies only; a stalled socket send could occupy the single command slot for the transport's much longer lifetime. | Apply the cancellation/deadline callback gate to sends and share a monotonic ten-second budget between sending and receiving. Reject matching replies processed after the deadline. | Implemented; focused and full deterministic release checks pass. |

Readiness polling stops promptly between probes. An already-running Electron socket exchange
retains its existing two-second transport bound; cancelling its caller prevents retries and
subsequent commands but does not interrupt that synchronous exchange. This pass does not claim
that every probe is forcibly interrupted at the readiness deadline.

AE-027: making command cancellation effective exposed a cleanup interaction: an interrupted
drag's best-effort release would itself be cancelled, and clicks/keys lacked equivalent
cleanup. Input sequences now attempt their final release in an uncancelled task, bounded by
normal transport rules and pinned to the original socket/target. They retain the original
failure and never release on a replacement page. A failed/retired original transport can still
prevent cleanup; a release attempt is not claimed as confirmed delivery. Implemented;
focused and full deterministic release checks pass.

A deterministic internal command-transport seam retains real loopback target discovery,
binding checks, and serialization but never sends application input. Tests cancel immediately
after a synthetic press and require a release with no further movement; other tests rebind
mid-gesture, element lookup, and navigation and require no commands against the replacement.

Focused verification after cleanup and compound-binding fixes: 63 tests passed, including
real loopback HTTP discovery with synthetic command transport and cancellation/rebind
interleavings. The first full release check passed before cleanup review; the final full check
also passed against the completed changes. Existing unrelated Viewer edits remain untouched.

Final evidence for this pass: `make verify-release` passed all 916 Swift tests, Viewer installer
transaction checks, 11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check`
passed. This is deterministic evidence, not live browser/display qualification or an RSS claim.
The broad goal remains active; the next pass will inspect browser observation allocation and
measure retained observation memory using synthetic workloads.

## 2026-09-22 — Browser observation work and memory measurements

Previous goal turn: progress (six cancellation/binding fixes and a passing 916-test deterministic
release check). Current source was re-read before selecting this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-028 | Resolving one web index collected every matching element and recomputed the selected rectangle; all observation paths also allocated a full querySelectorAll result. | Share a TreeWalker-based visible-element traversal and stop coordinate lookup at the requested index. Reuse the already-read rectangle; outlines/searches stop after their required results. | Implemented; focused and full deterministic release checks pass. |
| AE-029 | Interactive-element reporting rebuilt and filtered an outline's lines to count elements, and declared an exact-limit complete result truncated. | Return structured count/truncation evidence from the page; use one visible-element lookahead and render/count the parsed items directly. Native find uses one-hit lookahead too and preserves combined truncation reasons/counts. | Implemented; focused and full deterministic release checks pass. |
| AE-030 | Malformed page text, element lists, JavaScript exceptions, and selector replies could become empty reads, invented coordinates, or false absence. Search additionally swallowed page errors, and screen reads omitted a partial flag on page failure. | Decode bounded typed observations, reject malformed evidence and JavaScript exceptions, and mark unavailable page observations incomplete while retaining native results. | Implemented; focused and full deterministic release checks pass. |
| AE-031 | JavaScript UTF-16 slicing could split emoji/surrogate pairs, causing otherwise valid page observations to fail JSON decoding or disappear. | Clip labels at a valid UTF-16 boundary and read text using a scalar-safe prefix without constructing a full character array. | Implemented; focused and full deterministic release checks pass. |

JavaScriptCore tests execute the actual emitted scripts against an in-memory DOM adapter.
Resolving w0 among 10,000 synthetic controls now performs one rectangle and one style read,
with no label reads; the previous algorithm required 10,001 rectangle reads and 10,000 style
reads and retained all matching elements. This establishes work/retention reductions on the
fixture, not live-browser latency. A full traversal still visits the page's elements when a
requested control is absent; no new DOM product cap was introduced.

### Retained snapshot memory measurement

Optimized standalone binaries built from the actual `AXSnapshotDiff.swift` at baseline
`cec7173` and the current worktree, with the repository's actual `AXNode` and `ScreenDiff`
declarations, each remembered 32 synthetic snapshots of 4,000 nodes. Every node had a distinct
label consisting of its snapshot/index prefix and 512 ASCII characters. Three fresh process
runs per variant used `/usr/bin/time -l` to measure maximum resident set size.

| Variant | Peak RSS samples (bytes) | Median | Retained snapshots | Latest snapshot nodes |
| --- | --- | ---: | ---: | ---: |
| Baseline | 33,931,264; 33,947,648; 33,947,648 | 33,947,648 | 8 | 4,000 |
| Current | 18,497,536; 18,497,536; 18,497,536 | 18,497,536 | 3 | 4,000 |

The synthetic process's median peak RSS fell 45.5%; older snapshots were evicted by the 8 MiB
logical payload budget while the newest remained available. This supports AE-006's retention
improvement on this workload, not a general daemon RSS reduction or live-application claim.
An initial command was rejected because its shell output path expanded variables; rerunning
with captured subprocess output and a fixed scratch-result path resolved that safely. The
first expanded Swift build also caught an overlapping optional-property access in partial
report composition; composing the report locally removes that conflict.

AE-032: label extraction normalized a control's entire text with `trim().replace(...)` before
keeping at most 80 UTF-16 units. The shared script now normalizes only the returned prefix,
avoiding extra full-label copies and stopping once that prefix is full. A 100,000-character
synthetic label consumes 80 iterator characters; whitespace collapse and Unicode clipping
remain covered. Accessing `innerText` can still cause browser layout/full-text materialization;
this change does not claim to eliminate that source cost. Implemented; focused and full deterministic release checks pass.

Traversal tradeoff: streaming avoids retaining a complete match list and avoids later layout
queries once a result is found. For a missing result or a complete small outline, it still
walks the document and executes a selector check per element; native querySelectorAll may be
faster for some full-scan pages. No broad browser latency improvement is inferred from the
synthetic early-lookup counts. Real DOM/layout timing remains part of eligible-host validation.
The selector check calls Element.prototype.matches directly so an instance named property
cannot replace the method; the script fixtures include that shadowing case.

Focused validation: 86 observation/bridge/ergonomics/history tests passed, followed by all nine
script/decoder tests after the final selector-method adjustment. The final full deterministic
release check passed.

Final evidence: `make verify-release` passed 925 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and MCP smoke covering 32 tools. `git diff --check` passed.
No live browser/display/input tests were run. The broad goal remains active; next work should
inspect remaining observation rendering/allocation paths and expand deterministic workload
measurements rather than infer whole-daemon performance from microbenchmarks.

## 2026-09-22 — Native observation rendering and diff workspace

Previous goal turn: progress (five observation fixes, synthetic RSS measurements, and a passing
925-test deterministic release check). Current source was inspected again before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-033 | Full outlines retained a separate array of every rendered line before joining; full reads, search, and diffs also maintained separate formatting implementations. | Append full outlines directly to one result string and share per-node rendering, preserving order, filtering, and ordinary output. | Implemented; focused and full deterministic release checks pass. |
| AE-034 | Diffing materialized keyed node tuples for both snapshots plus a mapped dictionary-input array, retaining extra node values merely to locate matches/removals. | Stream key generation, map base keys to indices, and track matches with a compact boolean array while preserving original removal order and duplicate-key rules. | Implemented; focused and full deterministic release checks pass. |
| AE-035 | Exact-label targeting filtered/retained every match before noticing ambiguity. A nonpositive find limit still returned one result. | Stop label lookup at the second eligible match without a match array; return no find results for nonpositive limits. | Implemented; focused and full deterministic release checks pass. |
| AE-036 | Full outlines could trap on negative depth; global and window-relative search coordinates used trapping floating-point-to-integer conversion. | Clamp indentation and use checked centre conversion. Omit unusable coordinates while retaining indexed controls rather than fabricating a position or crashing. | Implemented; focused and full deterministic release checks pass. |

The first outline implementation saved memory but measured roughly 10% slower on the synthetic
fixture. Appending labels directly removed an intermediate copy; a bounded initial capacity
estimate then avoided repeated large buffer growth. The reservation bound does not clip output;
a regression renders an outline exceeding it. Diff matching retains the original duplicate-key
and removal-order behavior. Coordinate regressions cover NaN, infinity, finite out-of-range
values, negative sizes, and window-relative conversion.

### Native rendering/diff benchmark
Optimized (`swiftc -O`) standalone builds use the actual pre-pass and current diff code, the
repository AXNode/ScreenDiff declarations, and the actual outline methods. Each fresh process
performs 50 operations on 4,000 synthetic controls with 240-character labels plus distinct
index prefixes. Final runs alternate before/after variants three times per workload, after
focused testing finishes. `/usr/bin/time -l` supplies whole-process peak RSS.
| Workload | Variant | Elapsed samples (ms, 50 operations) | Median (ms) | Peak RSS samples (bytes) | Median peak RSS (bytes) |
| --- | --- | --- | ---: | --- | ---: |
| diff | before | 651.093; 623.388; 631.848 | 631.848 | 21,397,504; 21,184,512; 21,184,512 | 21,184,512 |
| diff | after | 570.570; 438.562; 418.018 | 438.562 | 12,845,056; 12,828,672; 12,845,056 | 12,845,056 |
| outline | before | 142.383; 128.909; 128.772 | 128.909 | 24,969,216; 26,607,616; 24,494,080 | 24,969,216 |
| outline | after | 114.174; 102.898; 96.081 | 102.898 | 11,403,264; 11,386,880; 10,240,000 | 11,386,880 |

Checksums match: 200,000 unchanged diff entries and 54,488,950 rendered UTF-8 bytes per run.
Timings and process RSS varied between exploratory and final runs; the samples are retained
above rather than treating a single percentage as a general performance guarantee. These
measure pure synthetic rendering/diff workloads, not Accessibility calls, daemon transport,
live-application latency, or release qualification.

Final native-rendering verification: 70 focused tests passed, followed by a passing
`make verify-release` (933 Swift tests, Viewer installer transaction checks, 11 Node evidence
tests, and MCP smoke for 32 tools). `git diff --check` passed. No live applications, displays,
input, or host installation were used. The goal remains active; search completeness and the
remaining transport/observation allocation paths still warrant inspection.

## 2026-09-22 — Search completeness across agent interfaces

Previous goal turn: progress (four native-rendering/search fixes, measured allocation changes,
and a passing 933-test deterministic release check). Current search and interface paths were
re-read before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-037 | Web find silently stopped at its match limit or the first 1,000 visible controls; an empty partial result looked like complete absence. The daemon recounted matches by splitting rendered text. | Return validated structured search evidence with result/scan-limit reasons, one-match/control lookahead, scanned count, and direct item counts. Combine native/page completeness in the daemon; keep the existing String API with a partial footer. | Implemented; focused and full deterministic release checks pass. |
| AE-038 | MCP discarded top-level truncation metadata, and batch receipts discarded observation completeness even while preserving clipped text. Agents could receive an incomplete search without its warning. | Render completeness in MCP without duplicating an existing footer; retain optional truncation metadata in step receipts and render it in MCP/CLI successes and failures. Keep old receipts decodable. | Implemented; focused and full deterministic release checks pass. |
| AE-039 | Web find searched only the displayed 80-unit prefix and normalized/materialized an item for every inspected control, including nonmatches. | Search full source labels/values using an escaped literal Unicode-insensitive matcher with whitespace-run matching, construct display items only for retained hits, and reuse the source label. This avoids full-label normalization/lowercase copies while preserving bounded output. | Implemented; focused and full deterministic release checks pass. |
| AE-040 | Find documentation claimed 25 total hits, all coordinates window-local, and all indices bound to a native snapshot; managed pages actually add up to 25 more hits with viewport coordinates and live DOM indices. | Align tool descriptions, role-filter guidance, playbook, daemon messages, and page-section headings with actual limits and index/coordinate semantics. | Implemented; focused and full deterministic release checks pass. |

Search lookahead may inspect additional controls after filling the output limit to distinguish
an exact result count from omitted matches. It remains limited to the first 1,000 searchable
controls, with one visible-control lookahead, and reports that boundary explicitly. Regex
metacharacters in a query are escaped; the user still supplies a literal substring, not a
regular expression. Matching runs on the source string; JavaScript-engine matching and
innerText materialization costs remain outside any claim of zero allocation.

Validation: 101 focused search/bridge/interface tests passed; the final 49-test subset also
passed after adding the public report/String-API regression. Script tests cover exact match
limits, the 1,000/1,001-control boundary, full long labels, whitespace, escaped regex syntax,
and inconsistent evidence. Existing script assertions were updated from the private array
payload to the structured report, and first-hit work assertions now include completeness
lookahead. Receipt wire tests keep older payloads decodable; MCP and real CLI tests retain
partial warnings inside failed batches.

Final `make verify-release` passed 939 Swift tests, Viewer installer transaction checks,
11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed. No live
browser/display/input tests were run. Full-label matching adds source-text work; this pass
claims complete search semantics within the reported bounds and avoids display normalization
for nonmatches, not a general end-to-end search speedup.

The goal remains active. Next inspect native clipping evidence: current truncation inference
uses a literal ellipsis in labels, which may also be ordinary UI text, and can therefore
encourage unnecessary follow-up reads. Transport/observation allocation review also remains.

## 2026-09-22 — Native clipping provenance

Previous goal turn made verified progress on search completeness and interface guidance.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-041 | Native read completeness scanned label/output text for any ellipsis. Ordinary labels such as “Open…” triggered unnecessary follow-up reads and prevented element-disappearance waits from proving absence. | Record whether the walker actually shortens a name/value, retain that evidence on AXNode, and consult it for snapshot completeness even when a diff omits the label. | Implemented; focused tests pass; full verification remains incomplete due to host-service stalls. |

This replaces repeated label/output text scans with per-node boolean checks. The existing
outline argument remains accepted for source compatibility. Provider strings clipped at
32 KiB still exceed the walker's 480-byte label budget, so they retain clipping evidence.
No claims are made about clipping performed by an application before exposing its AX text.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-042 | Browser key dispatch unnecessarily initialized `NSPasteboard.general` before checking the shortcut. The full deterministic run stalled in synchronous pasteboard XPC during the synthetic cancelled-key test. | Remove the unused pasteboard initialization; retain clipboard-route rejection before any CDP key dispatch. | Implemented; focused tests pass; full verification remains incomplete due to host-service stalls. |

The first full check was stopped after a process sample identified the blocked path:
`testCancelledKeyStillReleasesItsKey` → `ChromiumBridge.key` → `CFPasteboardCreate` →
`xpc_connection_send_message_with_reply_sync`. No clipboard contents were read or copied.
The sample is retained locally at `/tmp/spaceo-clipping-test-sample.txt`.

| ID | Finding | Next action | Status |
| --- | --- | --- | --- |
| AE-043 | Ten existing safe-suite tests directly depend on the host's named pasteboard service, and AppKit event fixtures also initialize that service indirectly. Sampled runs blocked in both paths, independently of browser input, stalling the deterministic gate. | Separate pure refusal/diagnostic policy coverage from named-pasteboard integration, preserving coverage and making host-dependent checks explicitly bounded. | Resolved in the following pass; original evidence retained below. |

The second sample is `/tmp/spaceo-pasteboard-tests-sample.txt`. It identifies
`PasteboardGuardProductionTests.makePasteboard` blocked in the same synchronous XPC path.
The user clipboard service was not reset and test exclusions are not release qualification.

A reduced run excluding the ten direct pasteboard tests also stalled in
`KeyEquivalentReleaseTests.testCommandKeyEquivalentForwardsAMatchingRelease`; AppKit event
initialization invoked pasteboard prevalidation and blocked in synchronous XPC. Its sample is
`/tmp/spaceo-remaining-tests-sample.txt`. The affected test processes were stopped; neither
exclusions nor interrupted runs are counted as a passing suite.

Validation for AE-041/042: 86 focused tests pass. The optimized build, Viewer installer
transaction checks, 11 Node evidence tests, 32-tool MCP smoke, and `git diff --check` pass.
`make verify-release` was attempted twice; the final attempt was bounded to 120 seconds and
did not complete. Logs: `/tmp/spaceo-clipping-release.log`,
`/tmp/spaceo-clipping-final-release.log`, and `/tmp/spaceo-clipping-nonpasteboard.log`.
No live displays, application input, or host installation were performed. The goal remains
active; AE-043 is the next concrete work item, with broader transport/allocation review pending.

## 2026-09-22 — Removing clipboard-service waits from deterministic work

Previous goal turn made progress: two fixes and process samples located host-service stalls.
Current sources confirmed an additional native key dependency and metadata outside diagnostic
timeouts. No clipboard service reset is needed for these fixes.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-043 | Clipboard regression fixtures created real named pasteboards; Viewer event/accessibility fixtures initialized layer backing, which initializes NSApplication and the pasteboard service; drag registration also requires desktop services. | Exercise the diagnostic algorithm with a locked memory provider; exercise refusal through the same production delivery guard with no pasteboard argument. Viewer fixtures retain real event/accessibility handlers but omit rendering/drag setup; the standard production initializer still configures both. | Implemented; focused and full deterministic release checks pass. |
| AE-044 | Native `InputRouter.key` opened `.general` to pass an unused argument before refusing clipboard shortcuts or sending ordinary keys. | Remove the unused clipboard parameter from native and Web test seams; public native key calls never initialize the clipboard. Cover public refusal before host input, along with ordinary delivery. | Implemented; focused and full deterministic release checks pass. |
| AE-045 | Diagnostic snapshot metadata (change count, item list, type list) ran outside its timeout. Each value allocated a box/semaphore and dispatched another worker. | Run a complete capture under one worker, gate, and deadline, including opening `.general` for the no-argument API. Check the deadline between provider calls and reject late results; refuse incomplete restores before opening the system clipboard. Repeated requests cannot launch more workers behind a stuck provider. | Implemented; focused and full deterministic release checks pass. |

The bounded wait limits the caller; synchronous AppKit IPC cannot be cancelled. A stuck
provider may therefore retain the single worker and its captures until it returns. Atomically
materialized provider values can still exceed retained-data limits transiently. Diagnostic
restore remains an explicit synchronous write helper, never a production input guard.

The first Viewer fixture adjustment omitted only drag registration; a fresh process sample
(`/tmp/spaceo-viewer-fixture-sample.txt`) located an earlier dependency in NSView layer backing.
The final fixture initializer omits both. It does not verify rendering or AppKit drag registration.

Final validation: `make verify-release` passed all 944 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and MCP smoke for 32 tools, with no extra test exclusions.
This also completes full deterministic verification of AE-041/042 from the previous pass.
`SPACEO_CODESIGN_IDENTITY=- make viewer` and
`codesign --verify --deep --strict --verbose=2 ".build/SpaceO Viewer.app"` passed.
`git diff --check` passed. Logs are `/tmp/spaceo-pasteboard-final-release.log`,
`/tmp/spaceo-pasteboard-viewer-build.log`, and `/tmp/spaceo-pasteboard-viewer-signature.log`.

Focused regressions cover native/Web refusal and ordinary delivery, exact item/type/byte bounds,
unavailable values, changes during capture, empty restore, stale-value preservation, timeouts
while opening or reading each metadata/value stage, single-worker admission, recovery after a
stalled provider returns, zero-budget requests, and incomplete-restore rejection. Viewer event
and accessibility assertions remain exercised on actual unbacked views. Rendering, drag-service
registration, and the real AppKit pasteboard adapter still need eligible-host qualification;
the memory fixtures prove algorithm behavior, not platform integration.

No live displays, synthetic application input, general pasteboard mutation, installation, or
clipboard-service reset was used. Existing unrelated Viewer edits were preserved. The goal
remains active. Next review browser script execution budgets and remaining observation/transport
allocations; completion of the overall usability/performance/memory objective is not yet proven.

## 2026-09-22 — Browser evaluation lifetime

Previous goal turn made verified progress through AE-045 (944-test full release check).
Current evaluation/transport sources were inspected before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-046 | Evaluations bounded the transport wait but did not request Chromium's execution timeout. Viewport reads bypassed common evaluation/error validation and decoded an untyped dictionary. | Request a 5,000 ms engine timeout, with no unbounded retry if the parameter is rejected. Route viewport reads through the common evaluator and bounded typed observation decoder. | Implemented; focused and full deterministic release checks pass. |
| AE-047 | Evaluation result/exception remote object handles were returned as descriptions or errors and then discarded locally, without releasing the browser references. | Assign each evaluation a unique object group; release it when the reply contains handles, while holding the command lease and retaining the original target/socket. Cancellation still cleans up; cleanup failure retires only the original transport and preserves an original script exception. Primitive replies need no extra command. | Implemented; focused and full deterministic release checks pass. |
| AE-048 | Foundation bridges JSON booleans through NSNumber; checking Int before Bool could render boolean evaluations as 1/0. | Distinguish CFBoolean from numeric NSNumber values, preserving true/false and ordinary numeric text. | Implemented; focused and full deterministic release checks pass. |

Protocol grounding: the official [Runtime schema](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/js_protocol.json)
defines the evaluation timeout in milliseconds and group-based release of remote objects.
The timeout is experimental; a target that rejects it fails without retrying the expression
without a limit. Five seconds is shorter than the existing ten-second send/reply budget.
The engine deadline is not a cancellation guarantee for asynchronous work scheduled by user
JavaScript, nor proof of compatibility with every Chromium version. Cleanup uses its own bounded
send/reply and does not wait in the command queue or repeat HTTP target discovery.

The current [V8 injected-script implementation](https://raw.githubusercontent.com/v8/v8/main/src/inspector/injected-script.cc)
also associates exception objects with the evaluation's object group. An isolated Node v24.15.0
inspector probe used the 5,000 ms constant read from the Swift source: an infinite loop failed
with execution terminated after 5,000.571 ms. Both returned exception handles were readable
before group release and inaccessible afterward. This verifies the mechanism in that V8 build,
not Chrome compatibility or an end-to-end memory/RSS reduction. The script/result are retained
at `/tmp/spaceo-evaluation-protocol-check.mjs` and `/tmp/spaceo-evaluation-protocol-result.log`.

Focused tests cover primitive replies without cleanup traffic, viewport exception/geometry
refusal, unsupported timeout parameters without unbounded retry, result/exception handle cleanup,
cancellation, original exceptions on cleanup failure, and cleanup refusing a replacement page.
A cleanup-order/discovery test initially counted the fixture's WebSocket handshake as a target
discovery. A request observer now counts only `/json/list`; the corrected test passes with two
discovery requests for two evaluations, including the one that required object cleanup.

| ID | Finding | Next action | Status |
| --- | --- | --- | --- |
| AE-049 | Page text reads fetch the complete selection even though their message displays only a 200-character prefix; selection copies also cross the transport before the session clipboard's 1 MiB cap is checked. | Separate bounded previews from complete copy/cut reads; enforce the clipboard byte cap before serialization without a full UTF-8 encoding copy. | Implemented in the selection-budget follow-up below. |
| AE-050 | Native `ax.text` reads use AX.string's 32 KiB prefix, then compare its character count with the requested limit. A multi-byte value can be clipped upstream yet reported complete. Follow-up confirmed the window-wide text provider retained the same hidden cap. | Give budgeted text readers access to the original attribute, then clip under their explicit character/allocation budget. Both element and window reads preserve completeness evidence. | Implemented in the selection-budget follow-up below. |

Final validation: the initial 60-test browser subset passed; the final nine evaluation tests
passed after correcting the discovery counter. `make verify-release` passed 953 Swift tests,
Viewer installer transaction checks, 11 Node evidence tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Full output is `/tmp/spaceo-evaluation-release.log`.
No browser UI, live display/input tests, host installation, or user page content were used.
This turn did not change Viewer sources. The goal remains active; AE-049 and AE-050 are concrete
remaining work, alongside the broader observation/transport allocation review.


## 2026-09-22 — Selection and native text budgets

AE-049 and AE-050 are implemented. Browser previews serialize at most 200 Unicode scalars
(800 UTF-8 bytes), adding an ellipsis when partial. Native previews retain at most 200 grapheme
clusters under a 4 KiB byte cap. Complete selections are bounded to the session clipboard's
1 MiB limit; oversize reads fail before copying or deleting. Browser extraction counts UTF-8
bytes while iterating scalars, avoiding a full encoded copy. The decoder allows bounded JSON
escaping overhead so valid control characters do not cause premature size rejection.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-051 | Native clipboard selection reads shared the 32 KiB outline cap, allowing a partial copy followed by deletion of the whole selection. Append-style paste treated a missing current value as empty. | Read complete selection/current values under explicit byte and traversal budgets; refuse incomplete reads and require an exposed current value before append. Secure fields refuse value reads. | Implemented; focused tests pass. |
| AE-052 | Cut receipts treated an unreadable or changed selection as proof of deletion. Clearing a selection does not prove document content was removed. | Preserve the successful copy receipt but report deletion as unconfirmed; distinguish unchanged selection and failed follow-up reads. | Implemented; source paths reviewed; no live deletion attempted. |

The native attribute API and browser Selection.toString still materialize the source value;
these changes bound retained/serialized output, not provider-side transient allocation or RSS.
The window-wide reader's earlier direct-value traversal still went through AX.string in the
system provider. That cap is now bypassed only for callers enforcing their own output budgets;
outline and other legacy string callers retain their existing cap.

Deterministic fixtures cover 40 KiB emoji values beyond the old native cap, exact character and
byte boundaries, secure fields without value queries, missing append values, traversal-budget
exhaustion, invalid limits, oversized complete selections without partial payloads, bounded
large previews, JSON escape expansion, and defensive bridge reply validation. A synthetic
300,000-emoji preview serializes under 900 bytes; an oversized complete selection refusal
serializes under 64 bytes. These are output-size checks, not live memory benchmarks.

Validation: the initial 53-test text/evaluation subset passed, followed by all 11 evaluation
regressions after adding bridge-level selection tests. `make verify-release` passed all 962 Swift
tests, Viewer installer transaction checks, 11 Node evidence tests, and the 32-tool MCP smoke
check. `git diff --check` passed. Full output: `/tmp/spaceo-selection-release.log`.
No live display/input tests, browser UI, host installation, or user clipboard/content access
was used. Viewer source is unchanged in this pass; existing unrelated edits remain preserved.
The long-running goal remains active; broader observation/transport allocation review continues.


## 2026-09-22 — Event framing and screenshot forwarding

Previous turn made verified progress: AE-049 through AE-052 and the 962-test release check.
Current transport and MCP capture call sites were inspected before this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-053 | Event stream framing rescans the accumulated partial line after every 8 KiB read, then shifts the remaining buffer after each complete line. | Track searched/consumed offsets, validate incoming bytes once, and compact after draining. | Implemented; focused tests pass. |
| AE-054 | The event-stream byte limit is skipped whenever buffered data contains a newline, accepting oversized terminated lines or oversized tails behind complete lines. A partial line at EOF is silently treated as a clean close. | Enforce the limit on each line and tail before retaining a chunk, and report incomplete EOF except on explicit cancellation. | Implemented; focused tests pass. |
| AE-055 | MCP screenshots decode the daemon's base64 PNG for validation, then encode the same bytes again for the image block. | Preserve bounded PNG validation and forward the original encoded string, avoiding a second image-sized base64 allocation and encoding pass. | Implemented; focused tests pass. |
| AE-056 | One-shot request/response frames are converted Data → String → Data before JSON decoding. Completed server frames also remain reachable through a cancelled read timer's connection. | Decode the original framed bytes while retaining explicit UTF-8 validation; clear the pending connection's byte buffer and outcome after transfer. | Implemented; focused tests pass. |


An optimized standalone benchmark compiled the actual before/after `LineBuffer` implementations
(`HEAD` and the working tree) with `swiftc -O`. Median of three runs on this host:

| Synthetic workload | Before | After |
| --- | ---: | ---: |
| Four 1 MiB lines, each arriving in 8 KiB chunks | 513.796 ms | 8.602 ms |
| 200 batches of 512 coalesced 16-byte lines | 13.719 ms | 8.392 ms |

Output checksums match for both workloads. These measure the framing routine, not end-to-end
socket latency or RSS. Sources and results are retained in `/tmp/spaceo-framing-before.swift`,
`/tmp/spaceo-framing-after.swift`, and the corresponding `.log` files. Incoming bytes are checked
for line limits before allocation, while the search cursor prevents repeated scans of an
incomplete prefix. Consumed storage is released after draining, including when only a small
incomplete tail remains. The production reader drains each bounded 8 KiB socket chunk.

Screenshot forwarding preserves the existing 7 MiB encoded cap, 5 MiB decoded cap, base64
validation, and PNG signature check; it does not claim a full PNG decoder validation. It removes
the second encoding pass/string allocation while retaining the decode used for validation.
One-shot transport still performs explicit UTF-8 validation, but JSON consumes the received bytes
directly. Read-timer cancellation may retain the small connection object until its deadline;
completed input buffers/outcomes no longer remain attached to it.

Focused checks: 35 initial framing/screenshot tests, then 132 transport, pointer, and unit tests
passed after the one-shot data-path changes. The first compile of the raw-socket fixture required
qualifying `Darwin.bind` to avoid XCTest/NSObject method name lookup; no production failure was
hidden. Fixtures cover fragmented Unicode, coalesced/empty lines, exact and oversized limits,
oversized tails after valid lines, tail compaction, partial versus clean EOF over a local socket,
invalid UTF-8, preserved screenshot geometry, byte-identical forwarding, and screenshot caps.
Final validation: `make verify-release` passed all 968 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Full output: `/tmp/spaceo-framing-release.log`. No live display/input, browser UI, host setup,
installation, or real screenshots were used. This pass did not modify Viewer sources.
The long-running goal remains active; the broader allocation/lifetime review continues.


## 2026-09-22 — Admission lifetimes and lazy identity checks

Previous turn made verified progress through AE-056 and passed the 968-test release check.
Current transport timer ownership and executable-identity call sites were inspected this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-057 | An admission waiter owns its timeout work item, whose callback strongly captures that waiter and its decoded request. Expiry does not clear the work item; cancellation also leaves the scheduled callback retaining the request until its deadline. | Use a weak waiter capture for scheduled expiry and explicitly clear the timer on expiry/admission. Verify request-owner release before the deadline and after expiry. | Implemented; focused tests pass. |
| AE-058 | The MCP doctor resource evaluates the executable hash argument before comparing build UUIDs, reading/hashing the binary for each poll even when UUIDs settle the comparison or daemon provenance is unavailable. | Add a lazy current-executable comparison that preserves UUID priority and hashes only when both sides require the SHA fallback. Do not cache path-based identity across binary replacement. | Implemented; focused tests pass. |


A standalone optimized Swift probe reproduced the original strong-capture ownership pattern
and the new weak-capture pattern, using a synthetic 1,000,000-character request payload. A weak
reference remained non-nil both while the old callback was queued and after it expired. With
the weak capture it was nil in both cases. The probe source/executable are retained at
`/tmp/spaceo-admission-lifetime.swift` and `/tmp/spaceo-admission-lifetime`. This verifies an
object-lifetime leak mechanism; it is not a process RSS measurement.

The production waiter owns its work item, but the work item now references the waiter weakly.
The queue remains the waiter owner until admission, expiry, or stop. Expiry clears the timer
before invoking the server callback; admission and stop cancel and clear it. Regression tests
exercise the production scheduling method with a suspended queue and after actual expiry,
including cancelled and uncancelled removal. Existing socket tests still verify admission
limits, expiry refusal, subscriber isolation, and ordinary request handling.

The current-executable comparison preserves the existing public eager-value comparison API.
Matching or differing build UUIDs avoid hash reads; missing daemon hashes also avoid reads;
usable hash fallback loads exactly once and preserves true/false/unknown results. No disk-path
hash cache is introduced. Startup provenance reporting also checks for the daemon hash before
reading the client image. CLI doctor still computes its hash because its JSON includes that
field independently of the comparison.

Validation: 49 focused transport/setup/log tests passed. `make verify-release` passed all
971 Swift tests, Viewer installer transaction checks, 11 Node evidence tests, and the 32-tool
MCP smoke check. `git diff --check` passed. Full output: `/tmp/spaceo-lifetimes-release.log`.
No live displays, application input, browser UI, installs, or host configuration were used.
The long-running goal remains active.


## 2026-09-22 — Diagnostic payload bounds

Previous turn made verified progress through AE-058 with 971 passing Swift tests.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-059 | Event detail filtering materializes and sorts every key to retain at most 32. Grapheme-safe clipping also creates a temporary String per examined character. | Keep only the smallest eligible keys in bounded scratch storage; measure grapheme byte lengths through substring views and copy only the retained prefix. | Implemented; focused tests pass. |
| AE-060 | Reentrant event publication delivers a nested event before the outer event to later subscribers. Publishing during replay can also precede registration and disappear for that subscriber. The current one-subscriber test misses this ordering contract. | Add multi-subscriber/replay regression evidence and implement ordered delivery with bounded pending storage and explicit overflow behavior. | Implemented in the ordered-delivery follow-up below. |
| AE-061 | Daemon log values are character-limited but key count, key bytes, and kind bytes are unbounded; a single grapheme can also exceed the intended value budget. Log writes concatenate another full encoded record to append a newline. | Bound field count/key/value/kind bytes while preserving the existing character cap; append the newline in place. | Implemented; focused tests pass. |
| AE-062 | EventBus calls subscriber writers while holding its global lock. A slow socket writer can occupy that lock for its 10-second streaming write budget, delaying unrelated event publication and daemon requests. | Introduce bounded subscriber buffering, preserve sequence/redaction semantics, and explicitly report backpressure gaps or disconnects. Coordinate with AE-060. | Implemented in the ordered-delivery follow-up below. |


The shared diagnostic helper retains at most 32 eligible key references, preserving the same
lexicographically smallest key set without materializing a full sorted key array. When the input
already fits the count bound, it only filters invalid keys. Text clipping examines grapheme
substring views and copies the retained prefix once. Source dictionaries/strings remain owned
by their callers; these bounds apply to scratch and output storage, not source allocation.

Daemon logs retain at most 32 supplied fields (plus timestamp/kind/default-run metadata), drop
keys over 64 UTF-8 bytes, cap kind at 128 bytes, and cap field values at both 4096 graphemes and
16 KiB. The timestamp and kind remain server-controlled. Existing ASCII field limits and normal
request receipts are unchanged. A single 100,000-combining-mark grapheme returns a truncation
marker instead of bypassing the byte cap. Encoded records append their newline in place.

Optimized benchmark of the actual before/after filtering implementations, median of three
runs, with matching checksums:

| Synthetic workload | Before | After |
| --- | ---: | ---: |
| 20 runs over 20,000 keys | 60.447 ms | 0.955 ms |
| 2000 runs over 12 keys | 2.818 ms | 1.926 ms |

The first bounded-selection implementation slightly regressed the small case (2.941 ms); a
no-selection fast path for inputs already under the key cap resolved that. Sources/results:
`/tmp/spaceo-diagnostic-before.swift`, `/tmp/spaceo-diagnostic-after.swift`, and corresponding
`.log` files. These measure filtering only, not daemon latency or RSS.

AE-060 now has a standalone reproduction compiled against the current EventBus implementation:
the second subscriber receives `[2, 1]` for an outer/nested publish; a subscriber that publishes
while replaying sees `[1]` while the bus reaches sequence 2. Source and output are retained at
`/tmp/spaceo-event-order-probe/main.swift` and `result.log`. AE-060 and AE-062 remain open and
must be handled together without replacing the fixed-capacity ring with an unbounded queue or
silently dropping events. No delivery-order success claim is made by this pass's green tests.

Focused checks: 32 diagnostic/event/log tests passed, including large key-set equivalence,
input-order independence, short-input filtering, Unicode/substring clipping, huge single
graphemes, and bounded log metadata. `make verify-release` passed all 975 Swift tests, Viewer
installer transaction checks, 11 Node evidence tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Full output: `/tmp/spaceo-diagnostics-release.log`.
No live display, application input, browser UI, installation, or user data was used. The goal
remains active; AE-060 and AE-062 are the next confirmed event-delivery work.


## 2026-09-22 — Ordered bounded event delivery

Previous pass made verified progress through AE-059/061, with 975 passing Swift tests and
reproductions for AE-060/062. This pass fixes both delivery findings against the current sources.
The original AE-062 note cited the ordinary response's 30-second deadline; streaming writes
actually use 10 seconds. The log above is corrected; the blocking path itself was confirmed.

EventBus now registers before replay and tracks one cursor/drain per subscriber. Callbacks run
outside the ring lock. Reentrant publication is consumed iteratively in sequence order, including
publication during replay. Queued subscribers schedule at most one worker each and share the
existing fixed-capacity ring as their only backlog. If eviction overtakes a consumer, its gap
callback runs before retained events and supplies an explicit resync cursor. There is no new
unbounded pending-event array or task per event. Legacy inline subscriptions remain available;
queued subscriptions provide atomic capacity refusal and explicit gap notification.

The daemon uses a serial delivery queue per socket subscriber. Its handshake, events, gap
notices, and heartbeat use that queue, so a stalled writer no longer occupies the bus lock or a
producer's callback stack. Close unsubscribes and cancels the heartbeat; cancellation waits for
an already selected bounded writer to finish before the transport can close/reuse its descriptor.
One already selected callback may finish after unsubscribe; subsequent callbacks are stopped.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-063 | Streaming event cursors used seq+1 even though replay takes events strictly after sinceSeq. Hello/heartbeat frames could also acknowledge history before sending it. CLI JSON follow printed resync notices as plain text. | Use the last successfully delivered event sequence, preserve the caller's cursor in the handshake, advance only on delivered events or explicit reset notices, and emit JSON gap response records in JSON mode. | Implemented; focused tests pass. |
| AE-064 | Viewer ingestion returned early for empty event arrays, discarding standalone resync notices. | Refresh the control plane for resyncRequired even when no event records accompany it. | Implemented; focused tests pass. |

The standalone cursor contract remains exclusive for polling and streaming; nextSeq is passed
back unchanged as sinceSeq. Redaction occurs before event delivery. A slow writer may lose ring
history, but the gap is reported explicitly before delivery resumes; other subscribers continue.
This is bounded best-effort observation, not durable or exactly-once messaging.

| AE-065 | The old stream liveness helper wakes every 500 ms, adds up to half a second of close latency, and ignores sleep cancellation. | Share a one-shot completion task among handler waiters; close/cancellation signals it directly, then drain the serial writer before returning socket ownership. | Implemented; focused tests pass. |

Validation evidence so far: the original reproduction now reports `[1, 2]` for both later
subscribers and publication during replay (`/tmp/spaceo-event-order-probe/result-after.log`).
Focused tests cover nested publication, a 2000-event iterative callback chain, replay publication,
concurrent publishers, a blocked consumer with a fast consumer still progressing, ring eviction
and gap-before-data ordering, atomic capacity refusal, unsubscribe before queued delivery,
redaction, exclusive reconnect cursors, heartbeat/handshake cursors, cancellation during writes,
close-before-wait with multiple waiters, and real local-socket replay. CLI JSON gap records and
Viewer refresh on an empty resync response have separate regressions. No live apps are involved.

Final validation: 989 Swift tests, Viewer installer transaction checks, 11 Node evidence tests,
and the 32-tool MCP smoke check passed under `make verify-release`. The ad-hoc Viewer bundle
built with `SPACEO_CODESIGN_IDENTITY=- make viewer`; `codesign --verify --deep --strict
--verbose=2` passed. Build/signature output: `/tmp/spaceo-events-viewer-build.log`.
`git diff --check` passed. No live displays, input synthesis, browser UI, host installation, or
user event content was used. This pass changed only the Viewer's empty-gap handling; existing
unrelated Viewer edits remain preserved. The broader goal remains active.


The initial full release check found one mismatch between the updated Markdown playbook and
its embedded MCP copy. `node scripts/generate-playbook.mjs` synchronized the generated artifact;
all six PlaybookTests then passed, followed by the full release rerun. The retained initial
failure is `/tmp/spaceo-events-release.log`; the final run is `/tmp/spaceo-events-release-final.log`.

| ID | Finding | Next action | Status |
| --- | --- | --- | --- |
| AE-066 | The Viewer event subscriber creates a new MainActor task for every response. A replay burst or fast producer can enqueue responses faster than UI ingestion, retaining payloads outside the bus's bounded ring. | Bound the Viewer handoff backlog, batch refresh work, and preserve explicit resync behavior when UI consumption falls behind. | Implemented in the bounded Viewer handoff follow-up below. |


## 2026-09-22 — Bounded Viewer event handoff

Previous turn made verified progress through AE-060/062–065 and passed 989 Swift tests plus
Viewer bundle/signature validation. The current Viewer subscription path was inspected again.

AE-066 now uses a per-generation mailbox capped at 128 events and 1 MiB of accounted payload.
It schedules one main-actor delivery per pending batch; a full mailbox parks the socket reader
until the UI takes that batch. Already-received events stay ordered rather than being silently
dropped. Backpressure reaches the daemon's bounded ring, whose explicit resync notices are
preserved. A decoded event too large for the mailbox is refused with visible resync evidence.
The batch owns only events and minimal control flags, not arbitrary Response payloads. These
are retained-payload limits, not an RSS guarantee; the current decoded wire response and one
batch being ingested remain live alongside the pending mailbox.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-067 | Cancelled subscription callbacks and delayed reconnect closures are not tied to the active generation. An old close can clear a replacement subscription or schedule another connection. | Stop the old mailbox before cancelling its reader; scope ingestion/closure handling and reconnect tasks to a generation; cancel superseded reconnect timers and release blocked readers on stop/deinit. | Implemented; focused tests pass. |
| AE-068 | A redacted, missing, or partial isolation verdict is interpreted as not breached, clearing a previously observed breach. | Only explicit unredacted intact evidence clears a breach; unknown/redacted verdicts preserve prior evidence. Event gaps visibly warn that refreshing inventory does not reverify isolation. | Implemented; focused tests pass. |


The mailbox never stores the scheduling closure or a full Response. It schedules before an
large multi-event response can fill the mailbox, allowing a single 1000-event response to
make progress in bounded batches rather than deadlocking behind its own completion. Each take
re-arms scheduling and wakes the reader. Heartbeats cannot overwrite a pending resync notice;
close is delivered after accepted events. Stop clears retained events and wakes blocked readers.

Main-actor ingestion refreshes the control plane once per batch. A resync warning is appended
after its event batch so the 100-row feed cap cannot immediately evict the warning. Stream
replacement invalidates stale deliveries and reconnects; the reconnect task is cancellable and
captures the model weakly. Existing unrelated Viewer edits are preserved.

Focused validation: all 36 mailbox/control-plane tests pass. Fixtures show one scheduled delivery
for 128 pending events, a blocked 129th event that resumes after take, independent byte-budget
backpressure, exact ordered delivery across 1000 events, oversized-event refusal with resync,
heartbeat/close control preservation, blocked-reader release on stop, generation rejection,
reconnect cancellation, one inventory refresh per batch, and preservation of observed breaches
until explicit intact evidence arrives. The initial visibility assertion expected the gap warning
to remain the newest row even after a legitimate “Daemon connected” notice; it now checks that
the warning survives the batch and remains visible after refresh.
Final validation: `make verify-release` passed all 998 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and the 32-tool MCP smoke check. The ad-hoc Viewer bundle built
successfully and `codesign --verify --deep --strict --verbose=2` passed. `git diff --check` passed.
Logs: `/tmp/spaceo-viewer-mailbox-release.log` and `/tmp/spaceo-viewer-mailbox-build.log`.
No live display/input, browser UI, host installation, or user event payloads were used.
The long-running goal remains active; broader usability/allocation review continues.

## 2026-09-22 — Event CLI failures and reusable MCP discovery

The preceding pass passed 998 Swift tests and Viewer bundle/signature checks. This pass reviewed
CLI event consumption and MCP discovery without using a live graphical session.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-069 | `events --since-seq` parses a signed Int and converts it unchecked to UInt64. Negative values trap; valid wire cursors above Int.max are refused. | Parse UInt64 directly, preserving ordinary CLI/JSON validation errors and the complete wire range. | Implemented; focused and full deterministic checks passed. |
| AE-070 | Event-follow daemon refusals and transport failures print errors but eventually exit 0. Automation can mistake lost subscriptions for successful work. | Exit 1 immediately on a refusal or transport error; clean EOF and user interruption retain their successful exit behavior. | Implemented; focused and full deterministic checks passed. |
| AE-071 | Every MCP discovery request reconstructs 32 nested tool dictionaries; schema-resource reads also serialize the unchanged catalogue each time. | Lazily retain one immutable catalogue and one encoded resource string. Encoding failure returns a JSON-RPC internal error instead of successful empty content. | Implemented; focused and full deterministic checks passed. |

The discovery cache trades bounded process-lifetime catalogue/string retention for fewer transient
allocations and less repeated serialization. It contains no session, controller, or user state.
This is not an RSS reduction claim. A subprocess benchmark uses a temporary fake Unix socket
that only returns synthetic health responses, avoiding daemon startup and application access.
It performs a 200-request warm-up and three timed 200-request batches per discovery method.
Before-change medians: tools/list 0.286 ms/request, schema resources/read 0.529 ms/request.
Harness: `/tmp/spaceo-schema-benchmark.py`; baseline: `/tmp/spaceo-schema-before.log`.

After-change medians: tools/list 0.252 ms/request and schema resources/read 0.148 ms/request
(about 12% and 72% lower respectively in this local microbenchmark). Output hashes matched
before/after for both methods; timings include subprocess pipe and JSON-RPC overhead and are
not a guarantee for other hosts. Results: `/tmp/spaceo-schema-after.log`.

Focused validation passed 21 tests. CLI subprocess fixtures cover negative, malformed, empty,
and overflowing cursors, ordinary JSON error responses without contacting the daemon, full
UInt64 cursor forwarding, failed connections, daemon refusals, and clean stream EOF. The MCP
resource is parsed and compared with the tool-discovery payload. The initial test build caught
an incorrect Response initializer in the new fixture; the fixture now sets its error property
explicitly. Logs: `/tmp/spaceo-cli-schema-focused.log` (initial) and
`/tmp/spaceo-cli-schema-focused-final.log` (passing).

Final validation: `make verify-release` passed all 1003 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Release log: `/tmp/spaceo-cli-schema-release.log`. Viewer sources were not changed in this pass.
No live display/input, browser UI, host installation, or user payloads were used. The long-running
goal remains active.

## 2026-09-22 — Bounded PNG output and capture preflight

Previous turn made verified progress: 1003 Swift tests and the full deterministic release check
passed. Current capture paths, tests, and the explicit unrestricted-capture policy in release
audit Round 7 were inspected before changing allocation behavior. Large captures remain allowed;
the changes below enforce existing transport limits and representable storage arithmetic.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-072 | In-memory screenshots retain a complete encoded PNG before checking the existing 5 MiB transport limit. | Use a byte-budgeted CoreGraphics consumer, refuse oversized writes without copying them, discard partial output, and propagate overflow even if encoder finalization otherwise reports success. | Implemented; focused checks pass. |
| AE-073 | Mutually exclusive memory/export options are rejected only after capturing a real image. | Reject the combination in command preflight before session resolution or capture. | Implemented; focused checks pass. |
| AE-074 | Capture dimensions check individual integer conversion but not pixel-count or RGBA byte-count multiplication. | Use checked multiplication before asking ScreenCaptureKit to allocate; preserve large representable dimensions and avoid a new product cap. | Implemented; focused checks pass. |
| AE-075 | Screenshot help advertises only scales 1 and 2 although 1 through 4 are supported; discovery omits the existing in-memory PNG size limit and recovery hint. | Align CLI help with the supported scale range and explain the PNG limit/recovery in CLI and MCP discovery. | Implemented. |

The output sink uses checked remaining capacity, refuses an entire overflowing chunk, frees its
partial Data, and stays failed for all later writes. Consumer callback state is owned until the
consumer releases it. Successful output at an exact byte limit matches the previous ImageIO
NSMutableData destination byte-for-byte; no resizing or coordinate changes are introduced.
The PNG constant is shared by the daemon and MCP validator. File exports keep their existing
unrestricted encoding semantics. Allocation arithmetic uses four bytes per pixel as a baseline
representation check; this is not a guarantee about ScreenCaptureKit's actual allocation size.

Focused validation passed 33 tests, including seven new PNG tests: exact-limit preservation and
decodability, one-byte overflow, invalid limits, accumulated and single-chunk overflow, sticky
failure and partial-output release, finalization failure, consumer lifetime, and invalid-option
preflight without an existing session. Geometry tests reject pixel/byte multiplication overflow
while retaining the 16384-by-16384 acceptance case. An initial build caught the SDK's Swift
initializer label (`cbks`, not `callbacks`); this was corrected before tests ran. Logs:
`/tmp/spaceo-png-focused.log` and `/tmp/spaceo-png-focused-final.log`.

A standalone optimized probe compiled the actual new encoder source and compared it with the
former ImageIO data destination using one deterministic 2048-by-2048 synthetic image. The old
path produced a 14,668,168-byte PNG before rejection. The bounded path rejected it without
retaining oversized output. Peak RSS was effectively unchanged (44,826,624 vs 44,924,928 bytes),
as was encoding time (about 270 vs 268 ms): ImageIO's own buffers/work remain outside the sink
budget. This change establishes bounded consumer storage, not a demonstrated RSS or CPU saving.
Probe source, executable, and results: `/tmp/spaceo-png-probe/`. No actual screen was captured.

Final validation: `make verify-release` passed all 1010 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Release log: `/tmp/spaceo-png-release.log`. No Viewer source changes, live displays/input, host
installation, or real screenshots were used. The long-running goal remains active.

## 2026-09-22 — Recording growth, receipt budgets, and bounded reports

Previous turn made verified progress with 1010 Swift tests and a passing full deterministic
release check. Current SessionRecorder, SessionReport, and their fixtures were inspected.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-076 | Every receipt recursively counts the active recording's entire growing frame tree, yielding cumulative quadratic metadata work. Manifest dates are decoded even when no pruning is needed. | Track live writers' own byte counts, skip their recursive walks, and read/sort manifest dates only above capacity. | Implemented; focused tests and synthetic timing pass. |
| AE-077 | Frames are admitted before allowing space for their encoded receipt and path fields. They can strand files and prevent the receipt from being recorded. Invalid receipts also fail only after frame writes. | Encode first, reserve the full receipt including frame paths, and drop frames if the combination cannot fit. | Implemented; focused tests pass. |
| AE-078 | Pruning checks a manifest's size after an unbounded read; reports read manifests without a cap and check actions size separately from the actual read. | Open a nonblocking, no-follow descriptor, require a regular file, check size before reading, and enforce the limit during reads. Missing manifests still mean unfinished; other invalid manifest inputs are errors. | Implemented; focused tests pass. |
| AE-079 | Each recorder's prune protects only itself, so it can delete another live session's receipt stream. | Protect all same-process live writers, coordinate capacity reservation across their root, serialize pruning, and retire registry entries on finish/deinit without retaining recorders. | Implemented; focused tests pass. |
| AE-080 | Report coordinate formatting converts an arbitrary integral Double to Int and can trap on a valid decoded extreme coordinate. | Use exact integer conversion only when representable; format finite large values directly and show unknown for nonfinite pure-core values. | Implemented; focused tests pass. |
| AE-081 | Final manifest bytes can exceed the recording cap; a failed finish is silently successful on retry. | Check remaining live capacity before manifest writing, preserve the first finish error, and prune completed recordings after successful finalization. | Implemented; focused tests pass. |
| AE-082 | Report generation retains the full action sidecar, its split-line collection, and all decoded actions alongside the growing HTML. | Stream rows from a bounded reader while preserving manifest/fallback metadata and malformed-line accounting. | Implemented in the incremental report follow-up below. |

The registry contains paths and counts only, and does not own recorders or payloads. Record and
finish mutations reserve capacity under the registry lock; pruning never acquires a recorder's
instance lock. Directory creation is coordinated with pruning. Completed/released recorders
become reclaimable, and releasing an old finished instance cannot unregister a replacement
using the same path. If no metadata fits at finish, the stream closes and the manifest remains
absent; the error persists on retry. Receipts are preserved and the report shows unfinished.
Accounting covers these writers' bytes, not out-of-band edits or writers in another process.
Completed directories still require filesystem size inspection; no stale permanent disk-size
cache was introduced. No user recording directory was read or pruned during this work.

Focused tests cover exact frame-plus-receipt capacity, dropping frames for receipt/path overhead,
invalid encoding before frame writes, multi-recorder capacity, retirement and path reuse,
manifest overflow and repeated failure, a 1 GB sparse oversized manifest, bounded regular-file
reads, symlink/directory refusal, and extreme coordinates. A proposed FileManager enumeration
spy did not compile because Foundation exposes that method through a non-overridable extension;
it was removed in favor of timing the real implementation. An early eviction assertion was
corrected to grow the recording until its actual combined footprint requires eviction.

An optimized standalone probe compared the prior committed recorder with this implementation
using 600 deterministic receipts and 512-byte synthetic frames. Both wrote 600 actions and
370,584 bytes. Total append time fell from 610 ms to 122 ms; first/last 50-action averages were
0.350/1.642 ms before and 0.220/0.178 ms after. This local filesystem result demonstrates removal
of growth-dependent live-frame scans, not a promise for other hosts or archives. Probe sources,
executables, and results are in `/tmp/spaceo-recording-probe/`.

Final validation: all 28 focused recorder tests pass, including concurrent capacity admission.
`make verify-release` passed 1021 Swift tests, Viewer installer transaction checks, 11 Node
validation tests, and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-recording-focused-final5.log` and `/tmp/spaceo-recording-release.log`.
No Viewer source changes, live displays/input, host installation, or real user recordings were
used. The long-running goal remains active; AE-082 is the next confirmed report-memory work.

## 2026-09-22 — Incremental recording reports

Previous turn made verified progress with 1021 Swift tests and a passing full deterministic
release check. This pass completes the confirmed AE-082 report-memory work against the current
SessionRecorder/SessionReport sources.

A shared descriptor-based reader now supplies reusable 16 KiB chunks under the existing regular-
file, no-follow, and total-byte checks. Report generation assembles only the current JSON line,
decodes and renders it inside an autorelease pool, then releases the action. Small line capacity
is reused; unusually large lines are released after consumption. Rows accumulate in one String,
and the completed header/summary is prepended in place. Failure counts no longer allocate a
filtered array. The pure renderer shares the same final assembly and retains its public API.

Manifest metadata is read before rendering; when absent, the first valid action, observed frame
references, valid/malformed counts, and consumed bytes establish unfinished metadata in that
same ordered pass. Blank LF lines remain omitted, whitespace-only nonempty lines remain malformed,
CRLF and UTF-8 split across chunks remain valid, and a valid final line needs no newline. The
64 MiB input limit still applies during reads if a file grows after fstat. Final HTML remains in
memory because the public API returns a String. A single large receipt can still require line-
sized scratch storage; this change does not claim constant total memory or an RSS hard limit.

All 33 focused recorder/report tests pass. New fixtures compare complete HTML with the pure
renderer across long multibyte receipts, chunk boundaries, malformed/empty lines, CRLF, no final
newline, nonchronological unfinished actions, and empty/malformed-only recordings. Reader tests
verify byte preservation, bounded chunks, rejection before callbacks for an oversized file, and
refusal of overflow bytes when the file grows during a callback. One initial expectation used a
String substring check for CR inside CRLF; Swift's grapheme behavior made the expectation wrong.
Explicit fixture counts corrected it; the renderer already preserved the old malformed-line
semantics. Logs: `/tmp/spaceo-report-focused-final.log` and
`/tmp/spaceo-report-focused-final2.log`.

An optimized standalone probe renders 40,000 deterministic synthetic receipts from the same
fixture before and after the change. The initial run produced identical 24,387,296-byte HTML
(FNV64 11009724720794363421), with peak RSS dropping from 106,070,016 to 59,686,912 bytes (44%).
Render times were 1,992 and 2,025 ms respectively; no CPU-speed improvement is claimed. The
probe sources, binaries, fixture, and repeated-run logs are in `/tmp/spaceo-report-probe/`.
No real user recording was read or rendered.

Three runs per implementation reproduced the result: median peak RSS was 106,070,016 bytes
before and 59,686,912 bytes after; median render time was 2,030 versus 2,071 ms. All six runs
matched the same output length and hash. The small timing difference is reported rather than
presented as a speed improvement; the measured gain is removal of retained intermediate data.

Final validation: `make verify-release` passed all 1026 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Release log: `/tmp/spaceo-report-release.log`. No Viewer source changes, live displays/input,
host installation, or real user recordings were used. AE-082 is resolved; the broader goal
remains active.

## 2026-09-22 — MCP input cursor and line-copy removal

Previous turn made verified progress with 1026 passing Swift tests and a measured report-memory
reduction. The current MCP stdin reader and its recovery tests were inspected for this pass.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-083 | For each coalesced stdin request, the reader copies its Data slice and removes the consumed prefix from the shared buffer. Oversized lines are copied before their size is checked. | Advance a consumed cursor, decode directly from the bounded slice, compact only a partial tail before another read, and release an entirely consumed buffer. Check the line size before decoding. | Implemented; focused tests pass. |

Scan and consumed positions are offsets relative to the backing Data, so tail compaction keeps
their meaning even when Data indices differ from byte counts. Both valid lines and recoverable
errors advance the cursor. Fatal descriptor errors remain sticky; nonblocking descriptors still
wait for readiness. The existing maximum-line budget and fixed 64 KiB read chunk are unchanged.
No new input API or wire format was introduced.

All 11 focused stdin/line-reader tests pass. New fixtures cover 20,000 coalesced valid requests
across multiple reads, oversized and invalid-UTF-8 lines among them, empty lines, an unterminated
valid tail, stable previously returned strings, and a 65,535-byte UTF-8 line split after a
consumed short request. Existing tests retain dead-descriptor, nonblocking, bounded regular-file,
unclosed-pipe, exact-limit, and oversized-EOF coverage. Focused log:
`/tmp/spaceo-mcp-reader-focused-final.log`.

An optimized standalone harness compiles the actual reader before and after the edit. Initial
results: 100,000 46-byte JSON requests took 87.0 ms before and 15.9 ms after; 300,000 one-byte
lines took 101.8 versus 11.7 ms. Thirty 900,000-byte lines took 51.7 versus 47.9 ms. All line and
byte counts matched. These are isolated framing timings, not end-to-end MCP tool throughput or
an RSS claim; daemon work and response serialization are outside the measurement. Probe source,
executables, and logs: `/tmp/spaceo-mcp-reader-probe/`. Inputs are synthetic local files.

Two additional small-request runs measured 303.6/258.3 ms before and 18.5/17.6 ms after, with
identical 100,000-line and 4,600,000-byte totals. The substantial baseline variation is retained
in the evidence rather than hidden by a single speedup ratio. Every measured case improved,
but these local framing results do not establish a fixed production throughput multiplier.

Final validation: `make verify-release` passed all 1028 Swift tests, Viewer installer transaction
checks, 11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Release log: `/tmp/spaceo-mcp-reader-release.log`. No Viewer source changes, live display/input,
host installation, or user stdin payloads were used. The long-running goal remains active.

## 2026-09-22 — Truthful recording failures and finalized receipts

Previous turn made verified progress with 1028 passing Swift tests. This pass inspected the
actual SessionManager recording call sites, not just the recorder's standalone tests.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-084 | `try? recorder.record` discards capacity/I/O errors and retries the broken writer on every subsequent action. Session metadata continues to claim recording is active. | Retire the failed writer, finish it once, clear active recording mode, emit a reason-only event, and persist an owner-visible warning until session teardown. Preserve the actual command outcome. | Implemented; focused checks pass. |
| AE-085 | Recording runs before final action metadata is attached; payload length counts characters and excludes key chords. | Record after finalization, prefer resolved action window IDs, count UTF-8 text/key bytes, and cover adopt/place/repark alongside other action receipts. | Implemented; focused checks pass. |
| AE-086 | Recorder diagnostic fields are not all byte-bounded, and text/key response prose can echo rejected payloads into a recording intended to exclude them. | Bound diagnostic UTF-8 fields, retain structured errors/outcomes and payload lengths, and omit message/error prose for type/key and batch summaries containing them. Nonfinite rejected coordinates are omitted instead of causing another encoding failure. | Implemented; focused checks pass. |
| AE-087 | Ordinary exceptions during preflight or execute return before recording, so failed attempts disappear from the timeline. | Append authorized failure receipts while still holding the operation gate, without inventing a delivery route or changing the original failure. | Implemented; focused checks pass. |
| AE-088 | CLI and MCP failure rendering drop Response.warnings, hiding a recording failure when the command also fails. | Include warnings in both failure renderers while keeping nonzero CLI status and the MCP tool error. | Implemented; focused checks pass. |
| AE-089 | Batch steps and create-and-open launch commands call execute directly, bypassing individual recording/enrichment; only the batch summary may be recorded. | Route nested command outcomes through a gate-safe receipt path without duplicating summaries or recording unauthorized/skipped work. | Resolved in the nested-command pass below. |
| AE-090 | `actions+frames` is accepted and advertised, but SessionManager never supplies before/after frame bytes to SessionRecorder. Standalone thumbnail tests do not prove daemon capture. | Implement opt-in, bounded session-owned frame evidence at actual action boundaries with deterministic injected capture tests and explicit unavailable-frame reporting. | Implemented in the bounded-frame pass below; native qualification remains outstanding. |

Recording warnings are constant reason strings, not raw filesystem errors or payloads. Only a
covered controller receives them; foreign failures cannot append to the owner's history. Both
live-session destruction paths clear warning state. Failed writers are removed before later
commands, preventing repeated I/O attempts. A recording problem never turns an otherwise
completed command into a failed action that an agent might repeat. Current and subsequent
covered responses disclose the evidence loss. Successful and failed text/key receipts retain
byte counts and structured outcomes but no prose that could echo their content.

New tests use fake displays and temporary synthetic recorders: finalized route/completion/window,
multibyte text and key lengths, ordinary preflight failures, unknown routes/nonfinite coordinates,
foreign-controller refusal, bounded diagnostics including a giant grapheme, typing-error echoes,
capacity exhaustion, already-closed writers, persistent/hidden warnings, unchanged action
success/failure, stopped-writer removal, warning cleanup on destroy, and CLI/MCP failure display.
No actual input, application launch, capture, or user recording is used.

A final source review also found that a batch summary can echo a nested typing/key failure.
The same prose suppression now applies to those summaries; the regression fixture verifies
that neither the direct failure nor its batch summary persists the synthetic payload. An
initial full verification passed before this final privacy edge case was added; the full check
was rerun for the final sources.

Final validation: 76 focused tests passed before the final batch-echo regression extension.
The final `make verify-release` passed all 1034 Swift tests, Viewer installer transaction checks,
11 Node evidence tests, and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-recording-evidence-focused-all.log` and
`/tmp/spaceo-recording-evidence-release-final.log`.
No Viewer source changes, live displays/input, host installation, or real user recording data
were used. The goal remains active; AE-089 and AE-090 are confirmed recording follow-ups.


## 2026-09-22 — Nested receipts and partial-create recovery

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-089 | Nested batch actions and implicit launches bypass the ordinary evidence boundary. | Use a shared gate-safe execute/finalize/record path for batch actions, create-and-open, and implicit browser launch. Record each attempted action once and leave skipped/refused actions out. | Implemented; validation below. |
| AE-091 | A thrown create-and-open or post-create setup error hides an already-created session and its lease. MCP discards failed-response leases; CLI failure rendering omits them. Agents cannot reliably recover or clean up. | Return authoritative session/lease state for post-create failures, retain it in MCP only when both fields are present, and print the returned lease on CLI failure without changing failure status. | Implemented; validation below. |
| AE-092 | Batch admission errors report executed=true despite shutdown, replacement, pause, or lease refusal before dispatch. | Distinguish admission refusal from an error after dispatch; mark only the former unexecuted. | Implemented; validation below. |
| AE-093 | Full enrichment for every nested action would compute discarded session geometry/readiness and consume a handoff omitted by StepReceipt. | Keep isolation enforcement, final action metadata, and recording for nested actions; construct session metadata and consume the handoff once at the outer response. | Prevented during implementation; deterministic coverage. |

The caller retains the operation gate; nested execution never recursively acquires it. Wait
steps retain their existing gate-release and reauthorization path. Batch summary recording is
separate and remains exactly once. Recorder warnings remain sticky through the final response.
MCP partial-create recovery accepts only an actually returned session and credential; failed
heartbeat or destroy replies cannot replace or remove an existing credential.

Tests use fake displays, temporary synthetic recorders, invalid actions rejected before input,
and local fixture sockets. They cover stopped/continuing batches, foreign-controller refusal,
time-budget skipping, handoff delivery, launch/setup partial failure and cleanup, MCP credential
retention, and CLI failure status plus recovery guidance. No real app launches, captures, input,
or user recording data are used. AE-090 remains the next confirmed recording follow-up.

Validation: all 53 focused tests passed. Final `make verify-release` passed all 1040 Swift
tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-nested-recording-focused-final.log` and
`/tmp/spaceo-nested-recording-release.log`. No Viewer sources changed in this pass; no live
qualification, host installation, or publishing was performed. The long-running goal stays active.


## 2026-09-22 — Bounded daemon recording frames

Previous turn made verified progress with 1040 passing Swift tests. Inspection confirmed that
the receipt path still never passed frame data to the recorder. This pass connects actual
individual command boundaries to the existing session-aware capture path.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-090 | Daemon `actions+frames` records no images. | Capture before/after individual commands, including nested launches and batch steps; use the session tile and foreign-window exclusions. Persist images plus explicit omission statuses and show omissions in reports and agent warnings. | Implemented; focused checks pass; native qualification outstanding. |
| AE-094 | SessionRecorder accepts and writes caller-supplied images even in actions-only mode. | Enforce the chosen mode at the writer boundary; actions-only receipts cannot reference or persist supplied frames. | Implemented; deterministic test. |
| AE-095 | Optional frame capture could retain full-size images or accumulate pending tasks if native capture ignores cancellation. | Request at most 480-pixel output directly, cap encoded PNG retention at 1 MiB, enforce a two-second deadline, and allow at most one unfinished capture per manager. Late results are discarded; subsequent requests report busy until it retires. | Implemented; timeout/cancellation and resolution tests. |
| AE-096 | Missing images have no reason, capacity omission is silent, and unfinished reports infer actions-only mode when every frame is absent. | Add optional before/after status fields, preserve truthful capacity omission in the stored receipt, and infer frame mode from statuses too. Old receipts remain decodable. | Implemented; deterministic report and capacity tests. |
| AE-097 | Batch step warnings disappear because StepReceipt does not carry them; this hides missing frame evidence. | Collect distinct step warnings in the final batch response. | Implemented; batch fixture. |
| AE-098 | Recording comments/report footer promise typed content is never recorded, although opt-in pixels can contain visible typed text. | Distinguish omitted text/key payloads from visible screenshot content in report, CLI/MCP help, and recording documentation. | Corrected. |

Frames use the existing crop-before-capture and fail-closed foreign-window exclusion planner.
No full display image is captured and cropped later. Geometry/display validity is checked before
and after capture. Evidence checks do not mutate pause state; normal command isolation checks
remain authoritative. A capture failure does not turn a completed command into a retry request.
The optional path can add up to two two-second waits per action; actions-only mode makes none.
Batch summaries use step evidence rather than extra images. Preflight-rejected, foreign, paused,
and skipped work does not trigger capture. PNG and task bounds do not claim a whole-process RSS
limit or bound ScreenCaptureKit's private internal working storage.

The callback deadline gate was extracted from ChromiumBridge without changing its validated
wrapper contract. Both users share one-shot completion and cancellation behavior. The frame
worker remains marked busy until its underlying operation exits, even after the caller's timeout;
this avoids one uncooperative native operation per later command. Synthetic tests release their
suspended operations; they do not leave live captures or displays behind.

Tests exercise distinct before/after synthetic PNGs through SessionManager.handle, capture
failure and payload-free diagnostics, actions-only and foreign-controller refusal, actual
foreign-exclusion data passed to the injected capture provider, batch warnings/skipping,
encoded/dimension bounds, timeout and cancellation with an uncooperative provider, eventual
recovery, capacity omissions, report rendering, and backward-compatible receipt decoding.
All 118 focused tests pass before the final isolation-check review. Full validation follows.
User documentation: `docs/RECORDING.md`. No live ScreenCaptureKit/WindowServer qualification,
user screenshots, application launch/input, host installation, or release publication is claimed.

Final validation: `make verify-release` passed all 1049 Swift tests, Viewer installer transaction
checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed. Focused log:
`/tmp/spaceo-recording-frames-focused-final.log`; full log:
`/tmp/spaceo-recording-frames-release.log`. No Viewer sources changed in this pass. Native capture
qualification remains explicitly unproven, and the broader agent-efficiency goal remains active.


## 2026-09-22 — Completed-recording retention cost

Previous turn made verified progress with 1049 passing Swift tests. A fresh inspection found
that active recordings use tracked byte counts, but each append still creates Foundation URLs
and resource-value dictionaries for every file in every completed recording. A synthetic probe
with 40 completed recordings containing 100 frame files each confirmed the cost.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-099 | Recounting archived frame trees creates one URL/resource metadata object per file per action, increasing latency as retained history grows. | Use a physical POSIX file-tree walk to sum current regular-file sizes directly from stat metadata. Preserve hidden-file exclusions and oldest-first pruning; never follow links or change the process working directory. | Implemented; focused checks pass. |
| AE-100 | Repeated retention passes can accumulate autoreleased Foundation listing metadata inside a long-lived caller. | Drain a local autorelease pool at each prune boundary. The direct frame walk also avoids most temporary Objective-C metadata allocation. | Implemented; isolated probe shows lower peak RSS. |
| AE-101 | Missing/unreadable subtree enumeration and per-file metadata errors silently contribute zero bytes, allowing retention to understate disk usage. | Throw a structured recording error when a visible entry cannot be inspected. Do not make a deletion decision from incomplete accounting. | Implemented; deterministic missing/unreadable fixtures. |

Sizes are recomputed on every pass, including edits to existing completed frame files that do
not change their parent directory's timestamp. No mutable-size cache or periodic accounting
window was introduced. All live recorders retain their existing protection and tracked accounting.
The traversal excludes dot-hidden and macOS UF_HIDDEN entries, ignores non-regular files and
symbolic links, counts hard links by path as before, and closes the native traversal on errors.

New tests cover nested Unicode paths, dot-hidden files/subtrees, Finder-hidden flags, hard links,
file/directory/cyclic symlinks, unchanged process cwd, in-place file growth between appends,
missing paths, and unreadable visible subtrees. The unreadable fixture explicitly skips only
when executed as root, which bypasses its permission check. Existing retention tests continue
to cover oldest-first ordering, all-live protection, exact capacities, and completed cleanup.

Optimized probe evidence: 60 appended receipts with 40 completed archives × 100 synthetic
512-byte frame files. Before timings were 906.8, 1098.0, and 746.4 ms. Final-source after timings
were 211.4 and 213.8 ms. All runs produced 60 actions and 4011 receipt bytes. Two measured
baseline peak RSS values were 74,563,584 and 74,416,128 bytes; both final-source runs peaked at
10,469,376 bytes (about 86% lower in this isolated harness). An intermediate implementation
without the explicit autorelease boundary measured 216.3/301.0 ms and one 15,613,952-byte peak.
The probes compile the actual before/after recorder source; their synthetic image encoder stub
is unused in this actions-only append workload. RSS includes identical archive setup/cleanup,
while the printed timing covers only the append loop. These are local retention measurements,
not whole-daemon memory or throughput guarantees. Source, binaries, and logs are retained under
`/tmp/spaceo-retention-probe/`. Final focused validation passed all 39 recorder tests, including
the unreadable-directory test without a skip: `/tmp/spaceo-retention-focused-final.log`.

Final validation: `make verify-release` passed all 1053 Swift tests, Viewer installer transaction
checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed. Full log:
`/tmp/spaceo-retention-release.log`. No Viewer source changes, live displays/input, host
installation, or publishing were performed. The long-running goal remains active.


## 2026-09-22 — Wait scheduling and finalization

Previous turn made verified progress with 1053 passing Swift tests. Inspection of the actual
wait evaluator found avoidable delay around stability confirmation and operation-gate admission.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-102 | Stability durations are rounded up to the next 250 ms poll, so a stable 100 ms condition takes 250 ms and a 450 ms condition can time out at a 500 ms deadline without its final confirmation. | Schedule the next observation at the earlier of the polling interval, remaining deadline, or earliest stability confirmation. Require another matching full-frame hash; changes and missing evidence still reset stability. Adjust the watchdog ceiling for extra confirmation probes. | Implemented; focused tests pass. |
| AE-103 | A probe can queue before the wait deadline, acquire the operation gate after it, and perform an expensive observation whose result will be discarded. | Carry the probe admission deadline into the gated evaluator and refuse dispatch after expiration. Return a normal timeout without counting an observation that never began. | Implemented; queued fake-clock test. |
| AE-104 | Standalone wait finalization queues once to reauthorize and again to attach response metadata. | Reauthorize and enrich under one final gate entry. Nested waits preserve handoff notes for the outer batch and omit unused session metadata. | Implemented; standalone/nested handoff coverage. |
| AE-105 | Gate contention and in-flight native/bridge queries can delay the overall response beyond the condition deadline. Skipping expired dispatch does not cancel a pending gate entry or safely preempt already-running observation. | Follow up on bounded admission/response completion without releasing session authority while native work is still running. Current help now distinguishes condition deadlines from response latency. | Standalone wait admission addressed in the next pass below; in-flight work remains outstanding. |
| AE-106 | Standalone wait finalization asserts requested isolation against a response with no isolation report, even after preflight passes; enriching nested waits exposed the same missing-evidence path. | Attach current isolation evidence under the final gate when explicitly requested. Preserve partial coverage and require only the requested dimensions. | Regression reproduced; fix implemented. |

Deterministic timing cases now confirm 100, 130, 300, 450, and 550 ms conditions at their
requested durations with a confirming observation. A 450 ms condition succeeds before its
500 ms deadline. A changing image at the short confirmation resets the window; missing hashes
still break continuity. A 60-second fixture that changes on intermediate confirmations exceeds
400 probes and reaches its full deadline instead of hitting the old default watchdog early.
The watchdog remains bounded and public explicit WaitPolicy.maximumProbes remains authoritative.

A fake-display manager wait is suspended after its first probe, queued behind a held operation
lease, and advanced beyond its deadline. After the holder releases it, the response is a normal
timeout with exactly one probe; expired queued work never becomes a second observation.
Lease/generation authorization still runs before final metadata. Standalone and batched waits
deliver a pending human handoff once. Existing cancellation, pause, replacement, and timeout tests
remain green. No screenshots, AX traversal, app launch/input, or live displays are used.

Focused validation: all 62 tests across WaitConditionTests, ErgonomicsCommandTests, and
SessionLifecycleRaceTests passed. Log: `/tmp/spaceo-wait-scheduling-focused-final.log`.
These timings use an injected clock; they establish scheduling behavior, not native capture
latency or a whole-daemon throughput measurement. AE-105 remains a separate outstanding item.


A final review found AE-106. The new four-scenario regression (standalone/batch × strict/specific
required dimension) failed before the fix, despite valid injected observed evidence. Finalization
now attaches the requested report; ordinary waits do not incur another isolation observation.
The first full run caught a generated-playbook/source mismatch during the documentation update;
regeneration fixed it and a second full run passed 1060 tests before this additional regression
was found. Final validation is rerun after the isolation-evidence fix; earlier runs are not
presented as evidence for the final source state.

Final validation after AE-106: all 63 focused tests passed, then `make verify-release` passed
all 1061 Swift tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP
smoke check. Canonical playbook Markdown and generated Swift are synchronized. `git diff --check`
passed. Final logs: `/tmp/spaceo-wait-scheduling-focused-complete.log` and
`/tmp/spaceo-wait-scheduling-release-complete.log`. The reproduced isolation regression is retained
in `/tmp/spaceo-wait-isolation-before.log`. No Viewer source changes, live qualification, host
installation, or publishing occurred. The goal stays active; AE-105 is the next wait follow-up.


## 2026-09-22 — Bounded wait admission

Previous turn made verified progress with 1061 passing Swift tests. AE-105 was rechecked against
the current gate and wait path before implementation; every gate entry still waited indefinitely.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-105 | A standalone wait can remain queued after its condition budget expires. | Add optional timed admission to the existing gate. Initial admission, every probe, and final authorization use the same wait deadline. Expired waiters are unlinked/resumed without waiting for or releasing the holder. | Admission portion implemented; native in-flight completion remains unresolved. |
| AE-107 | The wait loop's clock starts after initial queue admission, so that queue delay does not consume the requested budget. | Carry one start/deadline through admission and the loop. Plain pauses sleep only the remaining budget; a fully consumed initial budget starts no observation. | Implemented; fake-clock coverage. |
| AE-108 | A batch has independent initial/step/final operation-gate entries outside the newly bounded inner wait, so its parent request can still queue after a nested wait has returned. | Bound batch admission and finalization while preserving historical step receipts and avoiding a false retry instruction for completed input. | Implemented in the following batch-admission pass. |

Untimed gate callers keep FIFO behavior. Zero timeout is a nonblocking attempt, useful for final
metadata when the budget is spent and the gate is already free. Positive deadlines remove queued
waiters independently of the holder and are checked again after handoff so a late grant cannot
run expired work. Timers capture the gate weakly and are cancelled on handoff/cancellation/expiry;
continuations resume outside the gate lock. A timed-out request never releases another owner's
lease. Existing cancellation-versus-handoff fencing is retained.

Initial or final authorization admission failure produces `wait_queue_timeout`, a structured
error with session-list recovery guidance. It returns no unreauthorized session, readiness,
snapshot, handoff, or wait payload. Probe admission expiry remains a condition timeout when final
authorization can run; if the gate remains occupied, final admission reports the queue error
immediately instead of blocking again. CLI/MCP help and the generated playbook describe the
new distinction. Malformed requests use a bounded default admission budget, then preserve
lease-first refusal before command-field validation; invalid values never arm an unbounded timer.

Tests retain a held gate while a waiter expires, prove remaining FIFO order and holder ownership,
cancel a long-deadline waiter, check release of its captured state before that deadline, cover
nonblocking/invalid timeouts, race handoff against expiry, and exercise initial/final manager
admission without releasing the blocker first. Pure loop tests charge initial queue time against
a plain pause and forbid a first observation after budget exhaustion. Fake displays, synthetic
state, and short scheduler timers only; no live input, application launch, or native capture.

Focused validation passed 78 tests across SessionLifecycleRaceTests, WaitConditionTests,
ErgonomicsCommandTests, and PlaybookTests before the final timeout-range validation refinement.
Log: `/tmp/spaceo-wait-admission-focused-final.log`. Full validation follows. AE-105's in-flight
query part and AE-108 remain open; no hard end-to-end response bound is claimed for them.


The first full verification exposed a lease-refusal precedence regression for malformed foreign
waits: parsing before admission returned a missing-condition error instead of the existing lease
error. Restored authorization-before-field-validation under bounded admission. Invalid timeout
values select a bounded default only for admission and are still rejected by normal validation
once authorized. The existing LeaseAuthorizationTests regression is retained unchanged.

Final validation after restoring lease-first refusal passed all 86 focused tests and
`make verify-release`: 1070 Swift tests with zero failures, Viewer installer transaction checks,
11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-wait-admission-focused-complete.log` and
`/tmp/spaceo-wait-admission-release-complete.log`. No live qualification or host installation
was performed. AE-105's in-flight native work and AE-108 remain open; the project goal stays active.

## 2026-09-22 — Bounded batch admission

Previous turn made verified progress with 1070 passing Swift tests. Inspection confirmed that
`runSteps` still had unbounded initial and final gate entries, and each step had its own unbounded
entry. The batch clock also started after initial admission, excluding that queue delay.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-108 | Batch queue entries can exceed the batch budget, including after a bounded nested wait returns. | Start one deadline before initial admission; use its remainder for initial, per-step, and final gate entry. Preserve historical receipts when final authorization cannot run. | Implemented; deterministic contention tests pass. |
| AE-109 | Cancellation while awaiting a step's gate bypasses the unexecuted-step wrapper, so its receipt incorrectly says execution began. | Wrap non-timeout admission errors as `BatchStepNotExecuted`; cancellation retains prior receipts and skips later steps. | Implemented; queued-cancellation regression coverage. |

Initial queue expiry returns `batch_queue_timeout` and explicitly says no steps executed. A queued
step that expires receives `batch_timeout` with `executed: false`; later steps remain skipped even
with continue-on-failure enabled. An already-expired budget starts no step admission timer.
The existing 60-second cap and shorter valid request timeouts remain in force. Invalid timeout
values use a bounded default solely for admission, then normal preflight rejects them.

Final queue expiry retains every step receipt and the first step failure, but returns failure and
a warning that fresh session/isolation evidence is unavailable. If every step succeeded, the
top-level error is `batch_queue_timeout` with no invented failed-step index. Recovery guidance
requires reviewing receipts and re-observing before further input, not replaying completed steps.
No final session, readiness, snapshot, handoff, or isolation report is attached without admission.
Existing step observations remain historical, as documented. Timed admission uses the previously
verified gate cleanup; no new timer or worker implementation was introduced.

Tests hold the gate past initial admission, charge a fake initial delay against step eligibility,
queue another holder after a nested wait's final authorization, and retain that holder while the
batch's final or next-step admission expires. They assert successful earlier receipts survive,
queued input is unexecuted, later input is skipped, cancellation remains unexecuted, no fresh
metadata leaks through, and the queue empties before releasing the holder. Invalid deadlines
are rejected. Fixtures use fake displays and clocks; there is no native input or live capture.

CLI/MCP help, protocol documentation, troubleshooting, the generated playbook, and the changelog
describe the new behavior. Already-running native operations remain AE-105's unresolved latency
limit; bounding queue admission does not promise a hard end-to-end response deadline.

Validation passed: 78 focused tests across ergonomics, lease authorization, gate races,
playbook generation, and MCP translation; then `make verify-release` passed 1076 Swift tests,
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-batch-admission-focused-complete.log` and
`/tmp/spaceo-batch-admission-release.log`. No live qualification, Viewer source change, host
installation, or publishing occurred. AE-108 and AE-109 are fixed; AE-105's in-flight work remains
open and the project goal stays active.

## 2026-09-22 — AX wait traversal budget propagation

Previous turn made verified progress with 1076 passing Swift tests. Inspecting `probeNow` showed
that `element_label` and `element_gone` always invoked the ordinary three-second AX snapshot,
even when window resolution had consumed most of the wait's remaining budget. The existing AX
walker already supports monotonic traversal and descendant messaging deadlines, but this caller
was not supplying its remaining budget.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-105 | In-flight observations have backend budgets independent of the wait deadline. | Propagate the post-window-resolution remainder into AX traversal and per-call timeouts, retaining all other safety limits. | AX traversal portion implemented; window discovery, browser/capture deadlines, and uncooperative native work remain outstanding. |
| AE-110 | Preparation after the initial probe deadline check can consume the remainder, yet the path still starts a browser request or capture. | Recheck the deadline immediately before browser observation and capture dispatch; AX computes its envelope after window resolution. | Implemented; existing expired-probe handling applies without starting more backend work. |
| AE-111 | `WindowPlacement.windows(of:)` copies the complete AX window array, sets a timeout only on the application element, and reads window IDs/titles/frames without an aggregate discovery budget. `refreshWindows` repeats this per live app before wait traversal starts. | Introduce bounded/paged discovery and propagate the wait remainder without treating partial enumeration as window absence or weakening containment/ownership checks. | Wait, capture, placement, launch polling, no-window preflight, watcher, general refresh, teardown, and the compatibility list are bounded below; Electron pane discovery remains under AE-131. |

The public `snapshotAX(window:)` retains its existing default behavior. An internal overload
accepts the AX traversal envelope, preserving process-identity checks, generation invalidation,
cache attribution, and session/lifecycle authority. Waits cap total traversal at the lesser of
three seconds and their remainder, and each AX call at the lesser of its ordinary 250 ms limit
and that traversal remainder. Below the walker's supported 10 ms minimum, another traversal is
not started. Node, depth, call-count, allocation, and paging ceilings are unchanged.

Root lookup can exhaust the shared traversal budget before producing a partial snapshot; that
deadline stop now counts as an unmet observation instead of a generic command error. The wait
loop may retry if its overall deadline still permits it. Provider errors and cancellation remain
errors/cancellation; a partial tree never proves absence. No detached work, early lease release,
extra worker, or new native cancellation mechanism was introduced.

Synthetic-provider evidence: with a 25 ms remaining budget and calls advancing a monotonic clock
by 10 ms, traversal stops after three calls. Their messaging timeouts are 25, 15, and 5 ms;
the returned tree is marked deadline-truncated and cannot satisfy `element_gone`. Tests also
cover exhausted/subminimum/nonfinite budgets, unchanged ordinary traversal defaults, and retained
non-time safety limits. This demonstrates budget propagation, not native-provider compliance
with messaging timeouts or a hard end-to-end response deadline. CLI behavior remains unchanged;
MCP help, generated playbook, and the changelog explain the AX improvement and remaining limits.

Validation passed: 105 focused tests covering AX budgets, snapshot generations, waits,
ergonomics, and playbook consistency; `make verify-release` then passed 1079 Swift tests,
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-ax-wait-budget-focused-complete.log` and
`/tmp/spaceo-ax-wait-budget-release.log`. No live queries, input, capture, host installation,
Viewer source changes, or publishing were performed. The project goal remains active, with
AE-111 window discovery the next concrete part of the remaining AE-105 backend latency work.

## 2026-09-22 — Checked window discovery for wait probes

Previous turn made verified progress with 1079 passing Swift tests. Call-site inspection confirmed
that the old best-effort window array feeds placement, watchers, containment, teardown, and capture
exclusions as well as waits. Silently capping that shared array would turn an incomplete read into
missing safety evidence. This pass adds checked discovery to the wait path; migrating the remaining
legacy consumers requires explicit completeness handling and remains part of AE-111.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-111 | Wait discovery copies a whole remote window array and reads each descendant without an aggregate budget. | Checked AX count/page calls, 32-reference pages, per-descendant timeouts, and one budget across apps. Publish the refreshed session list only after successful discovery. | Wait path implemented; legacy consumers remain open. |
| AE-112 | A window retained through an AX blackout carries a cached title; title waits previously searched that cache as if it were a fresh observation. | Return freshly enumerated windows separately from the retained containment list and match title conditions only against those observations. | Implemented; retention/freshness regression test. |

`AXWindowDiscovery` reuses the existing AX traversal accounting. One wait probe permits at most
256 window entries, 2048 AX calls, 2 MiB accounted allocation, and the lesser of two seconds and
the current wait remainder; descendant messaging calls remain at most 250 ms and shrink with
the deadline. Counts above the remaining entry limit fail before copying any page. Missing or
short pages, unknown/repeated window IDs, unavailable geometry, provider errors, and resource
limits throw instead of yielding a plausible partial list. Cancellation begins no further calls.
Single AX attributes are still returned atomically by macOS; allocation accounting rejects an
oversized title after that unavoidable read rather than claiming to cap the provider's allocation.

`AgentSession.refreshWindows(forWait:)` stages the new list, rechecks each process identity, and
commits only after all apps finish within the shared budget. Failed enumeration preserves known
windows and snapshot history. Owned windows still present in the WindowServer remain in the
containment list, with ownership and geometry rechecked under the budget. Their cached titles
are excluded from fresh title observations. A deadline produces an unmet probe, while provider
and resource-limit failures remain errors; no partial result proves absence. Other wait backends
reuse this successful refresh rather than invoking another unbounded window lookup.

Synthetic tests cover 70 windows in pages of 32/32/6, descendant messaging timeouts, `Int.max`
counts rejected before any page, failed/short pages versus a successful empty list, deadline and
allocation exhaustion, shared limits across apps, cancellation, repeated/unknown identities,
transactional preservation of known windows/history, and cached-title exclusion. The first test
build exposed the SDK's conflicting `WindowRef` alias; explicitly qualifying the test return type
resolved it. All fixtures use fake providers, fake displays, and the existing test process identity;
there is no native AX enumeration, application launch, input, or capture.

Browser/capture deadlines and uncooperative native calls remain AE-105 work. In particular,
foreign-window exclusion discovery inside capture and legacy general window enumeration remain
unbounded by this new wait-discovery budget; neither a universal enumeration bound nor a hard
end-to-end wait deadline is claimed. MCP help, generated playbook, and changelog reflect this scope.

Validation passed: 122 focused tests across discovery/traversal, blackout retention, ergonomics,
waits, snapshot generation, and playbook consistency. `make verify-release` passed 1088 Swift
tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-window-discovery-focused-complete.log` and
`/tmp/spaceo-window-discovery-release.log`. No live qualification, host installation, Viewer
source change, or publishing occurred. AE-112 is fixed; AE-111's legacy enumeration consumers
and AE-105's remaining backends stay open. The long-running project goal remains active.

## 2026-09-22 — Bounded capture exclusion discovery

Previous turn made verified progress with 1088 passing Swift tests. Capture's exclusion planner
already combines known exact identities with live process IDs and the ScreenCaptureKit snapshot.
Fresh AX discovery is still needed to establish known overlaps that ScreenCaptureKit might omit;
removing it would weaken the unresolved-overlap refusal. This pass migrates that discovery to the
checked, paged path and keeps the existing capture planner unchanged.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-111 | Capture exclusions still trigger unbounded legacy enumeration in every neighbour before capture starts. | One checked discovery budget spans all neighbours, retained identities, and immutable teardown snapshots; discovery failure prevents capture. Stability waits pass their remainder. | Capture portion implemented; legacy general/placement/watcher/teardown enumeration remains open. |
| AE-113 | Exclusion discovery reads and retains titles although filtering needs only window IDs, owners, and geometry. | Add an identity-only discovery mode and omit title IPC/allocation. | Implemented; synthetic call-count and oversized-title regression. |
| AE-114 | Capture identity merging creates cached and refreshed arrays, a combined array, mapped tuples, and a dictionary before producing its output. | Merge checked results and retained identities incrementally into one bounded dictionary, dropping titles from identity records. | Implemented; retention and capacity tests. |

The existing discovery envelope applies once per exclusion request: 256 window entries, 2048 AX
calls, 2 MiB accounted allocation, and at most two seconds (shortened by a stability wait's
remainder). Retained cached identities and teardown snapshots consume that same budget; capacity
exhaustion throws rather than trimming an exclusion set. Fresh geometry takes precedence, while
known windows remain protected through AX blackouts and process-exit/compositor transitions.
Live process IDs still cover newly appearing windows in the capture snapshot. Native AX attributes
are atomic, so accounting is not a guarantee about allocations inside a remote provider.

Each neighbour's lifecycle lease now has deferred release across the throwing discovery path.
Optional recording evidence reports capture unavailability without replacing the underlying
command outcome; no frame provider runs with partial exclusions. Discovery reads leave the
session's window cache unchanged. The driver seam is now named `checkedWindows` and explicitly
selects title-bearing observations versus identity-only capture discovery.

Synthetic evidence with 70 windows and WindowServer geometry: normal discovery makes 144 AX
calls; exclusion discovery makes 74 (one count, three pages, 70 identities) and makes no title
requests, including for a configured 3 MiB title. The identity-only test accounts for less than
32 KiB. This is a provider-call/accounting comparison, not a whole-daemon memory or latency claim.
Tests also prove that an insufficient cached-identity budget fails without dropping known windows,
that the manager uses checked discovery rather than legacy enumeration, and that injected failure
prevents partial exclusions and recording frames while preserving action results. Teardown after
those failures completes, exercising lifecycle cleanup.

The existing missing-owner, unresolved-overlap, changed-owner, new-window, and nonoverlapping-window
capture planner tests remain unchanged. Documentation now distinguishes the two-second exclusion
discovery budget from each recording capture's separate two-second callback budget. Browser and
ScreenCaptureKit completion, uncooperative native calls, and the remaining legacy discovery paths
remain open work under AE-105/AE-111; no hard end-to-end deadline is claimed.

Validation passed: 104 focused tests covering capture isolation, blackout retention, discovery,
ergonomics, recording capture, and playbook consistency. `make verify-release` passed 1090 Swift
tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-capture-discovery-focused-complete.log` and
`/tmp/spaceo-capture-discovery-release.log`. No native capture, live qualification, host installation,
Viewer source change, or publishing occurred. AE-113 and AE-114 are fixed; the long-running goal
remains active with the remaining AE-111 legacy discovery paths and AE-105 backends outstanding.

## 2026-09-22 — One checked discovery per placement transaction

Previous turn made verified progress with 1090 passing Swift tests. Inspection of `placeAll`
found that it enumerated all windows once, then `move` repeated whole-array enumeration for every
window; rollback repeated those scans again. Discovery was best-effort, so an incomplete list
could be accepted as the set of windows to place.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-111 | Placement starts from an unbounded best-effort list; single-window element lookup also copies a complete array. | Placement uses checked discovery before any move; single-window lookup reuses the paged AX root resolver under the existing time/call/allocation limits. | Placement and element lookup migrated; launch polling/general refresh/watchers/teardown remain open. |
| AE-115 | Forward placement and rollback repeatedly scan every window to resolve each element, producing quadratic identity lookups and repeated full-array allocations. | Retain handles from one successful bounded discovery, revalidate process/element identity before use, and reuse those handles for forward moves and rollback. | Implemented; deterministic transaction and discovery tests. |
| AE-116 | `allow_no_windows` launch/adoption checks interpret failed best-effort enumeration as an empty list and take the successful no-window branch. | Require checked enumeration and process-identity validation before accepting an empty result. | Implemented; CLI/MCP/playbook semantics updated. |
| AE-117 | No-window preflight still reads geometry/titles for every discovered window even though its decision only needs a trustworthy zero/nonzero result; nonempty results are then rediscovered for placement. | Introduce a checked bounded presence probe alongside the remaining launch-polling migration, preserving failure-versus-empty distinctions. | Implemented in the following readiness pass. |

Handle retention is opt-in: wait/capture discovery still returns no handle map. The bounded
discovery result publishes windows and handles together only after complete enumeration;
retained handle entries consume the allocation budget. Placement validates coverage before any
move. Each use rechecks the original process identity, installs a descendant timeout, and confirms
the element's window ID. A closed/replaced handle is refused rather than rediscovered as another
window. Existing post-move full-containment verification and best-effort rollback of every original
window are preserved. Cancellation stops forward work and still attempts rollback. No native work
is detached or permitted to outlive session authority.

The public optional element lookup remains optional but now has bounded lookup semantics; a direct
`move` preserves the underlying structured lookup failure. `placeAll` retains the existing
WindowServer-disagreement diagnostic for a confirmed empty AX list. The discovery phase is bounded,
not the entire multi-window mutation/rollback: existing asynchronous frame-settle verification and
uncooperative native calls remain separate latency work.

The production placement transaction now has injected discovery/move/live-bounds operations for
deterministic tests. Tests prove one discovery supplies all handles, incomplete discovery or missing
handle coverage causes zero moves, containment refusal restores all originals (including windows
not yet moved), rollback continues after an individual restoration error, closed windows are omitted
from returned placement receipts, and cancellation still restores originals. A 70-window fake-provider
test retains all 70 handles in the same 144 discovery calls and 32/32/6 pages as an ordinary read;
ordinary reads retain zero handles. This demonstrates removal of repeated discovery, not measured
native placement throughput. The initial build caught Swift's throwing short-circuit syntax in the
no-window checks; explicit conditional clauses resolved it before tests ran.

Validation passed: 203 focused tests covering placement transactions, discovery/traversal,
janitor geometry, unit contracts, MCP translation, playbook consistency, and lease authorization.
`make verify-release` passed 1097 Swift tests, Viewer installer transaction checks, 11 Node tests,
and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-placement-discovery-focused-complete.log` and
`/tmp/spaceo-placement-discovery-release.log`. No native window movement, live qualification,
host installation, Viewer source change, or publishing occurred. AE-115 and AE-116 are fixed;
AE-117 and the remaining AE-111/AE-105 work stay open. The project goal remains active.

## 2026-09-22 — Bounded launch readiness and cheap absence preflight

Previous turn made verified progress with 1097 passing Swift tests. The remaining launch poll
still used legacy whole-array discovery under a wall-clock deadline, accepted late results, and
slept a full interval even when less time remained. No-window preflight used the new checked
discovery but still read every title and frame solely to decide whether the list was empty.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-111 | Launch polling still uses unbounded legacy window discovery. | Use checked paged discovery for public window waits and a bounded identified-window probe before launch placement. | Launch polling migrated; general refresh/watchers/teardown remain open. |
| AE-117 | `allow_no_windows` reads complete window details for a zero/nonzero decision. | Use exactly one checked AX count query, with process identity checked before/after. | Implemented; zero, large positive, failed, and negative count tests. |
| AE-118 | Window readiness polling uses a wall clock, starts each discovery with a fresh budget, accepts late observations, and can oversleep its remainder. | A monotonic, injectable polling loop passes the remainder into each probe, validates identity/permission before and after, rejects late observations, and clamps sleep. | Implemented; fake-clock regression coverage. |
| AE-119 | Timeout diagnostics truncate fractional seconds, reporting a subsecond timeout as zero seconds. | Preserve the requested fractional duration in window-not-ready errors. | Implemented. |

Launch readiness checks for at least one resolved window ID and leaves titles/geometry to the
immediately following checked placement. A count alone is insufficient for readiness when AX
window entries exist but their IDs are not yet available; unresolved IDs keep polling. The separate
no-window decision only asks whether a successful count is zero, so it needs no pages or identities.
Provider errors and invalid counts never become absence; full placement still enforces complete
discovery and its resource limits after a positive presence probe.

The public `waitForWindow` signature/result remains unchanged and still returns complete window
records. Both readiness paths use the shared monotonic runtime, bounded discovery envelopes, and
the same cancellation and process/permission checks. A discovery deadline can retry only while
the overall deadline permits it. Provider/resource failures propagate; they are not silently
retried as empty lists. No detached native task or early authority release is introduced.

Synthetic evidence: a no-window preflight requires one count call and zero pages/title reads or
accounted window allocation even when the reported count is `Int.max`. A 70-window launch probe
with its first ID ready uses three calls (count, one page, one ID) instead of the 144-call full
discovery; 70 unresolved IDs do not establish readiness. Full discovery/placement remains mandatory
afterward. Tests cover oversized/short pages, remaining-budget propagation, clamped final sleep,
late results, returned observation values, failed providers, per-probe deadline retry, process
replacement during a probe, validation consuming the deadline, cancellation, and invalid limits.
These are deterministic provider/polling comparisons, not native launch-throughput measurements.

Validation passed: 178 focused tests covering window readiness, count/identity discovery,
placement transactions, unit contracts, playbook consistency, MCP translation, and existing bridge
readiness. `make verify-release` passed 1109 Swift tests, Viewer installer transaction checks,
11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-window-readiness-focused-final.log` and `/tmp/spaceo-window-readiness-release.log`.
No native application launch, window mutation, live qualification, host installation, Viewer
source change, or publishing occurred. AE-117, AE-118, and AE-119 are fixed; general refresh,
watcher/teardown discovery, and remaining backend deadlines stay open. The project goal remains active.


## 2026-09-22 — Checked watcher discovery and permanent stop

Previous pass completed with 1109 passing Swift tests. Watcher sweeps still consumed the legacy
best-effort window list, so a failed query looked like every window had closed and erased refusal
history. Coalescer cancellation also did not permanently stop later callbacks from starting work.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-111 | Watchers enumerate full AX window arrays without checked completeness or an aggregate discovery budget. | Use checked paged discovery with the existing two-second, 256-window, 2048-call, 2 MiB limits; validate the original process identity and check stop/deadline between operations. | Watcher discovery migrated; general refresh and teardown enumeration remain open. |
| AE-120 | Failed watcher enumeration clears refusal history as though all windows closed, hiding incomplete containment. | Change tracked windows only after complete discovery; retain a bounded 512-byte failure diagnostic and include it in session audits until a successful sweep. | Implemented; deterministic failure/recovery and session aggregation tests. |
| AE-121 | Cancelling the sweep coalescer resets its state but permits late callbacks to start another sweep after stop. | Add a permanent stopped flag at admission and continuation boundaries; cancel queued repeats. | Implemented; late, reentrant, and in-progress stop boundary tests. |
| AE-122 | Watcher moves still resolve each element independently after discovering the complete window list. | Reuse handles from checked discovery, following the placement transaction approach. | Implemented in the watcher handle pass below. |
| AE-123 | Teardown evacuates windows before stopping watchers, and stop does not drain a native move already entered. A watcher can move a window back onto a released tile. | Stop all watchers before teardown work; track admitted sweeps through callback return and retain the complete resource ledger with a retryable incomplete report until every sweep finishes. | Implemented in the quiescence follow-up below; no blocking drain or detached native work. |

The watcher driver is injected for tests without native AX calls, observers, timers, window
movement, or displays. Tests preserve refusal history across incomplete discovery, clear it after
confirmed closure, avoid repeatedly moving unchanged refused geometry, retry changed geometry,
reject work after stop, cancel a queued reentrant sweep, and prevent a post-move bounds query or
second move after stop during the first move. Process replacement after discovery prevents any
containment query or mutation. Session aggregation reports the app name and failure; source
inspection confirms audit findings make verification unsuccessful. A live audit is not run.

The sweep deadline bounds discovery and admission of subsequent work. A native move already
entered retains its own lookup/settle behavior and cannot be preempted; this is not a hard
two-second end-to-end sweep or a draining stop. Diagnostic strings are bounded, and incomplete
discovery never publishes a partial window list. Existing containment rechecks and refused-frame
deduplication remain in place.

Validation of checked discovery and permanent stop passed 103 focused tests and the full
`make verify-release`: 1117 Swift tests, Viewer installer transaction checks, 11 Node tests,
and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-watcher-discovery-focused-complete.log` and
`/tmp/spaceo-watcher-discovery-release.log`.

### Quiescence before teardown evacuation

Further inspection confirmed teardown left watchers active until after evacuation and ownership
release. Teardown now stops all watchers first. An explicit active-sweep count remains nonzero
through discovery, moves, and placement callbacks, independently of coalescer cancellation.
Admission and accounting share the watcher lock; stopped watchers cannot acquire new work.
The count also covers the brief handoff between successive admitted sweeps.

If any stopped watcher still has work, teardown returns its existing structured incomplete report
with the pending session and attached display, before input-route capture, window discovery,
evacuation, app termination, or ownership release. The entire app/window ledger remains available
for retry. This avoids a blocking drain, which could deadlock a reentrant placement callback or
the main run loop. Once the admitted work returns, a retry runs the normal evacuation and
verification path. Teardown failure retains the stopped watchers too; retries cannot restart them.

Deterministic tests trigger teardown inside discovery, a native-move stand-in, and the placement
callback. They prove the first attempt leaves frames and ownership unchanged, retains the
session/display, and does not claim quiescence while a callback is still on the stack. In the
move case the simulated native mutation completes after stop, and the retry then evacuates that
window. All three cases release ownership only on the successful retry; late sweeps perform no
new move. A separate watcher test covers repeated stop and a cancelled coalesced request while
the original sweep still owns its active count. These tests use no native AX discovery, window
mutation, or watcher timers.


Validation of the quiescence follow-up passed 74 focused tests and `make verify-release`:
1119 Swift tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP
smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-watcher-quiescence-focused-complete.log` and
`/tmp/spaceo-watcher-quiescence-release.log`. No native window movement, application launch,
live qualification, host installation, Viewer source change, or publishing occurred. AE-120,
AE-121, and AE-123 are fixed. AE-122, the remaining AE-111 discovery consumers, and backend
latency limits remain open. The long-running project goal stays active.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-124 | The watcher's `handled` set is written and intersected on every sweep, but no decision or public statistic reads it; containment is always rechecked. | Remove the redundant retained set and its per-sweep maintenance, preserving refusal deduplication and placement counters. | Implemented in the watcher handle pass below. |


## 2026-09-22 — Reuse watcher handles and reduce sweep allocations

The previous pass made verified progress with 1119 passing Swift tests. Current-source review
confirmed AE-122's repeated element resolution and AE-124's unused handled-window set. It also
found two refusal collections maintained in parallel, unnecessary title reads, and a dictionary
rebuilt on every complete sweep even when its keys never changed.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-122 | Every watcher move repeats element lookup after complete discovery. | Retain the checked discovery's handles for that sweep and pass the exact handle to placement. Validate complete handle coverage before any containment work and revalidate process/window identity before native mutation. | Implemented; one-discovery, missing-handle, wrong-process, and retention tests. |
| AE-124 | The handled-window set is write-only bookkeeping. | Remove the set and all its updates; keep authoritative containment checks on every sweep. | Implemented; contained and subsequently escaped windows covered. |
| AE-125 | A refused-ID set duplicates the keys of the refused-geometry dictionary and requires parallel updates. | Use the geometry dictionary as the sole refusal ledger and derive the public count from it. | Implemented; unchanged/changed geometry, explicit release, closure, and external containment tests. |
| AE-126 | Watchers without placement callbacks still read and allocate every window title even though containment only uses identities and frames. | Request titles only when the public placement callback exists; retain full callback titles with the existing discovery bounds. | Implemented; title-free and title-preserving synthetic discovery paths. |
| AE-127 | Every complete sweep builds a live-ID set and replaces the refusal dictionary even when there are no refusals or no closed refused windows. | Skip pruning when the ledger is empty; otherwise remove only closed keys in place, preserving unchanged records. | Implemented; selective closure and unchanged-refusal retry coverage. |

The injected watcher driver now returns a sweep-local result containing windows and a move
closure over the immutable handle map. No per-window closure or long-lived handle cache is
introduced. The discovery budget accounts for retained handles; successful, failed, cancelled,
and incomplete sweep paths release the result when the sweep ends. Native moves share the
placement transaction's retained-handle implementation, including the exact original process
identity, per-element timeout, and window-ID revalidation. Missing/stale handles cause failure
rather than a new lookup. The shared move also explicitly rejects mismatched process identities.
Original stop/deadline checks, post-move containment proof, refusal deduplication, callback data,
and teardown quiescence remain in force.

Synthetic evidence: a 70-window watcher fixture uses one complete discovery and exactly the 70
returned handles for 70 moves. Discovery takes three pages (32/32/6) and 74 provider calls without
titles, versus 144 with titles. A synthetic 3 MiB title is never requested on the title-free path;
accounted discovery allocation stays below 32 KiB in both ordinary fixtures including handle
storage. These counts cover discovery; native mutation/settle calls are represented by injected
operations and are not included. Retaining handles adds bounded temporary storage to avoid
repeated lookups; no claim of measured native throughput or whole-process RSS reduction is made.

Weak-reference tests confirm handles stay alive through movement and placement callbacks and
are gone after success, movement failure, or stop while the watcher itself remains alive. Other
tests reject missing handles and wrong-PID records before any containment query or move, prove
an unchanged refusal retries after explicit release, recontain a previously successful window
that escapes, and prune only the closed refusal while preserving the surviving retry guard.


Validation passed: 123 focused tests covering watcher behavior, AX discovery, placement,
blackout retention, janitor geometry, and session lifecycle races. `make verify-release`
passed 1125 Swift tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool
MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-watcher-handles-focused-complete.log` and
`/tmp/spaceo-watcher-handles-release.log`. No native window movement, application launch,
live qualification, host installation, Viewer source change, or publishing occurred.
AE-122 and AE-124 through AE-127 are fixed. Current-source inspection confirms general
`refreshWindows()` and its teardown consumers still use `windowDriver.windows`; those
remaining AE-111 consumers and backend latency limits stay open. The project goal remains active.


## 2026-09-22 — Transactional session refresh and incomplete teardown diagnostics

The previous pass made verified progress with 1125 passing Swift tests. General session refresh
still used the unbounded best-effort AX array, and teardown treated its result as sufficient to
release ownership. The wait-specific transactional refresh already provided checked discovery;
this pass shares that implementation across ordinary refreshes without an extra observed array.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-111 | General refresh and teardown still enumerate legacy whole-window arrays; the public compatibility list also remains unbounded. | Use one checked discovery budget across all session apps, commit only complete results, and bound the compatibility list through the same paged provider. | These consumers migrated; Electron pane root discovery remains under AE-131. |
| AE-128 | The `windows` command's timeout loop uses a wall clock and fresh per-probe budgets, sleeps a full interval, and performs another refresh after finding a match. | Reuse monotonic remaining-budget polling and avoid the redundant final discovery. | Implemented in the timed window-command pass below. |
| AE-129 | Retained cached windows consume a node but do not charge their retained title/record storage to the shared refresh allocation budget. | Account for title bytes and record storage before appending retained windows; preserve the old list when the budget fails. | Implemented; allocation regression test. |
| AE-130 | Teardown can mistake failed or partial discovery for a complete list and release ownership after evacuating only known windows. | Skip evacuation on discovery failure, retain the complete ledger, return an incomplete report with optional discovery diagnostics, and allow explicit quits of launched apps to recover an unresponsive provider. | Implemented; keep-apps, explicit-quit, retry, ownership, and wire tests. |
| AE-131 | `ElectronEditorPanes.editorFrames` copies the full AX window array to locate one root before recursive pane collection. | Use bounded window-root resolution and audit the recursive pane traversal budget. | Implemented in the checked Electron pane discovery pass below; deterministic provider evidence. |
| AE-132 | Adopted-app rollback evacuates and unregisters an app outside full session teardown; its watcher is stopped only at unregister, so it can overlap evacuation. | Extend the watcher quiescence requirement to rollback while preserving retained ownership and recoverability on incomplete rollback. | Implemented with temporary quiescent suspension in the rollback pass below. |

Ordinary refresh and waits now share transactional discovery and WindowServer ownership retention.
Only waits collect the separate freshly observed list needed for title matching; general refresh
avoids that extra array. One two-second/256-window/2048-call/2 MiB envelope covers all apps, with
process identity checks before and after discovery and retained-window reconciliation. Incomplete
discovery preserves the exact window list and snapshot history. A bounded 512-byte diagnostic
remains until successful refresh. The public nonthrowing `refreshWindows()` keeps its signature
and returns cached windows with `windowRefreshFailure`; commands that promise a fresh list and
target selection use throwing refresh. Audits include incomplete discovery, and re-parking or
adopted-app rollback performs no evacuation from an incomplete list.

Already-completed place/re-park actions retain their receipts and add a post-refresh warning.
Reusing an app similarly reports a refresh warning without losing the result of opening files.
Teardown never moves from an incomplete discovery result or releases its app/window ledger;
explicit quit still signals only apps SpaceO launched, and normal input-route restoration runs
before the incomplete return. A later retry completes ordinary evacuation once discovery works.
The optional `windowDiscoveryFailures` field survives wire round trips and merged reports, makes
completion false, and supplies the reason in recovery text. Old reports without it still decode;
required ownership fields remain required.

The public `WindowPlacement.windows` compatibility helper now uses bounded paged discovery and
original-process identity checks. Its nonthrowing empty result remains ambiguous (absent versus
unavailable/over-budget) and is documented as such; internal session commands no longer use it to
prove absence. No hard native-call or whole-command wall-time guarantee is claimed.

Tests exercise real manager read/list errors and recovery against injected providers, prove zero
legacy enumerations, preserve cache/history after failure, prevent movement and explicit target
resolution on failed refresh, reject a 257-window partial result, charge retained storage, and
retain ownership through failed teardown with and without explicit quitting. Successful retry
then evacuates and releases ownership. The first expanded build exposed an ambiguous SDK
`WindowRef` type name in a new test helper; qualifying `SpaceOKit.WindowRef` resolved it.


| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-133 | Several process/ledger tests inject fake process behavior but rely on the test constructor's default live window driver. Failed native AX reads previously appeared as empty lists, masking this nondeterministic dependency. | Require an explicit window driver in the internal test constructor; provide a shared windowless fixture that rejects any attempted move, and inject failing observer factories where the fixtures can reinstall watchers. | Implemented in teardown failure, persistence, and reclamation fixtures. |

The expanded check initially produced seven assertions in two teardown tests: their simulated
processes had exited but their real test-process identities still existed, and checked native AX
discovery correctly refused to establish an empty window list. The tests now explicitly model
windowless fake apps. Production checks were not weakened. Compile-time injection requirements
prevent future tests from silently inheriting the live window driver. The shared assertion helper
also required an explicit XCTest import, added before the final checks.


The first full release check found one capture-fixture assumption: every checked discovery was
asserted to omit titles, including teardown's newly checked ordinary refresh. The fixture now
counts title requests and asserts no increase specifically around direct capture exclusions and
recording evidence (including their failure paths). Teardown can request titles normally. The
capture/teardown/playbook regression pass then passed 42 tests; the full check was rerun.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-134 | Session evacuation and re-parking still invoke single-window movement for each discovered window, repeating bounded native element lookup after the session list is known. | Extend sweep-local retained-handle movement to these multi-window paths while preserving ownership checks and receipts. | Implemented in the session movement pass below; deterministic batch and handle-lifetime evidence. |


Final validation passed: 229 focused tests plus the 42-test capture/teardown regression pass.
`make verify-release` passed 1131 Swift tests, Viewer installer transaction checks, 11 Node tests,
and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-session-discovery-focused-complete.log`,
`/tmp/spaceo-session-discovery-capture-regression.log`, and
`/tmp/spaceo-session-discovery-release-final.log`. No application launch, native window mutation,
live qualification, host installation, Viewer source change, or publishing occurred. The earlier
fixture failure exposed native AX reads and those implicit test dependencies were removed.
General refresh/teardown/compatibility discovery and AE-129, AE-130, and AE-133 are addressed.
AE-128, AE-131, AE-132, AE-134, and remaining backend latency limits stay open. The goal remains active.


## 2026-09-22 — One deadline and no redundant refresh for timed window reads

The previous pass made verified progress with 1131 passing Swift tests. The current `windows`
command still used a wall-clock polling loop, reset discovery to two seconds on every probe,
slept a whole interval past its deadline, and rediscovered the full list after a successful match.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-128 | Timed window reads reset their probe budget, can accept late matches, oversleep, and discard a successful discovery only to query again. | Reuse the existing monotonic WindowReadiness loop, pass the remainder into transactional refresh, validate matching live apps before/after each probe, and return the successful result directly. | Implemented; manager-level fake-clock scenarios and existing polling tests. |
| AE-135 | Timeout text claims a running app has no window, although a window may exist without a timely confirmed observation. | Report that no matching window was confirmed before the deadline; align CLI/MCP/playbook guidance. | Implemented. |

A normal read still performs exactly one checked refresh. Timed reads retain their existing
100 ms poll interval, process/PID ownership checks, cancellation behavior, and operation/lifecycle
authority. Failed provider discovery propagates immediately. A per-probe discovery deadline may
retry only while the overall budget remains; late successful observations cannot become success.
No native task is detached or preempted. The polling deadline starts after command admission;
this change does not add a queue-admission deadline or promise to interrupt uncooperative native
calls. The session refresh path still caps each probe at its ordinary two-second resource envelope.

The real manager handler is tested using an injected monotonic clock and window provider. An
immediately ready window now needs one discovery instead of two. A match on the second probe
needs two discoveries instead of three. A 550 ms empty wait passes 550/450/350/250/150/50 ms
budgets and sleeps 100/100/100/100/100/50 ms. A simulated result at 600 ms is rejected without
another read or sleep. Provider errors stay errors; a probe deadline after 200 ms retries with
250 ms left after the ordinary 100 ms interval. Empty sessions and unowned PID filters start no
provider work or sleep. These are deterministic call/time-budget assertions, not native latency
measurements. Existing wait-loop cancellation and identity-change tests remain in the focused run.


| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-136 | Adopted-app rollback accepts any nonthrowing `WindowPlacement.move` result and unregisters the app without verifying that its windows left the agent display; a refused move can therefore release ownership prematurely. | Verify evacuation against authoritative bounds before unregistering and inject geometry operations for deterministic refusal tests; combine with AE-132 watcher quiescence. | Implemented in the rollback pass below. |


Validation passed: 77 focused tests covering command polling, readiness, ownership validation,
MCP translation, CLI arguments, and playbook consistency. `make verify-release` passed 1133 Swift
tests, Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-window-command-wait-focused-final.log` and
`/tmp/spaceo-window-command-wait-release.log`. No native window movement, application launch,
live qualification, host installation, Viewer source change, or publishing occurred. AE-128 and
AE-135 are fixed; Electron traversal, rollback quiescence/evacuation proof, repeated session move
lookups, and remaining backend latency limits stay open. The long-running goal remains active.


## 2026-09-22 — Verified rollback without watcher overlap or observer churn

The previous pass made verified progress with 1133 passing Swift tests. Current-source inspection
confirmed adopted-app rollback still moved windows while its watcher was active and accepted a
nonthrowing move as evacuation. Reusing existing injected geometry made those failures testable
without native windows and exposed further retry and multi-window evacuation issues.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-132 | A watcher can pull a window back during adopted-app rollback; permanently stopping it on every rollback attempt would disable containment if persistence later recovers. | Admit synchronous rollback only while the watcher is idle, temporarily fence new sweeps, and resume the same observer after failure. Coalesce notifications during suspension into one replay; successful unregister permanently stops the watcher. | Implemented; active discovery/move/callback and retry tests. |
| AE-136 | Returned movement is mistaken for verified evacuation. | Use injected geometry operations, check original process/owner before moves, rediscover after moves, and require live evacuation evidence before unregistering. | Implemented; refusal, partial overlap, later repositioning, closure, new-window, unavailable-display, and unknown-bounds tests. |
| AE-137 | Evacuation adds 28 pixels per window to a display-sized frame without limiting the result to the user display. | Reuse the existing bounded cascade for rollback and teardown. | Implemented; 70-window fixtures for both paths keep every requested frame on the user display. |
| AE-138 | Refresh drops a cached window when only its owner or bounds is unavailable; a later cleanup attempt can reinterpret the erased evidence as absence. | Treat partially unavailable cached identity/geometry as incomplete discovery and preserve the whole prior list. For live apps, only both-absent owner/bounds or a known different owner permit removal. | Implemented; ambiguous owner blocks targeting, rollback, and teardown; unknown bounds plus an AX blackout remains incomplete across retries. |
| AE-139 | Full teardown checks only windows enumerated before evacuation, missing newly opened dialogs or post-move discovery failures. | Refresh again before release and share a live evacuated/stranded/unknown classification with rollback. Retain the ledger and report uncertainty when geometry cannot be verified. | Implemented; post-move dialog, provider failure, and unavailable-geometry scenarios. |

The temporary watcher suspension is synchronous and nonblocking at admission. A sweep or its
placement callback must return before rollback can start; a reentrant attempt simply returns
incomplete. Nested suspension also refuses admission. Failed rollback lifts the fence and replays
one coalesced request without creating an observer or detaching native work. Stop always wins:
when unregister permanently stops the watcher, deferred notifications cannot restart it. The
existing session operation/lifecycle authority still covers rollback resource work.

Adopted apps are never terminated. Missing/invalid user-display geometry, failed discovery,
refused movement, partial overlap with any part of the agent display, and unconfirmed final
bounds all retain ownership. All moves finish before verification, so a later move that resizes
or relocates an earlier window back onto the display is detected. A second checked discovery
includes dialogs opened during movement; this extra query is required for evacuation evidence.
Native per-window lookups and move/settle latency remain under AE-134 and the backend latency
work rather than being described as an end-to-end bounded evacuation.

Rollback and teardown share three explicit verification outcomes: evacuated, stranded with live
bounds, and unknown. Missing bounds count as closure only when the window driver also reports no
owner. Invalid bounds are unknown. The full teardown report carries uncertainty in its existing
optional discovery diagnostics and retains the full app ledger. Transactional refresh likewise
refuses a partially unavailable cached identity, preserving evidence without making it targetable:
commands still require successful checked refresh, and the audit remains incomplete. Known
recycled identities are dropped; ordinary confirmed closure still clears history as before.

Tests use fake displays, geometry, process operations, and watcher callbacks. The same watcher
factory is called once through failed and successful rollback; requests arriving during evacuation
run only after its temporary fence lifts. Tests cover three reentrant phases, several movement
outcomes, repeated unknown-geometry failure with AX omission, ambiguous owner recovery, newly
opened windows during rollback and teardown, post-move provider failure, and 70-window cascades.
No native observer or native window mutation is needed for these assertions.


Validation passed: 153 focused tests covering rollback, watcher suspension, session retention,
persistence reconciliation, teardown failures/responsiveness, capture exclusions, waits, and
playbook consistency. `make verify-release` passed 1141 Swift tests, Viewer installer transaction
checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-rollback-containment-focused-final.log` and
`/tmp/spaceo-rollback-containment-release.log`. No native application launch, window mutation,
live qualification, host installation, Viewer source change, or publishing occurred. AE-132 and
AE-136 through AE-139 are fixed. Electron pane traversal (AE-131), repeated session movement
lookups (AE-134), and remaining native/backend latency limits stay open. The goal remains active.


## 2026-09-22 — Checked and bounded Electron pane discovery

The previous pass made verified progress with 1141 passing Swift tests. Electron scroll and
selection still located their AX root through a whole window array and recursively copied whole
child arrays. Per-branch prefixes and silent depth limits neither bounded total work nor proved
that the returned pane list was complete.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-131 | Pane root lookup and recursive collection copy whole provider arrays without an aggregate deadline, call, node, or allocation budget. | Checked 32-element paging, a 256-window root limit, and one two-second/1500-node/8000-call/2-MiB discovery budget; apply a bounded messaging timeout to every queried element. | Implemented; deterministic paged-root and wide-tree tests. |
| AE-140 | Failed, truncated, or missing-geometry pane discovery becomes an empty/single-pane result, allowing scroll or selection to act on the active editor from incomplete evidence. | The action router uses throwing discovery and propagates provider/budget errors. Recheck exact root identity and original process identity before returning. | Implemented; partial-pane failures never reach the active-editor fallback. |
| AE-141 | The old 64-pane limit is checked only on function entry, allowing sibling appends beyond it; repeated/cyclic elements multiply work and silently truncated branches can hide another pane. | Enforce the cap before every append, finish remaining branches even at 64, track visited elements, and refuse unvisited descendants at the depth boundary. | Implemented; 64/65 siblings, late failure, cycles/shared subtrees, and depth tests. |
| AE-142 | Point resolution deduplicates frames, then calls ordering which deduplicates the original frames again. | Share ordering of already-distinct frames between public ordering and resolution. | Implemented; existing geometry and routing regressions. |

The native checked provider distinguishes absent optional subroles/children from messaging
failure, invalid elements, malformed values, and unsupported process accessibility. A missing
optional attribute can establish a leaf; a failed announced page cannot. Window and child page
cardinality must match the checked count. Negative and oversized counts refuse before allocation.
Matched Monaco surfaces prune their inner content groups; small proxies still descend. Pane
geometry must be present, finite, nonnegative, and have finite outer edges. No partial frame list
escapes a failed traversal. The compatibility `editorFrames` signature remains nonthrowing and
bounded, with documented ambiguous empty results; production actions use the checked path.

Complete zero/single-pane AX layouts preserve the existing active-editor behavior after the
caller's editor hit test. Grid layouts and points outside a split remain refused. This is not an
atomic native layout snapshot or an end-to-end action deadline: hit testing and subsequent editor
bridge calls retain their own behavior, and private/native calls still require live qualification.
No background native worker is detached to enforce this discovery deadline.

Fake providers cover a 70-window root and a pane after 199 non-pane siblings, using pages no
larger than 32 and less than 16 KiB of accounted aggregate discovery allocations. That assertion
measures the request accounting, not resident memory. Only the exact target subtree receives
subrole/geometry queries; no window titles, node labels, actions, or full AX snapshot are read.
Tests also cover failed/short/oversized pages, huge counts, missing/invalid geometry, strict pane
limits, deep/wide/cyclic/shared trees, cancellation, expired results, shrinking descendant
messaging timeouts, rejected timeout setup, and changed root identity. All providers are fake;
no native Accessibility enumeration or application mutation is used.


Validation passed: 43 focused tests covering checked pane discovery, point routing, editor
bridge behavior, and playbook consistency. `make verify-release` passed 1154 Swift tests,
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-electron-pane-focused-final.log` and
`/tmp/spaceo-electron-pane-release.log`. No native Accessibility enumeration, application launch,
input, live qualification, host installation, Viewer source change, or publishing occurred.
AE-131 and AE-140 through AE-142 are fixed. Repeated session movement lookups (AE-134) and
remaining native/backend latency limits remain open. The long-running goal remains active.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-143 | `SessionAppTeardownDriver.live.waitForExit` uses wall-clock `Date()` and unconditional 120 ms sleeps, so clock changes can extend cleanup and the last sleep can exceed the remaining wait. | Replace with an injectable monotonic process-exit wait that caps its final sleep and preserves conservative ownership when liveness is unconfirmed. | Implemented in the process-exit wait pass below; no native process termination exercised. |


## 2026-09-22 — Monotonic cleanup waits with in-place survivor tracking

The previous pass made verified progress with 1154 passing Swift tests. Inspection confirmed
the session teardown wait still used wall time and full 120 ms sleeps; detached recovery had a
second copy of the loop, including allocation of a new filtered array on every probe.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-143 | Session teardown and undurable-launch rollback use wall-clock deadlines and can sleep beyond their remaining process-exit wait. | Share ProcessExitWait with a monotonic clock, capped final sleep, deadline checks before/after liveness reads, and retained unconfirmed entries. | Implemented; fake-clock and session ownership/retry evidence. |
| AE-144 | Detached recovery duplicates the wait loop, and both paths rebuild survivor arrays on each polling pass. | Reuse the same helper in both production adapters; compact the pending array in place and never recheck confirmed exits. | Implemented; deterministic recovery tests now run the helper through their fake process world. |
| AE-145 | App launch reveal, DevTools marker polling, and failure cleanup still use wall-clock deadlines and swallow cancelled Task.sleep errors. A cancelled task can repeatedly perform provider/file work without sleeping; failed-launch cleanup also waits on a bare PID after forcing termination. | Audit these launch phases with cancellation-aware monotonic waits, exact-identity cleanup, and tests that distinguish cancelled useful work from cleanup responsibility. | Implemented in the launch polling pass below; no native launch or termination exercised. |
| AE-146 | DevTools marker discovery reads the complete DevToolsActivePort file on every retry although it only needs one small port line. | Bound the marker read and test oversized/malformed files while preserving valid Chromium discovery. | Implemented in the launch polling pass below. |

ProcessExitWait is a synchronous helper for the existing cleanup worker and detached recovery
paths; it does not introduce a new worker, release lifecycle authority, or detach native work.
The production runtime reads DispatchTime uptime and sleeps at most the smaller of 120 ms and
the remaining deadline. Timeouts are capped at 30 seconds; zero, negative, and nonfinite inputs
perform one immediate liveness scan with no sleep, preserving existing no-wait behavior. The
normal session caller still normalizes its own timeout before calling the driver.

For positive waits, a process check that returns after the deadline cannot erase ownership.
An expired scan preserves its unqueried suffix and starts no more liveness calls; oversleeping
does not trigger another probe. Each backend retains its existing process-identity semantics
and termination checks. The helper requires uncertain liveness to remain pending; it does not
change the underlying process-query API's interpretation of absence. Native query/scheduler
latency still cannot be preempted, so this is a bounded polling policy rather than a promise of
hard response latency. Graceful and force phases keep their separate existing budgets.

Deterministic tests cover immediate/empty results, shrinking sleeps, confirmed exits dropping
out of later polls, stable survivor order, early completion, late process results, a deadline
expiring mid-scan, late wakeups, invalid/zero/huge durations, nanosecond overflow, and identity
replacement versus uncertain liveness. A 550 ms pending wait requests four 120 ms sleeps and
one 70 ms sleep, with no new probe at the deadline. The session integration test also accounts
for the independent three-second force phase, verifies the retained process claim/display,
and confirms a successful retry adds no sleep. Recovery integration fixtures use the same
helper with an independent fake monotonic clock. No wall clock, real sleeping, or process
termination is required for the new timing assertions. Survivor-buffer compaction removes a
repeated allocation in source; no resident-memory benchmark is claimed.


Validation passed: 95 focused tests covering process-exit polling, ownership retention/retry,
rollback, session persistence, teardown responsiveness, and detached recovery. The first expanded
run exposed an incomplete test expectation: default session destruction also waits through its
existing three-second force phase. The corrected assertion covers both phase budgets without
changing production force behavior. `make verify-release` passed 1163 Swift tests, Viewer
installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check`
passed. Logs: `/tmp/spaceo-process-exit-focused-final.log` and
`/tmp/spaceo-process-exit-release.log`. No native application launch, process termination,
Accessibility enumeration, input, live qualification, host installation, Viewer source change,
or publishing occurred. AE-143 and AE-144 are fixed. AE-134, AE-145, AE-146, and remaining
native/backend latency limits stay open. The long-running goal remains active.


| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-147 | The full build emits existing unreachable-default/unused-binding warnings in AppLauncher, SessionManager+Ergonomics, WindowWatcher, and ViewerModel, plus Sendable-conversion warnings in Viewer mailbox tests. This obscures new diagnostics and would fail a warnings-as-errors gate. | Remove dead bindings/defaults, explicitly handle ignored return values, and make test callback sendability intentional; rerun the applicable build/test/Viewer checks. | Fixed; explicit callback closures and ignored results, preserved weak ownership checks, and removed unused bindings. Validation recorded below. |


## 2026-09-22 — Cancellable launch polling and bounded DevTools discovery

The previous pass made verified progress with 1163 passing Swift tests. Current launch code
confirmed wall-clock loops and swallowed cancellation in marker discovery, reveal, settle waits,
and failed-launch process cleanup. Marker discovery read the entire provider-written file on
each poll. These paths are now bounded without skipping the durable materialization callback.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-145 | Cancelled launch sleeps are swallowed, turning polling into repeated immediate work; cleanup also waits on a bare PID. | Reuse monotonic BridgeReadiness for marker/reveal waits, propagate cancellation from settle and polling, and await an independent cleanup task with exact-identity checks and separate bounded graceful/force phases. | Implemented; cancellation, late result, identity loss, escalation, and replacement tests. |
| AE-146 | Marker polling allocates and decodes the whole DevToolsActivePort file, even though only the port line is needed. | Open nonblocking/no-follow, check the opened regular file is at most 4096 bytes, cap the read at 4097 bytes, and parse only a complete ASCII decimal port line. | Implemented; malformed, partial, boundary, sparse-file, symlink, directory, and FIFO fixtures. |
| AE-148 | BridgeReadiness checks its deadline before validation but can start a probe after validation consumes the deadline or cancels the request. | Recheck cancellation and monotonic deadline immediately after validation. | Implemented; validation-expiry and validation-cancellation tests forbid provider work. |
| AE-149 | Launch repeatedly reads bundle classification and creates private profiles/adapters before rejecting incompatible mute/custom-argument options. | Classify once and reject these options before allocating private resources; reuse the classification for launch configuration. | Implemented; existing option/detection regressions retained, no native launch benchmark claimed. |

Marker reads no longer allocate a file-sized String or split the entire contents into lines.
A valid first line has one through five ASCII digits followed by LF (CRLF is also accepted),
and a port in 1...65535. Requiring the newline prevents an incomplete write such as `43` from
being mistaken for the completed port. The endpoint suffix remains outside this parser's role;
the existing DevTools bridge validates endpoints separately. Missing or invalid markers remain
unready and can be retried within the existing readiness interval. Files above 4096 bytes and
non-regular/symlink entries are rejected. The single bounded read also handles growth after stat;
short reads without a complete line and read errors remain unready. Filesystem syscall latency
is not preempted, and this is not a whole-launch response-time guarantee.

Launch keeps the materialization callback before post-launch cancellation checks so a real
process is registered/persisted before cleanup can be needed. Cancellation before dispatch
cleans prepared resources and remains a CancellationError. Post-materialization polling and
settle cancellation enter the existing catch path. Reveal checks original-process liveness
before/after probes and no longer sleeps after visibility is already confirmed. A cancelled or
expired bridge validation starts no further provider probe. The existing window placement,
watcher, launch-substitution, and process ownership safeguards remain in force.

Failed-launch cleanup uses an independent task whose completion is awaited. Cancelling the
parent does not cancel the cleanup sleeps or let the launch release its lifecycle authority
early. Graceful and forced waits each have a two-second monotonic budget and at most 100 ms
sleeps. Termination is attempted only for an owned launched app with a precise matching identity;
a precise replacement ends the wait for the original process, while missing precision remains
unknown and never authorizes force. Production quit still performs its own identity check.
Resource cleanup runs once through the existing helper, which rechecks liveness before removal
and retains deferred cleanup responsibility for survivors. The original launch error propagates
after the awaited attempt. A cleanup deadline does not claim termination or authorize deleting
live profile state. The preexisting eventual resource-cleanup worker remains separate.

New tests use fake process identities/clocks and disposable marker files, with no native app
launch, reveal, Accessibility work, input, or termination. Tests cover a cancelled parent awaiting
both cleanup phases while preserving its original cancellation, immediate/graceful/forced exits,
PID replacement, initially/later imprecise identities, adopted apps, hidden-state refusal,
cancelled and late probes, a partial marker becoming complete, 4096/4097-byte boundaries, and a
64-MiB sparse marker refused without loading its payload. The AppLauncher unreachable-default
warning from AE-147 was also removed while changing argument construction; the remaining
warning cleanup is still open.


Validation passed: 121 focused tests covering launch polling/cleanup, marker parsing, bridge and
window readiness, materialization persistence, temporary-resource recovery, editor/Chromium
bridges, and ownership budgets. `make verify-release` passed 1179 Swift tests, Viewer installer
transaction checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Logs: `/tmp/spaceo-launch-polling-focused-final.log` and
`/tmp/spaceo-launch-polling-release.log`. No native application launch/reveal, process termination,
Accessibility enumeration, input, live qualification, host installation, Viewer source change,
or publishing occurred. AE-145, AE-146, AE-148, and AE-149 are fixed. AE-134, the remainder of
AE-147, and remaining native/backend latency limits stay open. The long-running goal remains active.


## 2026-09-22 — Reuse session movement handles without extending their lifetime

The previous pass made verified progress with 1179 passing Swift tests. Session refresh already
performed checked discovery, but rollback, re-parking, and teardown evacuation still resolved
each AX window again while moving it. This repeated the app's window pages and ID queries for
every discovered window, despite already having the correct handles during enumeration.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-134 | Session multi-window movement repeats bounded window-root searches after discovery. | Retain handles only for apps selected for movement, reuse them in rollback/re-parking/evacuation, and release the movement capability before post-move verification or process waits. | Implemented; 70-window batches, no-fallback counts, and weak-reference lifetime checks. |
| AE-150 | Native WindowPlacement.move still settles with a wall-clock one-second deadline and unconditional 20 ms sleeps, and its fallback geometry reads have no shared remaining-time budget. | Replace settling with a monotonic, injectable observation loop that caps its final sleep and preserves truthful unknown/refusal outcomes and native authority. | Implemented in the bounded movement pass below; deterministic provider and clock evidence. |

SessionWindowMovement holds a discovered list and one movement closure capturing its handle
map. Its checked constructor refuses incomplete handle coverage or foreign-process windows.
Each move validates the original process and uses the retained native placement path, which
rechecks the handle's window ID and messaging timeout. A failed retained-handle move never
silently looks up a replacement handle. Transactional refresh still completes across all apps
before the movement body starts; failed discovery preserves the previous window cache and
releases any handles already collected.

An operation-local scope selects which apps need movement handles. Ordinary reads, waits,
capture exclusions, verification refreshes, and apps being quit rather than evacuated still use
ordinary checked discovery. Handle-map entries remain charged to the discovery allocation
budget; per-app movement storage is charged too. Nothing is added to the durable or in-memory
session window cache. The scope ends before the follow-up refresh or teardown's potentially
long process waits, and no closure/AX handle is retained for a later session operation.

Known windows omitted by Accessibility remain important containment evidence. Refresh still
requires live owner/bounds before retaining them. Such a cached window has no discovered handle,
so it keeps a bounded single-window recovery lookup. That fallback now carries the original
process identity into lookup and final placement instead of recapturing a possibly replaced
process. The fallback is not used for windows already discovered. Returned movement remains an
attempt: re-parking counts authoritative landed bounds, and rollback/teardown rediscover and
verify evacuation before ownership release. Watcher quiescence and rollback suspension remain
unchanged.

The fake window server now supplies handle-backed movement capabilities, so existing blackout,
refusal, owner ambiguity, new-window, and rollback tests exercise the new route. A 70-window
rollback or evacuation performs one movement discovery plus the required post-move discovery,
with 70 retained-handle moves and zero fallback lookups. Successful re-parking has the same two
discoveries; refusal has one and reports zero landed windows. Ordinary reads create no movement
handles. Weak references verify all 70 handles remain live during moves and are gone before
verification, after refusal, after invalid-display rollback, and after incomplete cached-window
retention. A blackout fixture still recovers through its bounded fallback. These are deterministic
query-route and lifetime assertions, not native latency or resident-memory measurements.


Validation passed: 144 focused tests covering handle movement, blackout retention, watcher
quiescence, rollback, capture exclusions, persistence, reclamation, and teardown responsiveness.
`make verify-release` passed 1185 Swift tests, Viewer installer transaction checks, 11 Node tests,
and the 32-tool MCP smoke check. `git diff --check` passed. Logs:
`/tmp/spaceo-session-movement-focused-final.log` and
`/tmp/spaceo-session-movement-release.log`. No native application launch, window movement,
Accessibility enumeration, input, live qualification, host installation, Viewer source change,
or publishing occurred. AE-134 is fixed. AE-147's remaining warnings, AE-150's native settling
loop, and remaining native/backend latency limits stay open. The long-running goal remains active.


## 2026-09-22 — Bounded movement mutation and truthful settling observations

The previous pass made verified progress with 1185 passing Swift tests. Native movement still
ran three AX mutations with individual timeouts, then began a fresh wall-clock settling wait.
Fallback AX frame reads could spend another full timeout past the polling deadline, and the
last fallback could return the requested frame without ever observing geometry.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-150 | Window movement resets its wait after mutation, polls with wall time, sleeps a full interval at the deadline, and uses unbudgeted fallback frame reads. | Share one one-second monotonic movement budget across window-ID validation, position/size/position requests, and geometry observation; cap each AX call and final 20 ms sleep to the remaining time. | Implemented; fake native-provider order, time-budget, refusal, and fallback tests. |
| AE-151 | AXTraversalBudget computes remaining time using two clock reads in one UInt64 subtraction, which can underflow if the deadline passes between them; boundedCall can dispatch after timeout setup exhausts its deadline. | Read the clock once for the remainder and recheck budget/cancellation after messaging-timeout setup, before starting provider work. | Implemented; expiry-boundary arithmetic and expired-setup tests, plus existing traversal regression coverage. |
| AE-152 | Native move can return the requested rectangle when no geometry is available; degenerate or invalid observations can also satisfy its size-only landing predicate. | Return only valid, timely observed geometry; throw an explicit unconfirmed-geometry deadline error if none was obtained. Invalid raw sizes, nonfinite coordinates/extents, and overflowing outer edges cannot establish arrival. | Implemented; absent/invalid/late geometry and failed-setter tests. |

WindowMovement contains the injectable mutation/settling sequence used by the retained native
placement path. Successful WindowServer bounds avoid AX fallback entirely. When they are absent
or invalid, position and size are separate bounded calls; each receives the current remainder,
and late results are discarded. Observation checks retain process identity before and after the
read. Fallback preserves the prior AX.frame short circuit when position is missing and also
skips size for nonfinite positions; its missing-position fixture performs 50 point reads and
zero size reads. The existing landing rule still permits grid-snapped sizes that fit the requested frame,
but a changed origin or oversized extent continues polling. Setter success/failure alone does
not prove delivery: an already-satisfied target can be confirmed through geometry even if a
setter refuses, while missing geometry never becomes success through an echoed request.

At expiry, the helper can return its last valid observation (which has not met the landing
predicate); existing callers still verify live containment/evacuation and produce their own
receipts. If no valid timely geometry exists, it throws instead of doing another unbounded
read or inventing a frame. This can surface an explicit failure for an unobservable or closed
window during movement; callers retain their existing rollback/retry behavior. There is no
extra final read and no detached native worker.

The new one-second budget begins before native window-ID validation and mutation, rather than
after the three mutations. AX calls retain the existing 250 ms ceiling and share a 256-call cap;
normal settling polls at most every 20 ms. Already-running native operations and scheduler
latency cannot be preempted, so the budget prevents further dispatch/late confirmation without
promising a hard wall-clock return time. Per-window lookup and an entire multi-window operation
remain separate scopes. Native retained-handle cleanup deliberately remains usable from a
cancelled task: placement rollback must still restore original windows. Admitting commands and
transaction loops retain their existing cancellation checks, and lifecycle/watcher authority is
held until synchronous movement returns.

Fake provider tests cover the exact position/size/position sequence, immediate WindowServer
success with no fallback or sleep, origin-only progress followed by grid-snapped completion,
refusal with a 15 ms final sleep in a 55 ms wait, unavailable geometry without an extra read,
shrinking fallback AX timeouts, late server/fallback results, mutation consuming the settling
budget, failed setters, invalid geometry, process/window identity changes, call limits,
rejected/expired timeout setup, cancelled-task rollback, and UInt64 expiry-boundary arithmetic.
A missing-geometry one-second fixture performs 50 bounded probes and sleeps, then refuses; a
late frame cannot replace an earlier refusal observation with a false arrival. All clocks,
provider operations, and process-validation callbacks in these tests are fake. No native
movement, Accessibility enumeration, input, or resident-memory benchmark is used.


Validation passed: 158 focused tests covering movement budgets, traversal, retained handles,
placement rollback, watcher quiescence, blackout retention, capture exclusions, persistence,
reclamation, and teardown responsiveness. `make verify-release` passed 1199 Swift tests,
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check.
`git diff --check` passed. Logs: `/tmp/spaceo-window-settling-focused-final.log` and
`/tmp/spaceo-window-settling-release.log`. No native window movement, application launch,
Accessibility enumeration, input, live qualification, host installation, Viewer source change,
or publishing occurred. AE-150 through AE-152 are fixed. AE-147's remaining warnings and
remaining native/backend deadline propagation stay open. The long-running goal remains active.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-153 | Watcher sweeps have a two-second discovery/sweep budget, but their retained-handle mover starts a fresh one-second movement budget. A move admitted near sweep expiry can still dispatch native work beyond the outer remainder. | Propagate the sweep remainder/stop condition into movement while retaining native authority until return; cover late admission and stop during movement with fake providers. | Implemented in the watcher movement budget pass below. |


## 2026-09-22 — Watcher movement shares the sweep deadline and remains retryable

The previous pass made verified progress with 1199 passing Swift tests. The native mover had
become bounded, but watcher discovery still handed it a fresh one-second budget. Inspection also
confirmed that a thrown movement error, or absent post-move containment, became cached refusal
history and could suppress another attempt while geometry remained unchanged.

| ID | Finding | Resolution | Status |
| --- | --- | --- | --- |
| AE-153 | Native movement can outlive the sweep remainder and ignores watcher stop during an entered mutation. | Pass the sweep budget through retained-handle movement and derive a child budget sharing its clock, deadline, cancellation, and aggregate counters while keeping the mover's own ceiling. | Implemented; late-admission, aggregate-call, stop-in-native-mutation, and child-budget tests. |
| AE-154 | Unconfirmed movement errors and unavailable post-move containment are cached as unchanged refusals, suppressing future containment retries. | Propagate movement/observation failure into the existing sweep diagnostic without creating refusal history. Cache only a completed movement with observed non-containment. | Implemented; unchanged-geometry retry, unknown-containment recovery, and refusal suppression tests. |
| AE-155 | Initial containment reads can finish after the sweep deadline and still erase refusal history or report a complete sweep; validation can also consume the budget before that read. | Check the sweep budget after validation and immediately after the containment query before changing history. | Implemented; late containment preserves a known refusal until a timely retry confirms containment. |

AXTraversalBudget now supports a synchronous child scope. Its deadline is the smaller of its
own cap and the parent's absolute deadline, using the parent's monotonic clock. Parent stop and
cancellation are checked throughout; native per-call timeout is capped by both scopes. Calls,
nodes, and aggregate allocation charges propagate to the parent, so creating another child
cannot replenish the outer budget. Local exhaustion refuses before consuming another parent
reservation. Siblings share the remaining parent counters. Child construction can handle a
sub-10-ms remaining deadline without rounding it up to a fresh minimum traversal timeout.

WindowWatcherDriver passes the same discovery/sweep budget into its native movement closure.
The movement scope keeps its one-second/256-call ceiling while sharing the sweep's two-second
and 2048-call limits. A stop during an entered native call cannot preempt that call, but prevents
later writes/reads once it returns. The active sweep count still covers the whole call and its
callbacks, so isQuiescent stays false until synchronous work actually returns. Independently
admitted rollback/evacuation moves keep their existing cancellation-resistant cleanup authority;
only moves with an enclosing watcher budget inherit that watcher's stop condition.

A failed movement now ends the sweep with the existing bounded failure diagnostic, preserving
retryability and prior history rather than manufacturing a verified refusal. Missing post-move
containment does the same. A real completed move whose window is observed outside its target
still records the unchanged-refusal guard, avoiding repeated ineffective movement. Deadline
checks also prevent late initial containment from clearing a previous refusal.

Deterministic tests run the actual generic movement pipeline through the watcher driver with
fake clocks/providers. Discovery consuming 1950 ms leaves 50 ms for movement, resulting in
20/20/10 ms sleeps and no placement/refusal claim at expiry. A fake sweep spending 2047 AX calls
in discovery permits the identity query but no mutation. A stop inside the first position write
leaves quiescence false during that call, prevents size/repeated-position writes, and becomes
quiescent only after return. Additional tests cover the mover's independent one-second ceiling,
5 ms inherited remainder, shared sibling/nested counters, parent stop, failed/unknown movement
retry, verified refusal suppression, and late containment preserving history. Two unused-return
warnings in WindowWatcher were also removed under AE-147; remaining warning cleanup stays open.


Validation passed: 169 focused tests covering inherited budgets, movement, watcher retries and
quiescence, traversal, retained handles, rollback, capture exclusions, persistence, reclamation,
and teardown responsiveness. `make verify-release` passed 1210 Swift tests, Viewer installer
transaction checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed.
Logs: `/tmp/spaceo-watcher-movement-budget-focused-final.log` and
`/tmp/spaceo-watcher-movement-budget-release.log`. No native window movement, application launch,
Accessibility enumeration, input, live qualification, host installation, Viewer source change,
or publishing occurred. AE-153 through AE-155 are fixed. The remaining AE-147 warning cleanup
and broader backend response-latency work remain open. The long-running goal remains active.


## Compiler diagnostic cleanup (AE-147)

Removed the remaining logged production and deterministic-test warnings so new diagnostics are
visible. Daemon drain returns its response directly; Viewer activity still requires a nonnil
agent action without binding an unused value. Mailbox tests pass explicit Sendable closures
capturing their existing synchronized holder. Teardown tests explicitly discard cleanup results,
and movement fixtures use explicit self in nested escaping closures. Weak-reference tests keep
weak mutable storage, with separate initialization, preserving lifetime assertions and the
package's Swift 5.9 language compatibility without adding unchecked Sendable annotations.

Validation: 100 focused tests passed, and the optimized warnings-as-errors build passed.
Full deterministic release checks passed again after the fixture correction below.
The ad-hoc Viewer bundle built and passed deep, strict signature verification.
No host installation or live qualification.


## Fake capture display retirement (AE-156)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-156 | Three recording capture fixtures report their fake display online forever, even after invalidation. Their queued deinitializers each wait ten seconds and serialize later display lifecycle work; the stranded-window test took 29.786 seconds in the full suite. | Derive the fixture's online list from synchronized attachment state so invalidation removes it immediately. Preserve intentionally stuck-display fixtures and all production retirement checks. | Fixed; ten focused tests pass in 0.073 seconds. Full-suite blocked-test time fell from 29.786 to 0.004 seconds. |


After the fixture correction, `make verify-release` passed all 1210 Swift tests, Viewer installer
transaction checks, 11 Node tests, and the 32-tool MCP smoke check. Swift suite wall time fell
from 56.180 to 29.101 seconds on this host; the formerly blocked test fell from 29.786 to 0.004
seconds. These are same-host deterministic-suite measurements, not native runtime benchmarks.
No compiler warnings were emitted in either full release pass. Logs:
`/tmp/spaceo-diagnostic-cleanup-focused.log`, `/tmp/spaceo-fixture-retirement-focused.log`,
`/tmp/spaceo-diagnostic-cleanup-release-final.log`, and
`/tmp/spaceo-diagnostic-cleanup-warnings-as-errors.log`.


`SPACEO_CODESIGN_IDENTITY=- make viewer`,
`codesign --verify --deep --strict --verbose=2 ".build/SpaceO Viewer.app"`, and
`git diff --check` passed. Viewer logs are `/tmp/spaceo-diagnostic-cleanup-viewer.log` and
`/tmp/spaceo-diagnostic-cleanup-viewer-signature.log`. AE-147 and AE-156 are fixed.
No Viewer launch, application input, native display creation, Accessibility enumeration,
host install, or publishing occurred. Browser/capture backend deadline propagation remains
open under AE-105; the long-running goal remains active.


## Browser observation deadline propagation (AE-105, AE-157, AE-158)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-105 | Browser wait probes inherit none of the wait remainder after window discovery: HTTP, queue admission, commands, and object cleanup can each outlive the request. | Carry one monotonic observation deadline through browser target and selector probes, bounding every stage without renewing the outer budget. | Browser implementation verified; 154 focused checks and the full release suite pass. Capture and uncooperative native-work limits remain open. |
| AE-157 | DevTools discovery accumulates each HTTP byte through AsyncBytes and has no caller-specific absolute transfer deadline, including time before response headers. | Accumulate bounded URLSession delegate chunks with a one-shot deadline and explicit task cancellation. Release accumulated data and callback ownership on completion, cancellation, or expiry. | Implemented; declared/streaming size limits, exact-limit data, stalled headers/body, and cancellation tests pass. |
| AE-158 | Title discovery can return the old bound target after an actor reentrant detach or reattach during HTTP discovery. | Validate the captured socket and target binding immediately after discovery, before either returning a title or detaching a missing target. Apply the same check to command target verification. | Fixed; a paused HTTP title read followed by detach refuses the stale observation. |

The outer deadline is constructed before crossing into the Chromium actor, so actor and command
queue residence spend the same budget. Existing public bridge APIs preserve their signatures;
wait probes use internal overloads with a deadline. Queue expiry removes the waiting caller.
Target parsing checks the remaining budget after decoding. Runtime.evaluate's engine timeout
is capped by the post-discovery remainder and its existing five-second ceiling. Socket send
and replies share the smaller of the remaining observation budget and the ten-second command
ceiling. Remote-object cleanup uses the same observation deadline; failed/expired cleanup
retires the original transport, and the wait receives a timeout rather than a successful match.
Discovery or queue expiry does not retire a healthy command transport. Cancellation keeps its
existing cancelled outcome. Ordinary HTTP transfers retain an absolute fifteen-second ceiling.

Delegate body accumulation enforces both Content-Length and streaming limits before appending
a chunk. It preserves request methods and the exact-limit body case, cancels the data task on
every exit, and clears retained payload/callback state before returning from timeout cleanup.
No extra worker task or independent reader survives a timed-out caller. Foundation callbacks
may still finish after cancellation; closed readers ignore their data. These bounds do not
claim to preempt synchronous Foundation parsing or native work on the active desktop.


Validation passed: 154 focused tests covering browser deadlines, discovery limits, target
binding, evaluation cleanup, wait outcomes, command ergonomics, and operation admission.
Ten new tests cover shared discovery/evaluation/cleanup accounting, expiry without starting
another phase, transport retirement after late work, queue expiry, stalled HTTP headers/body,
prompt cancellation, invalid/already-expired budgets, late titles, and detach during discovery.
The existing 66 browser tests also pass against the chunked HTTP implementation, including
exact response limits, oversized declared/streamed bodies, new-tab PUT requests, remote-object
cleanup, and deliberate target binding.

`make verify-release` passed all 1220 Swift tests (27.368 seconds), Viewer installer transaction
checks, 11 Node tests, and the 32-tool MCP smoke check. `git diff --check` passed and no compiler
warnings were emitted. Logs: `/tmp/spaceo-browser-budget-focused-final.log` and
`/tmp/spaceo-browser-budget-release.log`. AE-157 and AE-158 are fixed; the browser observation
portion of AE-105 is verified. No browser/app launch, native display creation, Accessibility
observation, screenshot, input, host install, Viewer source edit, or publishing occurred.

Capture wait probes still await native shareable-content enumeration and screenshot completion
without the outer deadline. The next change must bound response latency without allowing
repeated timeouts to accumulate native work, or releasing lifecycle authority while admitted
work still depends on a display. Existing RecordingFrameCapture's pending-work guard is useful
precedent; its low-resolution recording policy does not meet full-resolution stability waits.
AE-105 remains open for capture and native-work limits. The long-running goal remains active.


## Stability capture deadlines and resource quarantine (AE-105, AE-159 through AE-161)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-105 | Stability probes await native capture and pixel hashing without spending the wait remainder. | One deadline covers provider work and hashing; timeout/cancellation returns through a one-shot continuation and discards late results. | Verified for stability capture response latency; 136 focused checks and the full release suite pass. Synchronous/native APIs remain non-preemptible. |
| AE-159 | Every stability probe refreshes the target session's AX windows despite using only its tile and foreign capture exclusions. Busy retries would repeat the same unused scan. | Skip owned-window discovery for tile stability. Keep authorization, lifecycle admission, checked neighbouring windows, and capture filter exclusions. | Implemented; manager and isolation regressions exercise the reduced path. |
| AE-160 | Simply timing out capture could admit unlimited replacement screenshots or let teardown release a display while native work still uses it. | One pending stability worker per manager; a per-session capture ticket survives caller timeout until provider and pixel reads finish. Teardown returns an incomplete report and retains the entire resource ledger until retry. | Implemented; timeout/cancellation, busy probes, late-frame discard, and teardown quarantine tests. |
| AE-161 | A session with no apps could appear ready after teardown is deferred by capture work; callback completion is not proof cleanup ran. | Preserve a synchronized deferred-cleanup marker until teardown retries, including empty sessions. | Implemented; empty-session state and retry assertions. |

WaitFrameCapture retains full-resolution scale-one capture and hashes the complete validated
image. It rejects both incomplete and oversized backend dimensions rather than proving stability
from a partial frame. One detached worker owns native capture and hashing; it never starts a
replacement while an older callback is pending. Timeout/cancellation cancels that worker, but
its slot and capture ticket remain until native work actually returns. Late frames are discarded
before hashing, with cancellation/deadline checks again after hashing. Busy probes provide no
hash, which resets stability history instead of reusing stale evidence. Successful completion
clears the ticket only after all native and pixel operations have finished.

Capture tickets are registered under normal session lifecycle admission. Teardown fences new
admission, stops watchers, and refuses cleanup while any capture ticket remains. Unlike holding
an ordinary lifecycle lease indefinitely, this produces a prompt retryable report while preserving
the display, session, and app ledger. An empty session stays cleanup-pending after its callback
returns until a teardown retry completes. The existing global operation lease still protects
foreign exclusion discovery and any timely observation; late observations are never published.
Native capture helpers preserve cancellation and check it before progressing from enumeration
to screenshot and after screenshot completion. Permission preflight remains in Capture.region.


| ID | Additional finding | Fix | Status |
| --- | --- | --- | --- |
| AE-162 | RecordingFrameCapture already rejects replacement work after a timeout, but its caller releases the ordinary session lease before the native callback returns, leaving teardown free to recycle its tile. | Require the same owned capture ticket for recording workers. Transfer it only when a worker starts, finish it on rejection or actual worker completion, and retain it across timeout/cancellation. | Implemented; recording timeout, cancellation, rejected-image, and recovery ownership assertions added. |


| ID | Additional finding | Fix | Status |
| --- | --- | --- | --- |
| AE-163 | Recording evidence relies only on the scheduled timeout callback; a delayed timer can lose to a frame completed after the intended budget. | Track an absolute monotonic deadline through preparation, capture, and PNG encoding, and check it before accepting evidence. | Implemented; a fake-clock provider advances past the deadline without firing the timer and must return timeout. |


Focused verification passed 136 tests across capture ownership, full-frame hashing, exclusion
privacy, recording evidence, wait receipts, lifecycle admission, teardown responsiveness,
stranded-window retention, AX blackout recovery, and command ergonomics. New tests hold an
uncooperative provider after timeout/cancellation, issue 25 rejected replacement requests,
verify capture tickets remain owned, then release the provider and require a fresh frame.
Manager-level tests prove a normal timeout receipt, no stale hash on a busy retry, a responsive
ping, skipped target AX scans, retained teardown resources, and successful later cleanup.
An incomplete framebuffer returns structured `capture_failed` with an actionable explanation.

The exclusion integration test passes the neighbouring process/window set through the actual
stability capture path and refuses a subsequent probe when neighbour discovery fails. No
capture capability/preflight bypass exists in production; deterministic tests inject only the
image provider. Recording ownership checks cover timeout, cancellation, invalid-image rejection,
and recovery. A fake monotonic clock proves late recording frames cannot beat a delayed timer.

Final verification passed: `make verify-release` completed all 1228 Swift tests in 27.346 seconds,
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler
warnings were emitted, and `git diff --check` passed. Logs:
`/tmp/spaceo-capture-budget-focused-final.log` and `/tmp/spaceo-capture-budget-release-final.log`.
AE-159 through AE-163 are fixed; the stability-capture response-latency portion of AE-105 is
verified. No native capture, application launch, native display creation, Accessibility scan,
input, host installation, Viewer source edit, live qualification, or publishing occurred.

Ordinary screenshot commands still await their backend directly, and synchronous native calls
cannot be forcibly interrupted by these checks. Further response-latency work should retain
the same bounded pending-work and teardown safeguards. The long-running goal remains active.


## Ordinary screenshot processing (AE-164 through AE-167)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-164 | Ordinary screenshots await native capture indefinitely and run annotation/PNG encoding on the manager actor, blocking all commands. | One guarded screenshot worker handles capture and pixel processing under a shared fifteen-second post-admission deadline. Preserve its native-work ticket after timeout/cancellation until actual completion. | Implemented; deterministic capture and encoder stalls return promptly without admitting replacement work. |
| AE-165 | File screenshots retain PNG output with an effectively unlimited consumer budget; tile annotations capture pixels before rejecting an unsupported request. | Bound file PNG output to 64 MiB, retain the 5 MiB memory limit, and reject tile annotation before capture. | Implemented; memory/file limit and early-refusal tests. |
| AE-166 | An explicit window absent from the cache is captured after resolution but compared against the cached primary window's geometry. | Pin geometry from the resolved capture source rather than a fallback cached window. | Implemented; newly discovered non-primary window regression. |
| AE-167 | Moving image processing off the actor introduces another suspension interval in which topology can change after the existing geometry check. | Revalidate display/window geometry and deadline before publication, using the remaining budget for checked window discovery. | Implemented; moved-display-during-encoding test refuses without publishing. |

ScreenshotCapture owns at most one pending worker across capture and preparation. The same
monotonic budget covers both phases; it does not replenish on encoding, annotation, base64
conversion, AX annotation, or geometry verification. The worker retains a session capture ticket
until native/pixel operations return, so incomplete teardown retains the tile and full ledger.
A late result cannot publish pixels or paths. Full framebuffer dimensions are checked against
image geometry; PNG output uses the bounded ImageIO consumer and a final byte-count guard.
File PNG bytes are capped at 64 MiB; in-memory PNGs remain capped at 5 MiB before base64 expansion.
Pixel rendering checks and optional annotation run on the worker. AX snapshot/cache updates
remain under actor and command-gate ownership.

Requested output paths are written only after a timely prepared result and final geometry
validation. The worker never touches them, so a timeout/cancellation cannot later overwrite
an existing output file. Final publication preserves the existing atomic filesystem write;
that synchronous filesystem commit, and already-entered synchronous AX calls, are not forcibly
preemptible. The service budget starts after command admission, not while waiting in the global
operation queue. These remaining limits are explicit in the canonical playbook. CLI help and
MCP screenshot descriptions report the processing and PNG limits; generated playbook content
was regenerated from docs/playbook with the repository generator.


| ID | Additional finding | Fix | Status |
| --- | --- | --- | --- |
| AE-168 | Annotating zero marks still allocates and copies the entire screenshot bitmap, changing its colour space without drawing anything. | Return the original immutable image after validating existing annotation limits when the tag list is empty. | Implemented; reference-identity regression proves no replacement bitmap is created. |


| ID | Additional finding | Fix | Status |
| --- | --- | --- | --- |
| AE-169 | PNG byte limits do not bound the native image allocation; an 8192-square tile at scale four can request a billion pixels before encoding starts. | Cap every native capture configuration at 64 Mi pixels after scaling, with early screenshot-source admission checks and a second check against native shareable geometry. Keep overflow-only arithmetic validation separate. | Implemented; boundary/scaled-overflow tests refuse before provider work without allocating a giant bitmap. |
| AE-170 | Raw screenshot region dimensions can be negative and CGRect standardization can silently turn them into a different positive rectangle. | Validate positive width/height before constructing the region. | Implemented; direct manager regression confirms no capture for negative dimensions. |


Validation passed: 230 focused tests cover the screenshot worker, PNG and bitmap limits,
annotation allocation, privacy exclusions, wait/recording capture ownership, lifecycle and
teardown, manager ergonomics, MCP translation, CLI argument handling, coordinate contracts,
and pure unit checks. Twelve new screenshot tests exercise native/encoder stalls, repeated
busy requests, cancellation, expired admission, one shared capture/encoding budget, no late
output publication or overwrite, successful memory/file PNGs, late geometry changes, explicit
new-window resolution, scaled framebuffer limits, and invalid region/annotation rejection.
The exclusion integration test also verifies the ordinary screenshot worker receives foreign
window/process identities and refuses incomplete discovery before returning pixels. A new
annotation identity test proves an empty tag set does not allocate a replacement bitmap.

`make verify-release` passed all 1241 Swift tests (29.987 seconds), Viewer installer transaction
checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler warnings were emitted.
`git diff --check` passed. Logs: `/tmp/spaceo-screenshot-budget-focused-final.log` and
`/tmp/spaceo-screenshot-budget-release.log`. AE-164 through AE-170 are fixed. No native screen
capture, application launch, native display creation, Accessibility observation, input, host
install, Viewer source edit, live qualification, or publishing occurred. Test output consists
only of synthetic bitmap data in temporary test paths, which are removed by the fixtures.

Remaining work includes the explicitly non-preemptible final filesystem publication and
synchronous native-call latency, plus capture freshness metadata. Screenshot `capturedAt` is
currently populated when assembling the response after encoding/file output, rather than at
native capture completion. That can make an older image look newer after expensive processing;
the next pass should carry an observation timestamp through the worker and verify its meaning.
The long-running goal remains active.


## Capture observation time and agent guidance (AE-171, AE-172)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-171 | Screenshot receipts assign capturedAt after annotation, encoding, and file output, making delayed images appear newer and obscuring their actual observation time. | Stamp the backend-returned frame and carry that immutable time to memory/file receipts, wire serialization, and MCP output. Preserve unknown freshness/visibility and unverified presentation. | Fixed; deterministic processing-delay and agent-visible memory/file receipt regression passes. |
| AE-172 | Wait tool descriptions still say browser and capture backends have independent latency limits after those paths were changed to share the wait remainder. | Align MCP descriptions and the canonical playbook with shared deadlines, bounded pending work, discarded late frames, and remaining synchronous native limits. | Updated and regenerated with the repository playbook generator. |

The timestamp is assigned when the live provider returns its image and geometry, before the
worker's post-capture checks and before actor geometry verification, annotation, encoding, or
file publication. It is not a native renderer timestamp and does not establish that the pixels
are fresh or visible. The wire shape is unchanged. The Viewer uses its own streaming/capture
path and does not consume this receipt field, so no Viewer behavior or source changes are needed.


Validation passed: 55 focused tests, including a fixed backend timestamp preserved through
simulated processing delay, both output destinations, Response wire round trips, and the MCP
capture JSON. Freshness/visibility remain unknown and presentation remains unverified.
`make verify-release` passed all 1242 Swift tests (28.000 seconds), Viewer installer transaction
checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler warnings were emitted.
`git diff --check` passed. Logs: `/tmp/spaceo-capture-timestamp-focused.log` and
`/tmp/spaceo-capture-timestamp-release.log`. AE-171 and AE-172 are fixed. No native capture,
application launch, native display creation, Accessibility observation, input, host install,
Viewer source edit, live qualification, or publishing occurred. The long-running goal remains active.

| ID | Next measured path | Proposed work | Status |
| --- | --- | --- | --- |
| AE-173 | MCP screenshot validation decodes the entire PNG into a temporary Data allocation (up to 5 MiB) to check base64 validity, byte length, and the eight-byte signature, then discards it while retaining the original encoded string. | Evaluate bounded validation that preserves strict malformed-input rejection and size/signature checks without retaining the complete decoded image. Compare correctness and runtime against Foundation before replacing the path. | Logged from MCPServer.screenshotContent; implementation and measurement remain next work. |


## MCP PNG validation scratch memory (AE-173, AE-174)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-173 | Validating MCP image payloads allocates and decodes a complete temporary PNG (up to 5 MiB), then discards it and forwards the encoded string. | Compute decoded size from bounded base64 shape, validate alphabet in contiguous SIMD blocks with a scalar noncontiguous fallback, and decode at most nine bytes for the PNG signature. | Fixed; focused tests, optimized benchmarks, Address Sanitizer, and full deterministic release checks pass. |
| AE-174 | Foundation accepts some malformed base64 padding (observed examples include extra trailing padding and nonterminal padding), which may fail in downstream image clients. | Require groups of four with at most two terminal padding characters; '=' is forbidden throughout the remaining body. | Fixed; malformed-padding, whitespace, Unicode, byte classification, and forwarding regressions pass. |

The helper validates only the existing transport contract: base64 syntax, decoded-byte cap,
and PNG signature. It does not parse PNG chunks or claim that a renderer will decode every
payload. Standard daemon-generated base64 is preserved byte-for-byte; legal alphabet characters,
all ordinary padding lengths, and noncanonical unused pad bits accepted by Foundation remain
supported. Oversize payloads are refused before the body scan, including maximum-plus-one
payloads whose encoded length equals the allowed length. Overflowing or nonsensical byte-limit
configuration is refused. Prefix decoding allocates at most nine decoded bytes; validation
never builds a full decoded image or a copied UTF-8 array.

An initial scalar UTF-8 prototype reduced scratch memory but ran about five times slower than
Foundation, so it was not adopted. The production scanner uses 32-byte SIMD loads only when
contiguous storage is available. Every load is guarded by offset <= count - 32, including for
unaligned slices; remaining bytes use scalar checks. Noncontiguous collections retain a scalar
fallback without copying the collection. Exhaustive tests place all 256 byte values at every
position across short buffers, SIMD boundaries, tails, and unaligned slices. Additional tests
cover fallback collections, PNG signatures, payload sizes 8 through 512, the 5 MiB boundary,
invalid input mutations, and original MCP image forwarding.

Optimized isolated benchmark on this host (three alternating-order trials, medians):

| Decoded bytes | Foundation microseconds/call | Bounded validator microseconds/call | Foundation peak RSS MiB | Bounded peak RSS MiB |
| --- | --- | --- | --- | --- |
| 1,024 | 0.412 | 0.203 | 5.83 | 5.83 |
| 262,144 | 73.367 | 18.020 | 6.45 | 6.19 |
| 5,242,880 | 1,482.974 | 359.258 | 17.53 | 12.52 |

The largest fixture showed about 4.1x faster validation and 5.01 MiB lower process peak RSS.
These are isolated helper measurements, not whole-daemon throughput or memory claims. Fixtures
are allocated directly as encoded synthetic strings to avoid hiding scratch-memory differences
behind a full binary fixture allocation. Both variants run with the same autorelease-pool
boundary. Results are in `/tmp/spaceo-png-validation-benchmark.json`; the retained reproduction
driver is `scripts/benchmark-png-validation.swift`, compiled with the actual production helper.


Validation passed: 46 focused tests and an optimized Address Sanitizer harness exercising
3,145,728 byte classifications across exact allocation sizes, every starting offset from 0
through 31, SIMD blocks, and scalar tails. The retained benchmark driver also compiled and ran
against the production helper. `make verify-release` passed all 1250 Swift tests (29.834 seconds),
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler
warnings were emitted. `git diff --check` passed. Logs: `/tmp/spaceo-png-validation-focused.log`,
`/tmp/spaceo-png-validation-asan.log`, and `/tmp/spaceo-png-validation-release.log`.
AE-173 and AE-174 are fixed. No native capture, application launch, native display creation,
Accessibility observation, input, host install, Viewer source edit, live qualification, or
publishing occurred. The long-running goal remains active.


## Wire JSON slash expansion (AE-175)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-175 | The shared daemon JSONEncoder escapes every forward slash, expanding base64 image strings, paths, and URLs. A slash-heavy image within the 5 MiB image limit can exceed the 8 MiB wire limit solely because of this optional escape and become a failure response. | Configure the shared encoder with withoutEscapingSlashes. Preserve required JSON escaping, ISO-8601 dates, schema, decoder compatibility, and all frame limits. | Fixed; focused tests, optimized encoder measurements, and full deterministic release validation pass. |

The change affects the shared request/response encoder; MCP stdout already uses unescaped
slashes. A literal slash is valid JSON, including inside URLs and base64. This is a JSON-line
transport, not HTML script embedding. Existing escaped-slash peers remain decodable. The
regression test encodes a maximum-size synthetic image, passes it through the actual
Transport.writeLine path into a temporary file, and verifies the original image survives
without being replaced by an oversized-response failure. A separate test preserves the
structured failure for truly oversized output. Required newline, carriage-return, NUL,
quote, and backslash escaping and Unicode/request round trips are also covered. No real
image capture or user data is used.


Optimized isolated Foundation encoder benchmark on this host, three alternating-order trials
of 200 encodes of a synthetic 5 MiB decoded-size fixture (median results):

| Alphabet distribution | Formatting | Encoded bytes | Microseconds/call | Peak RSS MiB |
| --- | --- | --- | --- | --- |
| Uniform base64 alphabet | Escaped slashes | 7,099,762 | 15,458.596 | 44.531 |
| Uniform base64 alphabet | Literal slashes | 6,990,536 | 7,728.341 | 26.281 |
| Slash-heavy worst case | Escaped slashes | 13,981,042 | 12,981.038 | 66.797 |
| Slash-heavy worst case | Literal slashes | 6,990,536 | 6,039.631 | 26.281 |

The uniform fixture encodes about 2x faster with 18.25 MiB lower isolated peak RSS; the
slash-heavy case removes nearly 7 million redundant bytes and encodes about 2.15x faster.
These are Foundation encoder/configuration measurements using the same two populated response
field names, not whole-daemon or captured-image benchmarks. Uniform alphabet frequency is a
synthetic comparison, not a claim about any real PNG's character distribution. Both modes use
the same prebuilt string and autorelease-pool boundary in separate processes. JSON key ordering
is not assumed. Actual Response encoding and transport framing are covered independently by
the regression tests. Reproduction: `scripts/benchmark-json-slashes.swift`. Raw measurements:
`/tmp/spaceo-json-slashes-benchmark.json`.


Validation passed: 17 focused transport/encoding tests and all 1253 Swift tests in the final
`make verify-release` run (28.971 seconds), plus Viewer installer transaction checks, 11 Node
tests, and the 32-tool MCP smoke check. No compiler warnings were emitted. The oversized-frame
fixture uses a regular temporary file, so a future limit regression cannot hang writing to an
undrained pipe. `git diff --check` passed. Logs: `/tmp/spaceo-wire-encoding-focused.log` and
`/tmp/spaceo-wire-encoding-release-final.log`. AE-175 is fixed. No native capture, application
launch, native display creation, Accessibility observation, input, host install, Viewer source
edit, live qualification, or publishing occurred. The long-running goal remains active.

The next response/input-path candidate is the MCP run loop's conversion of each bounded line
from bytes to String, whitespace trimming, and conversion back to UTF-8 Data for JSON parsing.
Measure those copies before changing the reader contract; preserve invalid-UTF-8 rejection,
line-size limits, oversized-line recovery, EOF behavior, and existing whitespace handling.


## MCP input conversion scratch space (AE-176)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-176 | Each bounded MCP input line is converted from Data to String, trimmed, then encoded back into Data before JSON parsing, even for ordinary ASCII JSON. Near-limit requests retain avoidable temporary text storage. | Classify ASCII with bounded SIMD reads, retain its original Data slice, trim only the equivalent edge bytes, and parse directly. Keep strict UTF-8 String conversion and Foundation whitespace trimming for Unicode input. Share the existing bounded reader/framing logic between both representations. | Fixed; focused, compatibility, ownership, sanitizer, optimized benchmark, and full deterministic release checks pass. |

The fast path is for ASCII input only. It does not implement a new UTF-8 decoder or replace
JSONSerialization. Non-ASCII lines preserve strict Foundation UTF-8 validation and Unicode
whitespace behavior. ASCII edge trimming uses tab and space, exactly the ASCII members of
CharacterSet.whitespaces. Trimming is retained even though normal JSON allows those bytes:
Foundation's handling of unusual NUL-containing UTF-16/32-shaped inputs can depend on the
original trimming order. Empty trimmed lines are still ignored; parse failures, invalid-request
classification, invalid-UTF-8 errors, oversized-line recovery, EOF, and fatal descriptor handling
are unchanged. Complete lines are decoded before the reader advances; retained Data slices
remain immutable across subsequent buffer compaction or reuse.

Eleven focused tests passed, including exhaustive classification of all 256 byte values across
SIMD lanes, tails, and offset slices; equivalence to the old parser for Unicode whitespace,
control bytes, BOMs, invalid UTF-8, JSON arrays/scalars, malformed JSON, and NUL-containing input;
and a near-limit multiline reader fixture that retains earlier lines through later reads,
oversize/invalid recovery, Unicode fallback, and unterminated EOF. An optimized Address Sanitizer
harness passed 3,145,728 classifications with exact allocations and offsets 0 through 31.

Optimized isolated input-preparation plus JSON-parsing benchmark, three alternating-order trials
per case (medians; payload sizes below exclude the 11 JSON syntax bytes):

| Payload | Original microseconds/call | Byte-path microseconds/call | Original peak RSS MiB | Byte-path peak RSS MiB |
| --- | --- | --- | --- | --- |
| 256 ASCII bytes | 1.259 | 1.086 | 6.016 | 5.938 |
| 1,048,000 ASCII bytes | 1,233.352 | 1,208.634 | 10.016 | 8.969 |
| 1,048,000 Unicode UTF-8 bytes | 2,504.653 | 2,506.805 | 11.031 | 11.031 |

The useful large-input result is about 1 MiB lower isolated peak memory; the roughly 2% timing
difference is too small to claim a meaningful large-input speedup. Small requests improved by
about 14% in this run. Unicode fallback timing and peak memory were effectively unchanged. An
initial benchmark walked every decoded grapheme to check the fixture, obscuring parser costs;
the retained benchmark validates object shape without a second full text traversal. Results
are isolated helper measurements, not whole-MCP throughput or process-retention claims. The
same fixture and autorelease-pool boundary are used for each mode in separate processes.
Reproduction: `scripts/benchmark-mcp-input.swift`, compiled with the production helper. Results:
`/tmp/spaceo-mcp-input-benchmark.json`; focused log: `/tmp/spaceo-mcp-input-focused.log`; sanitizer
log: `/tmp/spaceo-mcp-input-asan.log`.


Final validation: `make verify-release` passed all 1256 Swift tests (30.615 seconds), Viewer
installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler
warnings were emitted. `git diff --check` passed. Release log:
`/tmp/spaceo-mcp-input-release.log`. AE-176 is fixed. No native capture, application launch,
native display creation, Accessibility observation, input, host install, Viewer source edit,
live qualification, or publishing occurred. The long-running goal remains active.


## Shared transport deadlines and nonblocking clients (AE-177–AE-179)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-177 | One-shot clients reset their timeout after connecting and again after upload; blocking socket syscalls can then spend a whole timeout despite little budget remaining. Subscription setup also resets its write budget, and its blocking request write has no socket timeout. | Carry one absolute uptime deadline through connection, upload, and response reception. Keep client sockets nonblocking and poll only for remaining time. Subscription connect/encode/write share the existing five-second setup budget; idle stream reads poll without a deadline and wake on cancellation. | Fixed; focused and full deterministic release checks pass. |
| AE-178 | writeAll only consults its deadline after EAGAIN, so an already expired writable descriptor can still emit bytes, and continuously progressing writes need not stop. readFrame can accept a terminator or UTF-8 validation result after its deadline. Connect polling restarts its timeout after EINTR. | Check writes before each syscall and after completion, recheck received frames after validation, and reuse the absolute-deadline poll helper for connect. Its rounded millisecond calculation no longer risks overflowing when given a very distant absolute deadline. | Fixed; expired-writer, late-fragment, and full release regressions pass. |
| AE-179 | Accepted server sockets install receive/send timeouts despite already being nonblocking. One-shot clients also install syscall timeouts to compensate for restoring blocking mode. | Remove the redundant socket options and blocking-mode restoration. Read sources and absolute poll deadlines own waiting. | Removed four timeout setsockopt calls across the two sides of an ordinary exchange, plus the client blocking-mode restoration call. No CPU benchmark claim. |

The deadline begins in sendLinePayload before framing and connecting; public Request JSON
encoding precedes that helper, and Response JSON decoding follows it. Those synchronous codec
operations are not claimed to be preemptible or included in the exchange timeout. Received UTF-8
validation remains bounded by the frame cap and rejects a late result. Existing 1 MiB request
and 8 MiB response limits, one-message framing, controller authorization, descriptor ownership,
and structured transport failures remain unchanged. A timeout closes the client connection;
it does not cancel already admitted daemon work or prove that an operation did not execute.
Regular-file writes and callers passing blocking descriptors to low-level test helpers remain
non-preemptible; all production transport socket writers now receive nonblocking descriptors.

The synthetic AF_UNIX peer fixtures check an immediately expired writer emits no bytes, late
fragments cannot stretch a 0.3-second read budget, upload delay consumes a shared 0.8-second
exchange budget, and timely fragmented responses still succeed. The upload fixture requires
the peer to receive the complete request, so a connection failure cannot satisfy the test by
accident. These are bounded fault fixtures, not throughput benchmarks or exact scheduler-latency
claims. A delayed first event tests the subscription's idle EAGAIN path followed by cancellation.
Existing streaming replay, redaction, cancellation, slow-reader framing, and malformed-input
regressions remain in the focused suite. No user daemon or native application is involved.


Final validation passed: 118 focused tests and all 1261 Swift tests in `make verify-release`
(32.272 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. `git diff --check` passed. Logs:
`/tmp/spaceo-transport-deadline-focused-final.log` and
`/tmp/spaceo-transport-deadline-release.log`. AE-177 through AE-179 are fixed. No native capture,
application launch, native display creation, Accessibility observation, input, host install,
Viewer source edit, live qualification, or publishing occurred. The long-running goal remains active.


## Subscription setup cancellation and terminal ownership (AE-180–AE-182)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-180 | Subscription cancellation cannot reach the socket until connect and request upload finish. A stopped subscription can occupy its setup caller and retain encoded data until the five-second budget expires. Cancelled readers also keep draining buffered input before exiting. | Register the descriptor before connect, let cancel shut it down, and leave close to the current setup/reader owner. Check cancellation between setup stages and before buffered decode/read work. Cancellable connect polls use at most 50 ms slices because shutdown need not wake an unconnected socket. | Fixed; stalled-upload cancellation, bounded cancellation polling, and full deterministic release checks pass. |
| AE-181 | Retained finished subscription handles keep the original Request and both callback closures alive, retaining their captured objects. Cancelling before start does not finish or release callbacks until a later start call. | Transfer and clear the request at admission, clear callback storage exactly once at completion, and release captures outside the lock. Cancellation before start is terminal and delivers one clean close. | Fixed; failure, clean EOF, and pre-start cancellation lifetime regressions pass, including capture deinitializers that reenter cancel. |
| AE-182 | The reader thread weakly captures its subscription and does nothing if it disappears before thread entry, leaking the connected descriptor. Reader completion callbacks also run before socket cleanup. | Close the descriptor in the nil-owner thread entry branch. Retire reader sockets before terminal callbacks, clear registration before close, and never close a descriptor while setup/poll/read is still borrowing it. | Fixed; ownership paths reviewed, with stream closure, cancellation, and full release checks passing. |

Setup owns the registered descriptor until it hands it to a reader under the lock. Cancellation
only shuts down that descriptor; the setup owner or reader closes it exactly once. Registration
is cleared before close so a racing cancel cannot target a reused descriptor number. Setup
cancellation may notify onClose before its socket owner has unwound, but further setup admission
is refused and retained callback/request fields are cleared. Active-reader cancellation lets
the reader finish any callback already running, retire the socket, and publish one close.
The existing five-second absolute setup deadline and frame limits remain in force.

Only cancellable connection setup uses short poll slices; ordinary exchanges retain a single
remaining-deadline wait, and established idle subscriptions still sleep indefinitely until data,
close, or shutdown. Synchronous JSON encoding remains non-preemptible; cancellation is checked
before allocating/registering a socket after encoding. Cancellation cannot recall request bytes
already transmitted or prove that the daemon did no work. No change to authorization, event
redaction, sequence semantics, or application isolation is involved.

The synthetic stalled-upload fixture sends a 900 KB request, has the peer read one byte and stop,
and verifies start is still blocked before cancellation. Cancellation must release start within
one second while the peer remains open (rather than reaching the five-second setup deadline).
The first run completed that complete fixture in 0.008 seconds; this is a fault-regression
observation, not a general latency benchmark. A separate readiness-free poll test confirms a
cancellation predicate is checked repeatedly and expired deadlines still stop waiting. Lifetime
checks hold the finished subscription strongly while verifying weak callback owners disappear;
owner deinitializers reenter cancel, exercising release outside the lock and one-shot completion.
The nil-owner thread-entry close is a reviewed defensive ownership path, not a scheduler-race
coverage claim. Initial weak-variable compiler diagnostics in the new tests were fixed without
turning the references strong.


Final validation passed: 120 focused tests and all 1266 Swift tests in `make verify-release`
(32.919 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. The final full run also verifies that a registered
setup socket does not report isRunning before reader handoff. `git diff --check` passed. Logs:
`/tmp/spaceo-subscription-focused-final.log` and `/tmp/spaceo-subscription-release.log`.
AE-180 through AE-182 are fixed. No native capture, application launch, native display creation,
Accessibility observation, input, host install, Viewer source edit, live qualification, or
publishing occurred. The long-running goal remains active.


## Frame admission before allocation (AE-183–AE-185)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-183 | Server request framing and one-shot response framing append an entire chunk before rejecting an over-limit frame. Crossing the cap can grow or copy Data storage just before it is discarded. | Share a subtraction-based bounded append that validates remaining capacity before consuming incoming bytes. Preserve exact-size frames and ignore post-terminator bytes as before. | Fixed; helper refusal, real client/server boundary, and full release tests pass. |
| AE-184 | The MCP reader keeps copying every read chunk while discarding a line already known to be oversized. It also extends a partial line before detecting that the incoming prefix exceeds its limit. | Scan rejected chunks without retaining them; reject oversized prefixes before append and retain only bytes after their newline for recovery. Avoid an extra delimiter scan when the entire chunk fits. | Fixed; boundary recovery, optimized reader benchmarks, and full release tests pass. |
| AE-185 | A valid MCP line at its size cap can grow its allocation just to append a terminator or following coalesced message. | At a boundary-crossing read, finish and decode the valid body directly, then retain the next-message tail separately. Advance state even if UTF-8 decoding fails. | Fixed; exact-limit, tail-preservation, decode-failure, and full release regressions pass. |

The daemon request cap remains 1 MiB, response cap 8 MiB, and MCP line cap 1 MiB. No cap is
increased, and no rejected prefix is decoded as a request. One-shot framing still requires a
terminator and valid UTF-8; MCP preserves its existing final unterminated-line behavior and
one recoverable error per oversized logical line. The fixed-size read scratch buffers are
unchanged. Coalesced valid MCP messages may still occupy one bounded read chunk together;
this change does not claim that total backing allocation always equals one logical line cap.

Thirty-seven focused tests pass. An unreadable synthetic collection proves rejected appends
neither traverse incoming bytes nor mutate the accepted prefix, including arithmetic extremes.
Tests exercise exact/over limits across 8 KiB reads, the real server accepting a 1 MiB request
and rejecting one extra valid JSON whitespace byte, MCP rejected-line terminators on both sides
of 64 KiB boundaries, consecutive errors, empty lines, valid tails, and UTF-8 failure immediately
before a valid coalesced message. Existing coalesced-input, partial-EOF, deadline, and cancellation
coverage passes as well.

Optimized actual-reader benchmark on this host, three alternating-order trials (medians):

| Synthetic file | Before ms/file | After ms/file | Before peak RSS MiB | After peak RSS MiB |
| --- | --- | --- | --- | --- |
| 64 MiB oversized line, then one valid line | 130.473 | 22.140 | 7.266 | 7.000 |
| 20,000 coalesced short valid lines | 1.227 | 1.218 | 6.141 | 6.141 |
| One exact 1 MiB UTF-8 line | 2.010 | 1.868 | 8.203 | 8.203 |

Oversized-line draining is about 5.9x faster; ordinary short-line timing is effectively unchanged.
The large rejected fixture avoids copying roughly 63 MiB after filling the initial 1 MiB prefix.
Peak RSS improvements are small/noisy and are not claimed as a significant process-memory win.
An intermediate implementation still appended the exact-limit terminator; it was refined before
final validation. These measurements cover the bounded reader and input representation, not JSON
parsing, daemon throughput, native application work, or disk-cold performance.

The benchmark compiles the actual before/after BoundedLineReader class with the production
MCPInputLine helper using swiftc -O. Each mode runs in a separate process with the same file,
autorelease-pool boundary, and expected accepted/error counts. Fixture files, extracted sources,
driver, binaries, and results are retained under `/tmp/spaceo-frame-admission-bench/`; the final
measurements are `results.json` and the intermediate results are `results-initial.json`.
The retained driver is `scripts/benchmark-mcp-framing.swift`. Fixtures are: 1,024 copies of a
64 KiB ASCII x block followed by newline and '{}\n'; 20,000 copies of '{"ok":true}\n'; and
1 MiB of ASCII x followed by newline. Run 10, 20, and 200 iterations respectively, expecting
(line,error) counts (1,1), (20000,0), and (1,0) per file. No fixture contains user content.


Final validation passed: 37 focused tests and all 1271 Swift tests in `make verify-release`
(32.670 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. The retained benchmark driver compiled and ran with
the production reader/helper. `git diff --check` passed. Logs:
`/tmp/spaceo-frame-admission-focused-final.log` and `/tmp/spaceo-frame-admission-release.log`.
AE-183 through AE-185 are fixed. No native capture, application launch, native display creation,
Accessibility observation, input, host install, Viewer source edit, live qualification, or
publishing occurred. The long-running goal remains active.


## Byte-first string admission (AE-186, AE-187)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-186 | Several public argument guards count grapheme clusters before checking an existing UTF-8 byte cap. A large single grapheme can therefore force a full Unicode traversal even though byte length already disqualifies it. | Check the byte cap first within the existing combined guard. Apply consistently to MCP strings/files/session IDs, daemon arguments, launch/document paths, browser target IDs/evaluation/preview text, and ergonomic references/paste routing. | Fixed; focused contract tests, optimized predicate measurements, and full deterministic release checks pass. |
| AE-187 | Daemon and Chromium typing separately count characters and scalars against the same 8,000 limit. A Unicode Character contains at least one scalar, so the scalar cap already enforces the character cap. | Keep the 32,000-byte check first and the 8,000-scalar check second; omit the redundant grapheme count. Keep the existing error and accepted-input contract. | Fixed; independent character/scalar/byte boundary coverage passes across MCP, daemon, and unattached browser validation. |

No limits, fields, schemas, or error strings change. Reordering stays within each existing
combined size guard, so earlier validation categories (for example forbidden session-ID
characters) retain their existing precedence. Session-ID trimming and control-character scans
are not claimed to be eliminated. Native paste keeps its separate character check because its
subsequent input-router validation also decides whether the text can be typed on that route.
The MCP typing parser retains its character check/error ordering; the redundant scan is removed
only where one combined daemon/browser guard already imposes the same scalar ceiling.

New tests compare the old accepted-input predicate with all three typing entry points for
ASCII limits, 8,000/8,001 emoji, combining sequences, multi-scalar family emoji, and a giant
single grapheme. Valid daemon/browser cases reach only missing-session/unattached-target
failures; no native input or endpoint discovery occurs. MCP path tests separately exercise
character-only and byte-only refusals. The focused suite passes 142 tests, including existing
session-ID, browser, input arbitration, and unit coverage, without compiler warnings.

Optimized isolated typing-predicate benchmark, three alternating-order trials (median µs/check):

| Synthetic String | Previous predicate | Byte/scalar predicate |
| --- | --- | --- |
| 64 ASCII characters | 0.107 | 0.055 |
| 8,000 emoji / 32,000 UTF-8 bytes | 130.635 | 8.305 |
| One grapheme / 500,001 UTF-8 bytes | 3,937.902 | 0.008 |
| 4,001 combining sequences / 8,002 scalars | 102.925 | 24.576 |

The valid emoji fixture's predicate is about 15.7x faster. The oversized grapheme no longer
incurs a roughly four-millisecond traversal; its new measurement is near benchmark overhead,
so no enormous speedup ratio is claimed. This 500 KB fixture fits within the MCP frame cap
but exceeds the typing byte limit. Measurements use native Swift String fixtures and the exact
before/after typing predicates; they do not include JSON decoding, actor/transport overhead,
foreign NSString bridging, normalization, or actual typing. UTF-8 counting may itself require
work for bridged strings, so this is not a universal constant-time guarantee. No RSS reduction
is claimed. Driver: `scripts/benchmark-string-admission.swift`; results:
`/tmp/spaceo-string-admission-benchmark.json`.

| ID | Follow-up observation | Next work | Status |
| --- | --- | --- | --- |
| AE-188 | MCP unexpected-argument diagnostics construct and sort the complete unexpected-key set, then join all names into the error. Input is framed at 1 MiB, but malformed argument dictionaries can still cause large diagnostic allocations and agent-visible errors. | Bound diagnostic construction and field-name rendering while preserving useful errors for ordinary typos; cover many keys and oversized Unicode keys. | Logged for the next validation pass. |


Final validation passed: 142 focused tests and all 1273 Swift tests in `make verify-release`
(32.473 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. `git diff --check` passed. Logs:
`/tmp/spaceo-string-admission-focused.log` and `/tmp/spaceo-string-admission-release.log`.
AE-186 and AE-187 are fixed; AE-188 remains the next logged diagnostic-construction task.
No native capture, application launch, native display creation, Accessibility observation,
input, host install, Viewer source edit, live qualification, or publishing occurred. The
long-running goal remains active.


## Bounded MCP diagnostic construction (AE-188, AE-189)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-188 | Unexpected-argument validation copies all keys into a Set, subtracts allowed fields, sorts every unexpected name, and joins them into potentially frame-sized error text. | Iterate original keys once, count unexpected fields, and keep only the lexically smallest eight rendered previews (96 bytes each) with an omitted count. Allocate no preview array storage when all keys are allowed. | Fixed; focused diagnostic/translation tests, optimized construction benchmarks, and full release checks pass. |
| AE-189 | Unknown tool/method responses and tool completion logs interpolate full request names. Error logging replaces newlines over the complete message then clips by Character count; a single giant grapheme can still make the log enormous. | Reuse bounded scalar-prefix rendering for names and a 600-byte stderr message preview. Escape control/format/line-separator characters and backslashes. Keep the tool's original error body independent of its bounded log preview. | Fixed; Unicode/control/size regressions and end-to-end protocol/log checks pass. |

Ordinary short unexpected names retain the same sorted text. For large dictionaries, selection
is deterministic by rendered preview rather than raw unbounded names. The error reports exactly
how many additional names were omitted; long individual names end with '...'. Preview collisions
are possible for names sharing a long prefix and do not change the total count or refusal.
Only eight names are retained during selection; a newly rendered candidate is bounded too.
Allowed-field membership retains Swift String equality, including canonical equivalence.
The same advertised fields and malformed requests are accepted/refused as before, and unknown
methods retain -32601 while invalid tool calls remain isError results. Argument values are not
copied into these diagnostics. The resulting unexpected-field message is under 1,024 UTF-8 bytes.

Scalar iteration prevents a giant grapheme from evading a Character-based output cap. It renders
only a prefix and never splits UTF-8 scalar encoding. Commas inside names are visibly escaped to distinguish embedded separators; control characters
cannot introduce raw log lines. Stderr error previews now
show escaped newlines instead of the former ' | ' substitution. Tool-completion logs also bound
the tool name. This does not cap all legitimate daemon error bodies or redesign diagnostics
elsewhere. UTF-8 counting/Set membership on externally bridged strings can still do conversion
or hashing work; no universal constant-time claim is made.

Five new tests cover unchanged ordinary typos, allowed/canonically equivalent keys, deterministic
10,000-name selection, exact omitted counts, giant combining/emoji names, escaped controls and
bidirectional formatting, byte-bounded log previews, and translator recovery. The initial
focused run passed 125 tests without warnings. MCP smoke now sends a 200 KB unknown method and
tool name plus a 1,000-field invalid dictionary, checks bounded structured errors, then continues
normal protocol checks; collected tool log lines must stay below 900 bytes.

Optimized actual-helper benchmark, three alternating-order trials (median µs/check):

| Fixture | Previous | Bounded | Previous output bytes | Bounded output bytes |
| --- | --- | --- | --- | --- |
| Three valid fields | 0.121 | 0.054 | 0 | 0 |
| One ordinary typo | 0.247 | 0.212 | 28 | 28 |
| 20,000 unexpected fields | 15,642.752 | 3,062.527 | 260,022 | 143 |
| One 500,001-byte grapheme name | 5,108.522 | 1.880 | 500,025 | 120 |

Large-key-set diagnostic construction is about 5.1x faster, with a much smaller agent-visible
error. The normal valid path avoids building the temporary key Set. These are native-String
helper measurements with dictionaries built before timing, not whole-RPC or JSON parsing
benchmarks. Peak RSS was 9.828/9.203 MiB for many keys, but 13.516/14.234 MiB for the giant-key
fixture, whose initial dictionary hashing/allocation dominates the process peak. No general RSS
reduction is claimed; diagnostic scratch/output is bounded independently of the already parsed
input dictionary. Driver: `scripts/benchmark-mcp-diagnostics.swift`, compiled with production
`MCPDiagnostic.swift`; results: `/tmp/spaceo-mcp-diagnostics-benchmark.json`.


Final validation passed: 125 focused tests and all 1278 Swift tests in `make verify-release`
(32.162 seconds), Viewer installer transaction checks, 11 Node tests, and the extended 32-tool MCP
smoke check, including bounded unknown-name responses, many-field diagnostics, later successful
requests, and stderr line budgets. No compiler warnings were emitted. `git diff --check` passed.
Logs: `/tmp/spaceo-diagnostic-focused.log` and `/tmp/spaceo-diagnostic-release.log`.
AE-188 and AE-189 are fixed. No native capture, application launch, native display creation,
Accessibility observation, input, host install, Viewer source edit, live qualification, or
publishing occurred. The long-running goal remains active.


## Bounded, actionable MCP prompt arguments (AE-190, AE-191)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-190 | prompts/get accepts values by a 4096-Character count alone. A single large combining-mark grapheme can pass and be copied into a very large prompt response, consuming memory and agent context. The byte/character limits are not advertised. | Enforce 16384 UTF-8 bytes before the existing 4096-character check, before preamble construction. Advertise both limits in prompts/list descriptions and the canonical playbook; regenerate the embedded resource. | Fixed; exact-boundary, large-grapheme, and full release checks pass. |
| AE-191 | Non-object prompt arguments are treated as an empty object; non-string or oversized required values are reported as missing. Unknown fields are silently dropped, so an agent can believe supplied context was included when it was ignored. | Validate argument object shape, reject unknown fields with the shared bounded diagnostic, and distinguish missing, non-string, and oversized values. Preserve -32602 and valid prompt content exactly. | Fixed; translation, malformed-request recovery, protocol smoke, and full release checks pass. |

Prompt expansion is now a pure testable helper used by the real handler. It does not execute
applications, open URLs, pause sessions, or claim arguments are valid for downstream action
tools. Empty and multiline string arguments retain their previous behavior; required means
present, not newly subject to an unstated nonempty rule. Missing required arguments keep their
existing explanatory message. An explicit null arguments container is refused as a non-object,
and a null field is refused as a non-string. Unknown prompt names retain the small constant
error. Supplied values are never echoed in refusal messages.

All three advertised prompts currently have one required argument, so added context is bounded
by one 16 KiB value plus the fixed label/separator and embedded document. Valid response roles,
descriptions, document content, and argument bytes are unchanged. Prompt discovery formats its
limit descriptions from the same constants as validation; the canonical docs/playbook/SKILL.md
records the contract, and scripts/generate-playbook.mjs regenerated Playbook.swift. No tool or
prompt names, prompt required fields, or application isolation semantics change.

Twenty-eight focused tests passed without warnings. New regressions cover all three prompt
expansions, independent character/byte limits, exactly 4096 emoji (16384 bytes), a two-grapheme
16384-byte combining-mark value, maximum-plus-one refusal, a 500 KB single grapheme, missing
arguments, arrays/null/numbers, 1000 unexpected fields with a bounded omitted-count diagnostic,
and successful later expansion. Oversized-value errors remain below 160 bytes. This is a
contract/output-size bound, not a process-RSS or end-to-end performance benchmark. MCP smoke
now discovers advertised limits, expands every prompt, rejects malformed/oversized requests
with -32602, and verifies a following valid request still works.


Final validation passed: 28 focused tests and all 1282 Swift tests in `make verify-release`
(32.161 seconds), Viewer installer transaction checks, 11 Node tests, and the extended 32-tool
MCP smoke check. The smoke check covers prompt discovery, all prompt expansions, bounded
malformed/oversized-argument errors, and successful subsequent requests. No compiler warnings
were emitted. `git diff --check` passed. Logs: `/tmp/spaceo-prompt-admission-focused.log` and
`/tmp/spaceo-prompt-admission-release.log`. AE-190 and AE-191 are fixed. No live qualification or
host installation was performed. The long-running goal remains active.


## MCP request lifetime and remaining nested validation (AE-192–AE-194)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-192 | The synchronous MCP request loop never drains Foundation autoreleased JSON/bridging temporaries. Repeated requests retain transient allocations for the lifetime of the process. | Wrap each complete read/decode/dispatch/emit iteration in an autorelease pool. Drain all success, blank-input, and recoverable-error paths before waiting for another request. Persistent reader/controller state stays outside the pool. | Fixed; focused tests, optimized probe, and full release checks pass. |
| AE-193 | Unknown resource URIs and disallowed batch tool names still echo complete supplied strings, amplifying malformed requests into large responses despite bounded diagnostics elsewhere. | Use the shared byte-bounded, control-escaping name preview while preserving error codes and ordinary short-name messages. | Fixed; focused tests, optimized probe, and full release checks pass. |
| AE-194 | Batch envelopes silently discard unknown fields and treat non-object arguments as empty objects. A misspelled argument field can change an action into defaults or produce a misleading missing-value error. | Reject unknown envelope fields and non-object argument values before producing a daemon request. Advertise additionalProperties=false in step schemas. Omitted arguments still use the original empty-object/single-tool validation. | Fixed; focused tests, optimized probe, and full release checks pass. |

The memory probe runs the actual optimized MCP binary against a synthetic ping-only Unix socket.
It creates no daemon, session, virtual display, application, Accessibility request, or input.
Each schema response is parsed and checked for its request ID and 32 tools. RSS samples use ps;
these are process resident-memory observations, not allocation counts or native GUI workloads.
The retained driver is scripts/benchmark-mcp-memory.mjs. Baseline at 50/100/500/1000 requests:
16032/19296/45568/78528 KiB, with identical-size schema replies throughout. This demonstrates
request-count-dependent retention rather than a single-request peak. Comparative results and
final checks follow below.


Three alternating-order trials of 2000 real schema requests gave the following medians:

| Sample | Before RSS (KiB) | Per-request pool RSS (KiB) |
| --- | --- | --- |
| 50 requests | 16032 | 12800 |
| 100 requests | 19296 | 12800 |
| 1000 requests | 78512 | 12864 |
| 2000 requests | 144176 | 12864 |

At 2000 requests the median reduction was approximately 128 MiB (91%). A separate 10000-request
run finished at 13056 KiB versus 12832 KiB at request 50, returning and checking every response.
The persistent schema, reader, and connection state remain usable across pool drains. Elapsed
medians for 2000 requests were 739.53 ms before and 758.03 ms after; one after trial was 1236.94
ms. These wall times include Node exchanges and RSS sampling; no latency improvement is claimed.
The after schema adds the 29-byte step-envelope additionalProperties=false contract per reply;
the workload otherwise uses identical methods and counts. The memory result applies to this
Foundation-heavy discovery workload, not arbitrary GUI operations or all possible tool mixes.
Results: /tmp/spaceo-mcp-memory-comparison.json and /tmp/spaceo-mcp-memory-long.json.

Thirty-one focused tests passed without warnings. Added regressions check batch null/array/
number/string arguments, later-step typos rejecting the entire translation, omission retaining
single-tool missing-value errors, schema agreement, 200 KB combining-mark tool names, and 1000
unknown envelope fields. Extended MCP smoke checks resource and batch error codes/byte limits,
and malformed batch refusal before the existing mutation-safety/recovery checks. Optimized
build succeeded. Final make verify-release passed all 1284 Swift tests (32.063 seconds), Viewer
installer transaction checks, 11 Node tests, and the extended 32-tool MCP smoke checks. No compiler
warnings were emitted. git diff --check passed. Logs: /tmp/spaceo-mcp-lifetime-focused.log,
/tmp/spaceo-mcp-lifetime-build.log, and /tmp/spaceo-mcp-lifetime-release.log. AE-192 through AE-194
are fixed. No native live qualification, host installation, or publishing was performed. The
long-running goal remains active.


## Event stream frame admission and storage transfer (AE-195, AE-196)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-195 | Completing a single event frame always constructs a subdata value before discarding the accumulated frame, even when its final byte is the newline and no following bytes need retention. | Remove the terminator and transfer the accumulated Data storage, resetting the search cursor. Coalesced-line and partial-tail paths retain their existing behavior. | Fixed; ownership, framing, and full release checks pass. |
| AE-196 | Every event-stream input byte runs through a Swift newline branch, byte-limit check, and counter increment before the separate framing scan. | For contiguous input, use bounded memchr scans and validate segment lengths between newlines. Keep allocation-free scalar fallback for noncontiguous Collections. Commit buffer and tail state only after the entire incoming chunk passes. | Fixed; exhaustive equivalence, ASan, benchmarks, and full release checks pass. |

The contiguous path checks each segment before adding its length and guards subtraction by the
current tail bound. Consecutive newlines, empty input, exact limits, fragmented existing tails,
and oversized content after a valid line all preserve prior behavior. Errors leave buffered
bytes and tail accounting unchanged. Buffer transfer preserves independent ownership across
subsequent reads, rejected appends, compaction, and inline/empty Data representations. It does
not change event decoding, callbacks, cancellation, EOF handling, or maximum frame sizes.

Twenty-six focused tests pass, including new small-input exhaustive contiguous/fallback
comparisons and retained-frame ownership regressions. An AddressSanitizer probe compares actual
before/after helpers across 33792 size/offset/newline-density/limit combinations, including
8191/8192/8193-byte boundaries; every admission result, emitted line, and remaining-tail flag
agrees, with no sanitizer errors. The probe sources and output are under
/tmp/spaceo-event-buffer-asan*. The retained performance driver is
scripts/benchmark-event-buffer.swift, compiled against actual extracted production helpers.


Optimized actual-helper benchmark, three alternating-order trials. Inputs are ArraySlice<UInt8>
chunks, matching the subscription reader's socket scratch buffer; checksum and frame lengths
are checked in every iteration. Median elapsed times:

| Workload | Before | After |
| --- | --- | --- |
| Four 8 MiB frames in 8 KiB chunks | 907.956 ms | 67.326 ms |
| 20000 single 256-byte frames | 139.605 ms | 13.892 ms |
| 20000 pairs of coalesced 256-byte frames | 278.267 ms | 27.829 ms |

This is about 13.5x faster for the fragmented fixture and 10x for the smaller fixtures. These
are framing-only timings from standalone optimized helpers, not whole-daemon latency. Compiler
specialization and concrete Collection types materially affect the measurements; an earlier
Data-input probe showed only about 2.4x. The final driver uses the actual socket chunk type.
Peak RSS medians in the final four-frame run were 39.875/39.844 MiB, and small-frame cases stayed
near 5.9 MiB. No RSS improvement is claimed. In an earlier 20-frame burst the faster path peaked
near 168 MiB versus 69 MiB before. Removing just the transfer optimization did not remove that
peak. A paused post-burst process fell from a 166.4 MiB peak footprint to 66.5 MiB; vmmap showed
64.2 MiB in empty malloc-large regions and only 80 KiB of live malloc allocations. A separate
leaks probe reported zero leaked malloc blocks. This supports delayed allocator reclamation
under the higher allocation rate; it does not promise a lower transient peak in long bursts.
Neither allocator behavior nor process-wide reclamation policy is changed by this patch.

Benchmark results: /tmp/spaceo-event-buffer-comparison.json. Additional investigations:
/tmp/spaceo-event-buffer-initial-array-comparison.json, /tmp/spaceo-event-buffer-validation.log,
/tmp/spaceo-event-buffer-vmmap.log, and /tmp/spaceo-event-buffer-leaks.log. The optimized sources
are /tmp/spaceo-event-buffer-before.swift and /tmp/spaceo-event-buffer-after.swift. Final make verify-release passed all 1287 Swift tests (33.914 seconds), Viewer installer
transaction checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler warnings were
emitted; git diff --check passed. Logs: /tmp/spaceo-event-buffer-focused.log and
/tmp/spaceo-event-buffer-release.log. AE-195 and AE-196 are fixed. No native displays, applications,
Accessibility observation, input, host install, live qualification, or publishing was used.
The long-running goal remains active.


## Closed event delivery ownership and callback teardown (AE-197, AE-198)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-197 | EventStreamDelivery keeps immutable strong references to its writer closure and EventBus after closing. Retaining a closed handle therefore retains captured writer owners and, for a private bus, its entire event backlog. | Transfer and clear bus, subscription, timer, and writer references under the lifecycle lock; cancel/unsubscribe/release outside it. A selected writer takes a local strong reference until the callback finishes. | Fixed; lifetime and full release checks pass. |
| AE-198 | EventBus.unsubscribe discards the removed Subscriber while holding its nonrecursive lock. Destroying the final callback capture can reenter the bus, deadlock cleanup, and strand subscription resources. | Retain the removed Subscriber through the locked dictionary/order mutation, then release it after unlocking. Preserve idempotence and already-selected delivery semantics. | Fixed; reentrant-destruction and full release checks pass. |

The handshake checks the subscription under the lifecycle lock now that close clears it. Writer
selection is also atomic with close, but already-selected callbacks remain allowed to finish.
waitUntilClosed retains its delivery-queue barrier so descriptor ownership cannot be returned
while a selected write is still using it. Closure and bus destruction happen without either
lifecycle lock held. No event cursor, redaction rule, buffer size, delivery ordering, or callback
signature changes.

Three new deterministic lifetime tests cover final callback destruction reentering the bus,
writer-capture and private-bus deallocation while an explicitly or automatically closed handle
remains retained, and preservation/release of a blocked selected writer across close. Existing
cancellation/barrier, replay/redaction, heartbeat, gap, and multi-waiter tests remain in scope.
These verify object ownership and progress; no process-RSS reduction is inferred.


Final validation passed: 31 focused tests and all 1290 Swift tests in make verify-release
(33.484 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. git diff --check passed. Logs:
/tmp/spaceo-event-lifetime-focused.log and /tmp/spaceo-event-lifetime-release.log. AE-197 and
AE-198 are fixed. No live GUI qualification, host installation, or publishing was performed.
The long-running goal remains active.


## Fair queued event delivery under sustained publication (AE-199)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-199 | A queued subscriber drains until its cursor reaches the current bus head. Continuous producers, including a callback publishing another event, can keep that single work item running indefinitely and starve other serial-queue work such as heartbeats or control actions. | Limit each queued turn to 128 delivery decisions, counting gap notifications and events filtered by the redactor. Keep draining=true while scheduling exactly one continuation; recheck membership and overrun state when it runs. Inline subscriptions retain their original synchronous semantics. | Fixed; deterministic fairness and full release checks pass. |

This is a work-count bound, not a wall-clock deadline: an already-selected callback can still
block according to its own contract. The bounded event ring remains the sole backlog. No event
array, callback task per event, duplicate drain, or new polling timer is introduced. Sequence
order, redaction, overrun notification, and exclusive cursors are preserved across turns.
Queued API documentation now states that one queue barrier does not flush an entire backlog.
The concurrent-producer test waits for its final sequence instead of assuming barrier completion
means all deferred delivery turns have finished. EventStreamDelivery's closure barrier remains
valid because it unsubscribes before scheduling that barrier; later continuations find no
subscriber and cannot write to the returned descriptor.

New deterministic queue-order tests place control work behind the initial drain before the queue
starts. A reentrant producer could generate 1000 events, but the control block runs after exactly
128, unsubscribes, and the continuation delivers nothing further. A second fixture starts after
a ring overrun and filters every retained event: the first gap plus 127 redaction decisions
consume the turn, control work runs, and continuation reaches sequence 1000 without losing or
repeating retained events. These prove bounded work and eventual ordered completion, not a
throughput or RSS improvement.


Final validation passed: 33 focused tests and all 1292 Swift tests in make verify-release
(34.355 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. git diff --check passed. Logs:
/tmp/spaceo-event-fairness-focused.log and /tmp/spaceo-event-fairness-release.log. AE-199 is fixed.
No live GUI qualification, host installation, or publishing was performed. The long-running
goal remains active.


## Bounded Unicode diagnostic clipping work (AE-200, AE-201)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-200 | BoundedDiagnosticText advances by a complete Character before checking its byte size. One 500 KB combining-mark grapheme therefore requires a full scan merely to produce a 480-byte-or-smaller preview. | For oversized strings, construct a byte-bounded sample with four bytes of scalar lookahead, then segment only that sample. Preserve complete original graphemes and the existing ellipsis policy. | Fixed; differential tests, benchmarks, and full release checks pass. |
| AE-201 | DaemonLog calls prefix(4096) before byte clipping, so a large single grapheme is traversed before the bounded helper even receives it. | Apply the existing character cap within the bounded helper, including run-ID clipping. Preserve character-first semantics: reaching 4096 complete characters within the byte budget adds no ellipsis, even if more input follows. | Fixed; logging, exact-fit, and full release checks pass. |

The sample retains full left context from the supplied text's start and enough UTF-8 lookahead
to complete the next scalar at each possible retained boundary. This design follows the
left-context/next-scalar structure of the grapheme rules in [Unicode UAX #29 §3.1.1](https://www.unicode.org/reports/tr29/tr29-45.html#Grapheme_Cluster_Boundary_Rules).
Swift still performs segmentation, so no separate Unicode-property table is introduced. A
replacement character caused by cutting the final sampled scalar lies beyond the returnable
byte range. Tests also exercise substring starts inside scalar/character sequences, CRLF,
regional indicators, emoji modifiers/ZWJ, Indic conjuncts, Hangul, combining and prepend marks.

The existing UTF-8 length guard remains; this bounds grapheme segmentation work and scratch
storage, not every possible foreign-string conversion cost. Already-fitting values retain the
fast path. Caller-owned input is not copied wholesale. Sample decoding consumes at most the
byte cap plus four source bytes (repair of a partial final scalar can add at most two bytes).
No process-RSS improvement is claimed: the change trades a small bounded sample allocation for
avoiding unbounded grapheme walks.

Forty-three focused tests passed. The randomized regression checks 97500 String/Substring
outputs across byte and character limits against the previous pipeline. Additional cases cover
negative/Int.max byte caps, scalar-offset substrings, large combining runs, and 4096 emoji
exactly filling 16384 bytes without an ellipsis, including actual daemon-log serialization.
A standalone comparison on all 1093 sequences from the [Unicode 16 grapheme-break corpus](https://www.unicode.org/Public/16.0.0/ucd/auxiliary/GraphemeBreakTest.txt)
matched 56045 outputs across byte/character caps. This tests compatibility with the runtime's
existing Swift segmentation, not independent conformance of that runtime to a new Unicode version.

Optimized native-String helper benchmark, median of three alternating-order trials (µs/call):

| Fixture | Before | After |
| --- | --- | --- |
| Short ASCII value that already fits | 0.022 | 0.023 |
| 2000 ASCII bytes, 480-byte preview | 7.481 | 3.987 |
| 500001-byte grapheme, 480-byte preview | 3923.977 | 4.518 |
| Same grapheme, log's 4096-character/16384-byte limits | 7854.931 | 143.178 |

These are isolated clipping costs with fixtures built before timing, not full logging or daemon
latency. Driver: scripts/benchmark-diagnostic-prefix.swift. Results:
/tmp/spaceo-diagnostic-lookahead-benchmark.json. Corpus comparison sources/data/log are under
/tmp/spaceo-diagnostic-corpus* and /tmp/spaceo-grapheme-break-test-16.txt. Full release validation
follows below.


Final validation passed: 43 focused tests and all 1295 Swift tests in make verify-release
(33.916 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted. git diff --check passed. Logs:
/tmp/spaceo-diagnostic-lookahead-focused.log and /tmp/spaceo-diagnostic-lookahead-release.log.
AE-200 and AE-201 are fixed. No live GUI qualification, host installation, or publishing was
performed. The long-running goal remains active.


## Best-effort logging admission, telemetry, and rotation (AE-202–AE-204)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-202 | record() captures process metrics and constructs diagnostic fields for every selected request even when the logger is unconfigured; event() only then discards them. | Check configuration after log-selection policy but before task_info/getrusage and field construction. | Fixed; unconfigured-request and full release checks pass. |
| AE-203 | Logging converts arbitrary Double durations directly to Int/Int64, and converts unsigned byte counters to Int64 before subtracting. Non-finite/large durations or counters can trap instead of remaining best-effort telemetry. | Use checked rounded millisecond conversion with an unavailable marker for unrepresentable values. Compute exact signed-text byte deltas by comparing/subtracting unsigned magnitudes. | Fixed; extreme-value serialization and full release checks pass. |
| AE-204 | Rotation recursively removes whatever exists at the predecessor path, ignores removal/move failures, then creates the active file anyway. An unexpected directory can be deleted, or a failed move can be followed by truncation of the unrotated active log. | Replace remove-plus-move with atomic same-directory rename. On failure stop that record and use the existing one-time warning. Check subsequent file creation and permissions instead of silently continuing. | Fixed; preservation/recovery, rotation, and full release checks pass. |

Normal request durations keep their rounded integer representation, including finite negative
elapsed values. CPU deltas retain the previous negative-to-zero clamp for finite values;
non-finite values are explicitly unavailable. Byte deltas remain decimal strings, including
magnitudes outside Int64, so the JSON field types do not change. The configuration check avoids
two process-metrics system calls and temporary field construction on a path that cannot write;
no wall-time benchmark or process-RSS claim is inferred.

A failed rename preserves the current log and predecessor. If rename succeeds but new-file
creation or permission setting fails, the previous content remains in the rotated file and the
new record is refused; this is not a claim of a filesystem-wide transaction or crash durability.
The one-time warning policy and best-effort refusal behavior remain. Rotation no longer has a
remove-first interval or uses recursive deletion for predecessor replacement.

Twenty-one focused tests passed. New regressions exercise unconfigured failures and explicit
metrics, NaN/infinities/extreme finite durations, UInt64.max initial memory counters, negative
and rounded valid elapsed values, an unexpected nonempty predecessor directory with a retained
sentinel, exact preservation of active bytes on refusal, and recovery after that obstruction is
removed. Existing normal rotation tests continue checking parseable predecessor/current records
and owner-only permissions. The failure fixture intentionally emits the logger's one-time
runtime warning; this is not a compiler warning.


Final validation passed: 21 focused tests and all 1298 Swift tests in make verify-release
(33.308 seconds), Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke
check. No compiler warnings were emitted; the one intentional runtime warning is documented
above. git diff --check passed. Logs: /tmp/spaceo-log-resilience-focused.log and
/tmp/spaceo-log-resilience-release.log. AE-202 through AE-204 are fixed. No live GUI qualification,
host installation, or publishing was performed. The long-running goal remains active.


## Daemon telemetry baseline admission and clock semantics (AE-205–AE-207)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-205 | The daemon still captures baseline process metrics for every ordinary request even when startup log configuration failed. AE-202 only skipped the logger's end-of-request work. | Gate the daemon's baseline capture on logger configuration. Preserve baseline sampling for every configured request because an unexpected failure needs a pre-operation sample. | Fixed; focused and full release checks pass. |
| AE-206 | Request duration is measured by subtracting wall-clock Dates. Clock corrections can produce misleading negative or inflated elapsed telemetry and obscure performance diagnosis. | Measure with ContinuousClock and convert its seconds/attoseconds components to the existing TimeInterval logging interface. Keep ISO timestamps as wall-clock dates. | Fixed; focused and full release checks pass. |
| AE-207 | DaemonLog calls its supplied timestamp callback under a nonrecursive lock. A clock/provider that inspects isConfigured or location deadlocks the log write and other callers. | Check configuration, sample the timestamp outside the lock, then enter serialized formatting/rotation/write work. | Fixed; reentrant timestamp regression and full release checks pass. |

The source review confirmed that skipping configured baseline samples merely because debug
logging is disabled would remove useful deltas from unexpected failures. That shortcut was not
adopted. Only an unusable/unconfigured logging destination skips those two metrics system calls.
The new configuration check complements record()'s earlier guard; no claimed metric is synthesized
from a missing baseline, and no counter/result fields change.

Clock callbacks can now inspect logger state without lock reentry. Timestamp formatting, bounded
field construction, JSON allocation, rotation, and file writes stay serialized so this change
does not introduce a queue of prepared large log buffers. The timestamp represents sampling
before the write lock; elapsed request time is independent of wall-clock adjustment.

The new asynchronous regression uses a timestamp callback that reads both configuration and
location and asserts a complete correctly timestamped record. Existing unconfigured tests
confirm that clocks are not invoked when no record can be written. These are control-flow and
progress checks, not end-to-end latency or RSS measurements.


## Parallel agent review: snapshot matching, rendering, and recovery (AE-208–AE-210)

| ID | Inefficiency | Fix | Status |
| --- | --- | --- | --- |
| AE-208 | Matching AX snapshots delete each matched key even though a bitmap also tracks unmatched nodes; read-only lookup was a possible optimization. | Compared lookup with removal using a standalone synthetic harness. Restored the original implementation because results did not establish a reliable gain and lookup retains consumed keys longer. | Investigated; no supported production fix. Benchmark retained. |
| AE-209 | Each rendered AX node builds an interpolated indent/tag/role string, and common AX roles allocate a replacement string before appending to the outline. | Append components directly and use a compatible fast path for ordinary role prefixes. | Fixed; Unicode regressions, benchmark, and full release checks pass. |
| AE-210 | MCP failure rendering omits the session returned by a partial creation failure even when controller bookkeeping retains its lease. Agents need an extra discovery call before addressing that session. | Include bounded session identity in failure output without exposing leases or claiming successful creation. | Fixed; exact session-ID, ownership-evidence, and full release checks pass. |

Three GPT-6-Sol agents investigated separate files under root coordination. Source edits and
benchmarks are isolated by ownership; package builds and deterministic validation run centrally.
No live application, input, display, or host-configuration work is part of this pass.

AE-209 measurement uses scripts/benchmark-observation-rendering.swift, compiled with swiftc -O
and the actual renderer plus a synthetic AXNode type. Forty-one alternating samples each render
twenty 4,000-node outlines with common roles and unusual-prefix fallbacks. Root's rerun measured
4.652 ms before and 2.692 ms after (1.73×); output contains 276,269 identical UTF-8 bytes. This is
a synthetic CPU/wall-time microbenchmark, not end-to-end application latency or an RSS claim.
Regression cases include combining marks on leading and embedded AX sequences.

AE-210 adds the retained-session guidance only for a failed session.create request with both
a returned session and controller lease. The lease is never rendered. Session IDs must meet
existing byte/character/control/path bounds and are included whole, so the recovery target stays
actionable. Tests cover missing ownership evidence, unrelated commands, missing sessions,
128-character ASCII and 512-byte Unicode IDs, oversized IDs, and invalid path separators.

Central focused validation passed all 66 selected tests across DaemonLogTests,
AXSnapshotDiffTests, AXObservationRenderingTests, and MCPToolTranslationTests.
Log: /tmp/spaceo-agent-efficiency-focused.log. Full release results are recorded below.

AE-208 was not shipped as an optimization. The actual diff implementation with stub node and
result types was measured on 4,000-node identical and mostly changed snapshots. Timing results
conflicted between runs, and the lookup candidate retains matched key strings until the entire
comparison ends. That tradeoff did not justify a production change. The agent restored only its
single-line edit and retained scripts/benchmark-snapshot-lookup.swift for future investigation;
prior snapshot-history and diff improvements remain intact. No speed or RSS improvement is claimed.

Final validation passed: make verify-release completed with 1301 Swift tests (33.247 seconds),
Viewer installer transaction checks, 11 Node tests, and the 32-tool MCP smoke check. No compiler
warnings were emitted. The deliberate log-rotation refusal fixture produced its expected
one-time runtime warning. Log: /tmp/spaceo-agent-efficiency-release.log. git diff --check passed.
AE-205–AE-207, AE-209, and AE-210 are fixed; AE-208 is an investigated candidate with no retained
production change. No live GUI qualification, installation, or publishing was performed.
The broader long-running project is not complete.


## Release gate toolchain drift (AE-211)

Release preparation found that Tests/ReleaseSecurityTests.sh still required Xcode 26.0.1 /
Swift 6.2 while commit cec7173 had moved CI and both release jobs to the self-hosted Apple Silicon
runner with Xcode 27.0 / Swift 6.4. The stale test refused the intended workflow before candidate
checks could run. The regression now asserts the exact current runner, path, and version pins
in CI and both release jobs, and its fixtures reject the old Xcode and Swift versions.
No workflow, signing requirement, publication gate, or toolchain check was removed.
Validation is recorded in docs/validation/2026-09-23-release-preparation.md.
