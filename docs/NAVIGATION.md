# Repository navigation

Read [AGENTS.md](../AGENTS.md) first, then choose the task below. Paths are relative to the
repository root. Discover files and symbols before reading a large implementation or work log.

## Which document answers the question?

| Question | Start here | How to interpret it |
| --- | --- | --- |
| What should I work on now? | [TICKETS.md — Active milestone](../TICKETS.md#active-milestone) | Current priorities and links to evidence; older ticket bodies retain historical acceptance criteria. |
| What is implemented? | Relevant source/tests below; [CHANGELOG.md](../CHANGELOG.md) | Check the checkout's implementation. A historical finding is not proof a feature is still missing. |
| What display operations are allowed? | [DISPLAY_SAFETY.md](DISPLAY_SAFETY.md), [AGENTS.md](../AGENTS.md#safety) | Current lifecycle safeguards and agent constraints; older unrestricted-resource decisions are superseded. |
| What are the architecture contracts? | [ARCHITECTURE.md](../ARCHITECTURE.md) | Layer contracts; detailed display constraints live in DISPLAY_SAFETY.md. |
| What is published or qualified? | [RELEASE_POLICY.md — Current status](RELEASE_POLICY.md#current-status) | Recorded status and per-release exceptions. Recheck GitHub for live publication state when the task requires it. |
| What is required to release? | [RELEASE_POLICY.md](RELEASE_POLICY.md), [LIVE_TESTS.md](LIVE_TESTS.md) | Current gates. The 1.0.0 handoff is historical, not a checklist for a new version. |
| How does an agent use the product? | [REFERENCE.md](REFERENCE.md), [playbook/README.md](playbook/README.md) | User-facing contracts and canonical MCP prompt/resource sources. |
| Why was something changed? | [RELEASE_AUDIT.md](../RELEASE_AUDIT.md), [FINDINGS.md](../FINDINGS.md), relevant dated plan/validation record | Evidence for that revision and workload, not blanket qualification of today's source. |
| Where are performance findings? | [PERFORMANCE.md](PERFORMANCE.md), then search [AGENT_EFFICIENCY.md](AGENT_EFFICIENCY.md) by symbol or AE ID | Procedure first; the efficiency file is a long chronological work log. |
| How do I investigate real agent friction? | [IMPROVEMENT_LOOP.md](IMPROVEMENT_LOOP.md) | Product journal workflow; keep full journals and private content out of public records. |

[PRODUCT_BACKLOG.md](../PRODUCT_BACKLOG.md) is the original product review with later status
summaries. Its Evidence/Impact text often describes the pre-fix state, and some older Open labels
are superseded by the summaries. [OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md),
[RELEASE_HANDOFF_1.0.0.md](RELEASE_HANDOFF_1.0.0.md), `docs/plans/`, and `docs/validation/` are dated
records. Preserve their evidence; link later dispositions rather than treating old counts,
versions, or NO-GO statements as current. Never infer live qualification from a Done label.

## Task to implementation and tests

The source and test names below are entry points, not an exhaustive dependency list. Test files
are in `Tests/SpaceOKitTests/` unless another path is shown. A listed suite can contain multiple
test classes; discover the class before choosing a Swift test filter.

| Task | Source entry points | Test entry points and guidance |
| --- | --- | --- |
| Add/change a CLI or MCP command | `Sources/spaceo/main.swift`; `Sources/SpaceOKit/CLIArguments.swift`, `CLIHelp.swift`, `Protocol.swift`; `Sources/SpaceOMCP/MCPServer.swift`; `Sources/SpaceOKit/SessionManager.swift` and `SessionManager+*.swift` | `MCPToolTranslationTests.swift`, `MCPCompactReceiptTests.swift`; `scripts/mcp-smoke.mjs`; [REFERENCE.md](REFERENCE.md). Align schemas, help, validation, limits, leases, and receipts. |
| MCP framing, diagnostics, connection state | `Sources/SpaceOMCP/MCPInputLine.swift`, `MCPDiagnostic.swift`, `MCPConnectionMemory.swift`, `MCPServer.swift` | `MCPInputLineTests.swift`, `MCPStdinFailureTests.swift`, `MCPDiagnosticTests.swift`; `scripts/benchmark-mcp-*.swift` and `.mjs`. |
| MCP prompts, resources, agent guidance | `docs/playbook/*.md`; `scripts/generate-playbook.mjs` | `PlaybookTests.swift`, `MCPPromptTests.swift`; [playbook/README.md](playbook/README.md). Generated destination: `Sources/SpaceOMCP/Playbook.swift`. |
| Display creation, reuse, teardown, health | `Sources/SpaceOKit/Stage.swift`, `DisplayPool.swift`, `DisplayLifecycleCoordinator.swift`, `DisplayLifecycleLease.swift`, `DisplayHostHealth.swift`, `DisplayHostHealthSampler.swift`, `ResourceBudget.swift` | `DisplayLifecycleContainmentTests.swift`, `DisplayHostHealthTests.swift`, `DisplaySafetyTests.swift`, `OwnershipAndBudgetTests.swift`; [DISPLAY_SAFETY.md](DISPLAY_SAFETY.md). |
| Daemon socket, startup, restart, deadlines | `Sources/SpaceOKit/Transport.swift`, `DaemonRestart.swift`; `Sources/spaceo/HostCommands.swift` | `TransportStartupLockTests.swift`, `TransportDeadlineTests.swift`, `TransportStreamingTests.swift`, `DaemonRestartTests.swift`; [UPDATING.md](UPDATING.md). |
| Session ownership, leases, recovery | `Sources/SpaceOKit/SessionManager.swift`, `SessionManager+Lifecycle.swift`, `AgentSession.swift`, `ProcessOwnership.swift`, `SessionStore.swift`, `DetachedSessionRecovery.swift` | `SessionLifecycleRaceTests.swift`, `OwnershipAndBudgetTests.swift`; [SESSION_RECOVERY.md](SESSION_RECOVERY.md). |
| App launch, placement, late windows | `Sources/SpaceOKit/AppLauncher.swift`, `LaunchFailureCleanup.swift`, `WindowPlacement.swift`, `WindowWatcher.swift`, `AXWindowDiscovery.swift` | `CleanSlateLaunchTests.swift`, `LaunchPollingTests.swift`, `LaunchFailureCleanupTests.swift`, `WindowWatcherTests.swift`, `WindowPlacementTransactionTests.swift`. |
| Accessibility reads, identity, diffs, text | `Sources/SpaceOKit/AXTree.swift`, `AXTraversal.swift`, `AXSupport.swift`, `AXWindowDiscovery.swift`, `AXSnapshotCache.swift`, `AXSnapshotDiff.swift`; `SessionManager+Ergonomics.swift` | `AXTraversalTests.swift`, `AXSnapshotDiffTests.swift`, `AXWindowIdentityTests.swift`, `AXObservationRenderingTests.swift`. Discover `*Text*` files for text-only traversal. |
| Input and managed browser behavior | `Sources/SpaceOKit/InputRouter.swift`, `ChromiumBridge.swift`, `AgentSession.swift`, `SessionManager.swift`; `AppLauncher.swift` for target admission | `PointerSurfaceTests.swift`, `ChromiumBridgeTests.swift`, `ChromiumDeadlineTests.swift`, `MCPToolTranslationTests.swift`, `AXMenuTests.swift`; [PRIVATE_API_SUPPORT.md](PRIVATE_API_SUPPORT.md), [TRANSCRIPT_WORKFLOWS.md](TRANSCRIPT_WORKFLOWS.md). Managed Electron launch is refused; retained adapter code does not establish support. |
| Screenshot ownership, encoding, frames | `Sources/SpaceOKit/Capture.swift`, `CapturePNG.swift`, `CaptureFrameHash.swift`; `Sources/SpaceOMCP/PNGBase64.swift` | `RecordingFrameCaptureTests.swift`, `WaitFrameCaptureTests.swift`, `CaptureFrameHashTests.swift`; [RECORDING.md](RECORDING.md). |
| Viewer layout, selection, controls | `Sources/SpaceOViewer/ContentView.swift`, `SidebarView.swift`, `InspectorView.swift`, `ViewerStyle.swift`, `ViewerModel.swift`, `ViewerModel+*.swift` | `ViewerAccessibilityTests.swift`, `ViewerSessionStatusTests.swift`, `ViewerControlPlaneTests.swift`; `ViewerPreview.swift`, `scripts/viewer-snapshots.sh`. Agents must launch Viewer with `--background`; previews still create sessions and require eligible host conditions. |
| Viewer streaming, rendering, event load | `Sources/SpaceOViewer/DisplayStream.swift`, `SurfaceView.swift`, `ViewerLatestValue.swift`, `ViewerEventMailbox.swift`, `ViewerModel+EventStream.swift` | `ViewerStreamLifecycleTests.swift`, `ViewerLatestValueTests.swift`, `ViewerEventMailboxTests.swift`; [PERFORMANCE.md](PERFORMANCE.md). |
| Setup, TCC attribution, client configuration | `Sources/spaceo/HostCommands.swift`; `Sources/SpaceOKit/DoctorReport.swift`, `MCPClientConfig.swift`, `MCPClientInspection.swift`, `SetupRemedies.swift`, `LaunchAgentInstaller.swift` | `SetupTests.swift`, `SetupRemediesTests.swift`, `MCPClientConfigTests.swift`, `MCPClientInspectionTests.swift`; [SETUP.md](SETUP.md). |
| Installer, packaging, signing, CI | `install.sh`, `scripts/release.sh`, `scripts/make-viewer-app.sh`, `scripts/install-viewer-app.sh`, `.github/workflows/` | `Tests/InstallScriptTests.sh`, `Tests/ViewerInstallTests.sh`, `Tests/ReleaseSecurityTests.sh`, `Tests/WorkflowPrivacyTests.py`; [INSTALL.md](INSTALL.md), [RELEASE_POLICY.md](RELEASE_POLICY.md). |
| Performance measurement and benchmarks | `Sources/SpaceOPerformance/`, `Sources/SpaceOKit/PerformanceTrace.swift`; `scripts/benchmark-*`, `scripts/performance-*`, `scripts/metrics-report.mjs` | `Tests/PerformanceFixtureTests.py`, `Tests/PerformanceReportTests.py`; [PERFORMANCE.md](PERFORMANCE.md). Prefer synthetic workloads before live ones. |
| Private API discovery/calls | `Sources/SpaceOPrivate/` | [PRIVATE_API_SUPPORT.md](PRIVATE_API_SUPPORT.md), [RELEASE_AUDIT.md](../RELEASE_AUDIT.md). Keep direct private API calls in this target. |

## Bounded discovery

Find the current path instead of guessing names from an old session or a historical line number:

```sh
rg --files Sources Tests scripts | rg 'AXSnapshot|DisplayLifecycle|MCP|Viewer'
rg -n '^(##|###) ' TICKETS.md docs/AGENT_EFFICIENCY.md
rg -n 'windowID|snapshotHistory' Sources/SpaceOKit Tests/SpaceOKitTests
sed -n '1,95p' TICKETS.md
```

Use the relevant symbol's matching section next. For a ticket ID, search both the current ledger
and its historical review: `rg -n 'SPAO-148' TICKETS.md PRODUCT_BACKLOG.md docs`.
For workflow paths, use `rg --files --hidden .github`; normal file discovery skips hidden paths.
Plans are Markdown; earlier sessions referring to `.html` plans predate their conversion.

## Build and runtime provenance

`VERSION` and `Sources/SpaceOKit/SpaceOVersion.swift` define the checkout's version. CI pins its
toolchain in `.github/workflows/ci.yml`; Swift's package tools version is not that compiler pin.
Before diagnosing installed behavior, distinguish the checkout, `.build` artifact, installed
CLI, and already-running daemon using [UPDATING.md](UPDATING.md). Matching version strings do not
prove identical builds. Do not install or restart merely to verify a source edit.

SwiftPM serializes builds sharing a scratch directory. Check existing build activity before
starting another build in the same checkout; an intentional separate scratch path can avoid
contention for direct Swift commands. The Makefile verification still checks the normal `.build`
artifacts. Keep final verification tied to the actual changed checkout.

## Keeping the map useful

When moving an entry point or replacing a procedure, update this map and links from AGENTS.md.
Keep changing release status and detailed safety limits in their authoritative documents rather
than copying them here. Mark superseded acceptance criteria at the old finding, and link the
replacement. Generate the embedded playbook after Markdown changes; its existing tests detect
drift. See the [20-session retrospective](retrospectives/2026-10-03-navigation.md) for the evidence
behind this map and remaining improvement ideas.
