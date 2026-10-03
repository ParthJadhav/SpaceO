# Navigation retrospective — 20 coding-agent sessions

Reviewed October 3, 2026. The largest recurring navigation cost is selecting the right source
of truth: agents repeatedly read large historical files, then rediscover current entry points
or correct old status statements. There is enough evidence to improve documentation routing;
there is not enough evidence to assign an honest number of wasted minutes to each problem.

## Scope and method

Selected the 20 most recently started top-level SpaceO sessions available locally across Codex
and Claude Code: **9 Codex and 11 Claude Code**, starting September 15–October 1, 2026. Selection
uses session creation time, not last modification, so a resumed long-running goal is one session.
This retrospective, metadata-only records, and separately counted subagents are excluded.
Marketing and launch-video tasks are retained because they are part of those 20 repository
sessions; their external-service delays are not attributed to repo navigation.

Scanned the selected JSONL streams, extracted user/assistant messages and tool calls, and examined
initial discovery, document searches, missing-path/truncation results, regeneration, and status
corrections. Delegation briefs/results in parent sessions are included; this is not an independent
review of every child transcript. Checked the resulting hypotheses against today's files.
Private raw transcripts remain outside the repository. Only sanitized navigation observations
and session identifiers are recorded here.

References such as **S02 L18** mean session S02 in the table below, JSONL line 18 in its local
export. The session IDs let the owner locate the corresponding export; no private absolute paths
or raw application content are included. Export line numbers are evidence locators, not source
code line numbers. Tool counts and elapsed time include useful work, so neither is treated as
waste. No claim is made that all twenty sessions encountered every issue.

## Findings, ordered by expected benefit

### 1. Route discovery before opening long documents

**Observed.** S02 L18 concatenates AGENTS, PRODUCT_BACKLOG, TICKETS, the release audit, package,
Makefile, README, and file listings. L23 reports truncated output; L27 then searches headings and
statuses and L36 rereads a ticket section. S06 L18 searches performance terms across source,
scripts, docs, and backlogs in one call; L21 truncates. S12 L19 and S14 L18 similarly combine
large source/docs reads and produce truncated output at L25 and L23. S18 L18–41 repeatedly
searches and rereads source and historical findings, with truncation at L32. S17 L36 reads the
entire product backlog; L41 truncates and L49 reads the retained tool-result file again.

**Still present.** Before this change, PRODUCT_BACKLOG had 791 lines, TICKETS 1,353, RELEASE_AUDIT
623, and AGENT_EFFICIENCY 3,250. A directory-level map does not tell an agent which file owns a
specific contract or where its deterministic tests are. Increasing the output cap only postpones
the same problem.

**Applied.** [NAVIGATION.md](../NAVIGATION.md) routes task → source → test → authoritative guide.
AGENTS, README, and CONTRIBUTING link to it. AGENTS now directs symbol/heading searches and
section reads before whole-file concatenation. The map routes active work directly to TICKETS'
Active milestone rather than reproducing its changing status.

### 2. Distinguish historical findings from current behavior

**Observed.** S02 L1286 explicitly reports correcting a backlog claim that lifecycle limits and
incident latches were absent. S09 L45 searches old version references across the repo before
renumbering the release. S10 L401 distinguishes current-facing docs from dated evidence. S20
L35, L45, and L71 reads the old product review in three pieces while looking for new work.

**Still present.** PRODUCT_BACKLOG calls a September 5 audit the latest review and presents the
original four-action capability summary in the present tense, despite later implementation
summaries. Several original Open labels remain beneath those summaries. TICKETS SPAO-104 and
SPAO-128 retain Done acceptance criteria requiring unrestricted creation. More seriously,
ARCHITECTURE still described no configured resource ceilings, no creation rate limit, and
ownerless displays as diagnostic only, contrary to Stage's current safeguards and DISPLAY_SAFETY.
It also described the retained Electron adapter without clearly stating managed launch refusal.

**Applied.** Added historical-use guidance to the backlog and ticket ledger, changed the old
capability summary to past tense, and marked the unrestricted-creation ticket criteria as
superseded. Corrected architecture claims about configured budgets, persistent admission,
unknown cleanup, Electron launch policy, and unconfirmed input. Removed its obsolete cursor-fence
verdict and positional-session CLI examples, routing command syntax to REFERENCE instead.
Current safeguard details remain in DISPLAY_SAFETY rather than being copied into a new
status dashboard. Historical evidence and old qualification results are preserved.

**Remaining.** Older backlog item statuses still need an item-by-item reconciliation against
implementation and retained evidence. This change labels their scope; it does not promote them
to Done or imply live qualification.

### 3. Release context needs a single current entry point

**Observed.** S14 L1372 reports automated review blockers involving stale release documentation;
L1396 reports correcting contradictory release notes and clarifying the evidence commit.
S05 L64–88 searches live-runner/workflow references across tests and several docs. L454 explains
that repeated review rounds required fixing local qualification instructions, release rules, and
the handoff. S06 L5915 reports another historical-wording correction concerning release status.

**Still present.** The old handoff has a historical banner but a prominent `Status: NO-GO` and
obsolete publication-setting claims below it. Its previous banner directs readers to the
September 24 open-source preparation record, which itself begins with pending binary
qualification wording. Following that chain is a poor way to learn the current recorded state.

**Applied.** Both historical records now route straight to RELEASE_POLICY's Current status.
The navigation authority table distinguishes policy, recorded status, dated evidence, and live
GitHub state. It also explains that an old artifact's evidence does not qualify a new artifact.
Release gates and per-release exceptions were not changed.

**Already fixed before this retrospective.** The self-hosted live workflow was removed, and
LIVE_TESTS now owns the retained local qualification procedure. Do not reintroduce duplicated
runner setup merely because an older session referred to it.

### 4. Make generated documentation ownership visible at the entry point

**Observed.** S18 L3326 reports that event-cursor guidance was missing from the embedded MCP
playbook. L5503 reports another verification failure because compiled playbook content predated
the final Markdown edit. Both discoveries occur at the full verification stage and require
regeneration and another run.

**Still present.** The generator and drift tests already solve this mechanically, but the
regeneration instruction was in the generator header and playbook README, rather than AGENTS.
An agent discovering MCPServer or Playbook.swift first can miss the canonical Markdown source.

**Applied.** AGENTS and the navigation map now give the exact source, generation command,
destination, and relevant suites: `node scripts/generate-playbook.mjs`, PlaybookTests, and
MCPPromptTests. No second generator or duplicate test was added.

### 5. Find symbols and actual filenames instead of guessing them

**Observed.** S18 L36 looks for `Tests/SpaceOKitTests/SnapshotDiffTests.swift`; L39 reports the
missing file. L41 switches to filename discovery and L51 reads `AXSnapshotDiffTests.swift`.
S12 L19/L29 tries `scripts/test-live.sh`; L34 returns to Makefile and script discovery. The
supported wrapper is `scripts/test.sh`. S17 L58–85 repeatedly extracts text/headings from an
HTML plan to avoid duplicating the earlier UX round.

**Applied.** Task rows provide current test/source names and bounded `rg --files` patterns.
The map explicitly calls out hidden `.github` discovery, the shared test wrapper via AGENTS,
and Markdown plans. No source files were renamed merely to match earlier guesses.

**Already fixed before this retrospective.** The HTML plans were converted to Markdown during
open-source preparation. The original extraction friction is real historical evidence, but
today's repo does not need another format conversion.

### 6. Keep source, installed build, running daemon, and compiler separate

**Observed.** S14 L559 reports a Swift 6.2 compatibility failure accepted by the newer local
compiler and a screenshot attempt using an older running daemon. S17 L108–113 checks installed,
built, and source versions before dogfooding. S06 L1232 reports a Viewer rebuild waiting on
SwiftPM's build lock. S15 L20 and later verification work rely on shared-workspace/scratch-build
notes stored outside the repo.

**Applied.** The map points to UPDATING for runtime provenance and the CI workflow for the
compiler pin, distinguishes the package tools version, and records SwiftPM scratch-directory
contention. AGENTS says that building does not replace the installed CLI or running daemon.
Host changes remain task-dependent; this retrospective does not install or restart anything.

**Limit.** The build-lock observation establishes contention, not that repo navigation caused
the wait. It should not be included in claimed time savings from these documentation changes.

## Session inventory

Dates are UTC start dates. All selected sessions were reviewed; “no finding” means no strong
repo-navigation problem was established, not that the entire task was fast or flawless.

| Ref | Start | Provider and session ID | Task | Navigation evidence |
| --- | --- | --- | --- | --- |
| S01 | 2026-10-01 | Claude `2691c69f-2c2c-4d20-ae9e-6d24a4e007bf` | Shorten release text | L25–42 locates notes and references directly; no strong navigation finding. |
| S02 | 2026-09-29 | Codex `01a0ec62-4379-79e3-886c-38150c0ea570` | Reliability/completeness goal | L18–36 oversized orientation; L1286 stale backlog correction. |
| S03 | 2026-09-28 | Codex `01a0e9b8-6640-7ae0-901c-27995abb01b8` | Research promotion venues | External policy research; no repo-navigation finding. |
| S04 | 2026-09-28 | Codex `01a0e9b5-a34f-7a51-9c7e-ff8ddfed89a4` | Marketing copy | L15–20 finds and reads README directly; no strong navigation finding. |
| S05 | 2026-09-28 | Claude `eb4ffbb5-9591-42fd-b8cf-7c63461293f6` | CI runner/qualification docs | L64–88 scattered references; L454 repeated documentation review fixes. |
| S06 | 2026-09-28 | Codex `01a0e748-c4af-78c2-a085-738e961771dd` | CPU/GPU/memory goal | L18–31 broad truncated discovery; L1232 build lock; L5915 historical release wording. |
| S07 | 2026-09-27 | Codex `01a0e453-4740-7d42-987c-aec6674e57aa` | Privacy/security and release follow-up | Large discovery/audit reads; no separate proven stale-doc finding. |
| S08 | 2026-09-27 | Claude `1fdc07dd-24dc-4864-b640-c3e49e65a8f2` | Simplify install/setup | L24–51 moves from install docs to HostCommands and client config; useful focused trace. |
| S09 | 2026-09-27 | Claude `7bd7ee63-8fe6-414d-af8b-1c29b423c403` | First-release version reset | L24–45 resolves release memory, live tags, versions, and historical references. |
| S10 | 2026-09-26 | Claude `a25c847e-b774-471e-b14c-dc61a30a958e` | Public repo/releases/README | L401 explicitly distinguishes current docs from dated records. |
| S11 | 2026-09-26 | Claude `87bef6cc-a26c-44e1-b1f1-e984e4e9db18` | Launch video | L41–50 discovers brand and marketing workspace; external media-tool friction excluded. |
| S12 | 2026-09-24 | Codex `01a0d4f7-ee79-7a63-8123-b6d6318d089c` | Display failure containment | L19–34 broad truncated reads and guessed live-test wrapper. |
| S13 | 2026-09-24 | Claude `765bebc4-c88c-435d-9a77-9317c1bf27b1` | Menu-bar logo | L25–48 finds brand assets and symbol directly; no strong navigation finding. |
| S14 | 2026-09-24 | Codex `01a0d3c0-a08b-7803-aa0d-e551453063b2` | Open-source/release preparation | L18–40 truncation; L559 toolchain/daemon provenance; L1372–1396 stale-doc corrections. |
| S15 | 2026-09-24 | Claude `0137d46b-d289-4346-9658-febeebaaa6d6` | Viewer redesign | L20 external workspace/build notes; L38–50 narrows to Viewer files. |
| S16 | 2026-09-24 | Claude `6fe87a79-3207-4b1e-b93d-4f415b404e51` | Three launch videos | Skill/template/media work dominates; no strong current repo-navigation finding. |
| S17 | 2026-09-22 | Claude `3a0ce7b4-d10f-4221-a942-16998712bd07` | Whole-product UX round | L36–85 truncated backlog and repeated HTML-plan extraction; L108–113 runtime provenance. |
| S18 | 2026-09-21 | Codex `01a0c53d-d890-7580-85ff-52ab6367727e` | Agent efficiency/performance goal | L18–51 discovery/truncation/missing test; L3326 and L5503 embedded-playbook drift. |
| S19 | 2026-09-17 | Codex `01a0b0b3-54fd-75a3-bd8a-ab74e9b2a34b` | Viewer UI/performance | L18–51 targeted Viewer reads; map can shorten orientation, but no prolonged search established. |
| S20 | 2026-09-15 | Claude `2ac2dfc5-734e-4510-85c1-4d395468ad28` | Whole-product UX plan/implementation | L35, L45, L71 three-part historical backlog read; L75 attempts open-ticket discovery. |

## Follow-ups worth doing

1. **Reconcile old backlog labels by ticket.** Link each superseded item to its implementation
   and evidence, preserving separate implementation and qualification states. Avoid an automatic
   “all implemented” conversion of historical acceptance criteria.
2. **Add a small documentation check if drift continues.** Check broken local links and mapped
   entry-point paths in the existing safe workflow. Existing playbook drift tests are sufficient
   for generated guidance. Do not add another manually maintained status database.
3. **Consider source extraction only with repeated evidence.** SessionManager, AgentSession,
   MCPServer, and Transport are large and often searched. A file map is the low-risk first fix;
   these twenty sessions do not by themselves justify a broad runtime refactor.
4. **Measure the next comparable sessions.** Record discovery calls before the first relevant
   source/test read, repeated section reads after truncation, missing-path errors, and docs found
   stale at verification/review. Compare similar tasks and exclude tests, CI waits, approvals,
   and external research. No measured navigation speedup is claimed yet.

## Validation scope

This change updates navigation and documentation, not runtime behavior, release gates, or host
configuration. Verification passed:

- 131 local links, all mapped paths and test filenames, and changed-document privacy checks.
- `git diff --check` and `make verify-release`: 1,701 Swift tests, 15 Node tests, supporting checks,
  and MCP smoke covering 35 tools.
- `bash Tests/ReleaseSecurityTests.sh`, `bash Tests/LiveTestGateTests.sh`, and
  `swift build -c release -Xswiftc -warnings-as-errors`.

No live display/input qualification follows from those checks. The existing working-tree edit
to the 1.0.5 release notes is preserved. No navigation speedup has been measured yet.
