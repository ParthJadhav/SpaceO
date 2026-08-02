import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import SpaceOKit
import SwiftUI

struct DisplayEntry: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let isSpaceO: Bool
    let isActive: Bool
    let name: String

    /// Rect equality at capture resolution. Anything non-finite counts as a change so a bad
    /// reading can never be mistaken for "nothing moved".
    static func rectsMatch(_ lhs: CGRect,
                           _ rhs: CGRect,
                           tolerance: CGFloat = 0.5) -> Bool {
        let deltas = [
            abs(lhs.minX - rhs.minX),
            abs(lhs.minY - rhs.minY),
            abs(lhs.width - rhs.width),
            abs(lhs.height - rhs.height),
        ]
        return !deltas.contains { !$0.isFinite || $0 >= tolerance }
    }
}

struct PermissionState: Equatable {
    var screenRecording = false
    var accessibility = false
}

enum ViewerStreamState: Equatable {
    case idle
    case starting
    case live
    case failed(String)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .live: "live"
        case .failed: "failed"
        }
    }
}

enum ViewerSessionBadge: Equatable, Sendable {
    case owned
    case abandoned
    case reclaimable
    case cleanupPending

    var title: String {
        switch self {
        case .owned: "Owned"
        case .abandoned: "Abandoned"
        case .reclaimable: "Reclaimable"
        case .cleanupPending: "Cleanup pending"
        }
    }

    var systemImage: String {
        switch self {
        case .owned: "person.crop.circle.fill"
        case .abandoned: "exclamationmark.triangle.fill"
        case .reclaimable: "arrow.uturn.backward.circle.fill"
        case .cleanupPending: "hourglass.circle.fill"
        }
    }
}

/// A small, deterministic presentation model keeps lifecycle precedence, duration wording, and
/// overlay admission consistent without making the Viewer's read-only polling path stateful.
struct ViewerSessionPresentation: Equatable, Sendable {
    let badge: ViewerSessionBadge?
    let ownerText: String?
    let timingText: String?

    init(session: SessionInfo, now: Date = Date()) {
        self.init(
            teardownPending: session.teardownPending,
            controllerOwner: session.controllerOwner,
            ageSeconds: session.ageSeconds,
            lastActivityAt: session.lastActivityAt,
            abandoned: session.abandoned,
            reclaimable: session.reclaimable,
            now: now
        )
    }

    init(
        teardownPending: Bool,
        controllerOwner: DurableSessionOwner?,
        ageSeconds: TimeInterval?,
        lastActivityAt: Date?,
        abandoned: Bool?,
        reclaimable: Bool?,
        now: Date = Date()
    ) {
        if teardownPending {
            badge = .cleanupPending
        } else if reclaimable == true {
            badge = .reclaimable
        } else if abandoned == true {
            badge = .abandoned
        } else if controllerOwner != nil {
            badge = .owned
        } else {
            // Older daemons do not send controller metadata. Absence is not abandonment.
            badge = nil
        }

        if let controllerOwner {
            let trimmedLabel = controllerOwner.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedLabel.isEmpty ? controllerOwner.id : trimmedLabel
            ownerText = "Owner: \(displayName) · \(Self.ownerKindName(controllerOwner.kind))"
        } else {
            ownerText = nil
        }

        var timingParts: [String] = []
        if let lastActivityAt {
            let elapsed = max(0, now.timeIntervalSince(lastActivityAt))
            if elapsed.isFinite {
                let relative = elapsed < 10
                    ? "just now"
                    : "\(Self.compactDuration(elapsed)) ago"
                timingParts.append("Last activity \(relative)")
            }
        }
        if let ageSeconds, ageSeconds.isFinite {
            timingParts.append("Age \(Self.compactDuration(max(0, ageSeconds)))")
        }
        timingText = timingParts.isEmpty ? nil : timingParts.joined(separator: " · ")
    }

    func accessibilityDescription(sessionID: String) -> String {
        var parts = ["Session \(sessionID)."]
        if let badge {
            parts.append("Status: \(badge.title).")
        }
        if let ownerText {
            parts.append("\(ownerText).")
        }
        if let timingText {
            parts.append("\(timingText).")
        }
        return parts.joined(separator: " ")
    }

    /// Only live SpaceO geometry is eligible for an overlay. An omitted attachment flag is
    /// accepted for compatibility with older daemons, whose lists contained only live sessions.
    static func overlayFrame(
        displayID: UInt32,
        frame: CGRect,
        runtimeAttached: Bool? = nil,
        on display: DisplayEntry
    ) -> CGRect? {
        guard runtimeAttached != false,
              display.isSpaceO,
              display.isActive,
              display.id == displayID else {
            return nil
        }
        let values = [
            display.bounds.minX, display.bounds.minY,
            display.bounds.width, display.bounds.height,
            frame.minX, frame.minY, frame.width, frame.height,
        ]
        guard values.allSatisfy(\.isFinite),
              display.bounds.width > 0,
              display.bounds.height > 0,
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

        // WindowServer geometry can differ by a sub-point during a display transition. Admit
        // that rounding only; records whose old tiles no longer belong to this display stay out.
        let liveBounds = display.bounds.insetBy(dx: -0.5, dy: -0.5)
        guard liveBounds.contains(frame) else { return nil }
        return frame
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3_600 {
            return "\(totalSeconds / 60)m"
        }
        if totalSeconds < 86_400 {
            let hours = totalSeconds / 3_600
            let minutes = (totalSeconds % 3_600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    private static func ownerKindName(_ kind: DurableSessionOwnerKind) -> String {
        switch kind {
        case .cli: "CLI"
        case .mcp: "MCP"
        case .viewer: "Viewer"
        case .other: "Other"
        @unknown default: "Other"
        }
    }
}

@MainActor
final class ViewerModel: ObservableObject {

    typealias DiscoverySnapshot = (displays: [DisplayEntry], permissions: PermissionState)
    typealias DiscoveryProvider = @MainActor () -> DiscoverySnapshot
    typealias DaemonTransport = @Sendable (Request) throws -> Response
    /// Raising the system permission prompts is the one Viewer action a test must never take:
    /// it puts a modal panel on the machine running the suite.
    typealias PermissionPrompt = @MainActor (PermissionState) -> Void

    private struct StreamTarget: Equatable, Sendable {
        let display: DisplayEntry
        let sourceRect: CGRect?
        let interactionDisplay: DisplayEntry

        /// Everything a restart would actually change: which display is captured, which region
        /// of it, and where clicks land. Deliberately narrower than `Equatable`, which also
        /// covers `DisplayEntry`'s cosmetic fields — `name` lags behind `CGGetOnlineDisplayList`
        /// because AppKit only refreshes `NSScreen.screens` on its own reconfiguration pass, so
        /// treating a rename as a restart would tear down a healthy capture on a routine poll.
        func capturesSameContent(as other: StreamTarget) -> Bool {
            guard display.id == other.display.id,
                  interactionDisplay.id == other.interactionDisplay.id,
                  DisplayEntry.rectsMatch(display.bounds, other.display.bounds),
                  DisplayEntry.rectsMatch(
                      interactionDisplay.bounds,
                      other.interactionDisplay.bounds
                  ) else {
                return false
            }
            switch (sourceRect, other.sourceRect) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return DisplayEntry.rectsMatch(lhs, rhs)
            default: return false
            }
        }
    }

    @Published private(set) var displays: [DisplayEntry] = []
    @Published var selectedID: CGDirectDisplayID? {
        didSet {
            if oldValue != selectedID {
                restartStreamForCurrentSelection()
            }
        }
    }
    @Published private(set) var interactionEnabled = false {
        didSet {
            input.interactionEnabled = interactionEnabled
                && interactionDisplay != nil
                && streamState.isLive
            if !interactionEnabled { note = nil }
            guard oldValue != interactionEnabled else { return }
            accessibilityAnnouncement(
                ViewerAccessibility.controlAnnouncement(
                    enabled: interactionEnabled,
                    displayName: interactionDisplay?.name
                )
            )
        }
    }
    @Published private(set) var streamState: ViewerStreamState = .idle
    @Published private(set) var streamError: String?
    @Published private(set) var permissions = PermissionState()
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var note: InputNote?
    @Published private(set) var selectedSessionID: String?
    @Published var searchText = ""
    @Published private(set) var canvasMode: ViewerCanvasMode = .session
    @Published private(set) var viewportZoom: CGFloat = 1
    @Published private(set) var viewportPan: CGPoint = .zero
    @Published var inspectorSection: ViewerInspectorSection = .overview
    @Published private(set) var connectivity: ViewerConnectivityState = .connecting
    @Published private(set) var infrastructure = ViewerInfrastructureSnapshot()
    @Published private(set) var events: [ViewerEvent] = []
    @Published private(set) var daemonError: String?
    @Published private(set) var screenshotResult: ViewerScreenshotResult?

    let input = ViewerInputController()
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let streamEngine: any ViewerDisplayStreaming
    private let discoveryProvider: DiscoveryProvider
    private let daemonTransport: DaemonTransport
    private let permissionPrompt: PermissionPrompt
    private let accessibilityAnnouncement: (String) -> Void
    private var refreshTimer: Timer?
    private var startTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var activeStream: (
        generation: UInt64,
        target: StreamTarget,
        session: any ViewerDisplayStreamSession
    )?
    private(set) var streamGeneration: UInt64 = 0
    private var daemonFailureStartedAt: Date?
    private var daemonProcess: Process?

    /// ScreenCaptureKit owns the sample while its callback is running. The receiving surface
    /// keeps the buffer alive once this immutable reference reaches the main actor.
    private struct FrameDelivery: @unchecked Sendable {
        let sample: CMSampleBuffer
    }

    var streamRunning: Bool { streamState.isLive }
    var selected: DisplayEntry? { displays.first { $0.id == selectedID } }
    var selectedSession: SessionInfo? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }
    var stages: [DisplayEntry] { displays.filter(\.isSpaceO) }
    var physicalDisplays: [DisplayEntry] { displays.filter { !$0.isSpaceO } }
    var attachedSessions: [SessionInfo] {
        sessions
            .filter { $0.runtimeAttached != false }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
    }
    var filteredSessions: [SessionInfo] {
        attachedSessions.filter { ViewerSessionSearch.matches($0, query: searchText) }
    }
    var detachedSessions: [SessionInfo] {
        Self.detachedSessions(from: sessions)
    }

    static func detachedSessions(from sessions: [SessionInfo]) -> [SessionInfo] {
        sessions
            .filter { $0.runtimeAttached == false }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
    }
    var sessionsOnSelectedDisplay: [SessionInfo] {
        guard let selected else { return [] }
        return sessions.filter { session in
            // A daemon-restart record keeps its last placement only for diagnosis. Display ids
            // are recyclable, so even an apparently matching live display must not turn that
            // stale record into an input or rendering overlay.
            let frame = CGRect(
                x: session.x,
                y: session.y,
                width: session.width,
                height: session.height
            )
            return ViewerSessionPresentation.overlayFrame(
                displayID: session.displayID,
                frame: frame,
                runtimeAttached: session.runtimeAttached,
                on: selected
            ) != nil
        }
    }

    private var currentStreamTarget: StreamTarget? {
        guard let selected else { return nil }
        guard canvasMode == .session,
              let session = selectedSession,
              session.runtimeAttached != false,
              session.displayID == selected.id else {
            return StreamTarget(
                display: selected,
                sourceRect: nil,
                interactionDisplay: selected
            )
        }
        let globalFrame = CGRect(
            x: session.x,
            y: session.y,
            width: session.width,
            height: session.height
        )
        guard ViewerSessionPresentation.overlayFrame(
            displayID: session.displayID,
            frame: globalFrame,
            runtimeAttached: session.runtimeAttached,
            on: selected
        ) != nil else {
            return StreamTarget(
                display: selected,
                sourceRect: nil,
                interactionDisplay: selected
            )
        }
        let sourceRect = CGRect(
            x: globalFrame.minX - selected.bounds.minX,
            y: globalFrame.minY - selected.bounds.minY,
            width: globalFrame.width,
            height: globalFrame.height
        )
        return StreamTarget(
            display: selected,
            sourceRect: sourceRect,
            interactionDisplay: DisplayEntry(
                id: selected.id,
                bounds: globalFrame,
                isSpaceO: selected.isSpaceO,
                isActive: selected.isActive,
                name: "Session \(session.id)"
            )
        )
    }

    var interactionDisplay: DisplayEntry? {
        currentStreamTarget?.interactionDisplay
    }

    var healthAlerts: [ViewerHealthAlert] {
        var alerts: [ViewerHealthAlert] = []
        if connectivity == .disconnected {
            alerts.append(ViewerHealthAlert(
                id: "daemon-offline",
                severity: .critical,
                title: "SpaceO daemon is offline",
                detail: daemonError ?? "No control-plane response is available.",
                actionTitle: "Start daemon",
                action: .startDaemon
            ))
        } else if connectivity == .degraded {
            alerts.append(ViewerHealthAlert(
                id: "daemon-degraded",
                severity: .warning,
                title: "Daemon connection is interrupted",
                detail: daemonError ?? "The Viewer will continue retrying.",
                actionTitle: "Retry now",
                action: .refreshDaemon
            ))
        }
        if !permissions.screenRecording {
            alerts.append(ViewerHealthAlert(
                id: "screen-recording",
                severity: .critical,
                title: "Display capture is blocked",
                detail: "Grant Screen Recording permission to view agent sessions.",
                actionTitle: "Open Settings",
                action: .openScreenRecordingSettings
            ))
        }
        if !permissions.accessibility {
            alerts.append(ViewerHealthAlert(
                id: "accessibility",
                severity: .warning,
                title: "Full control is unavailable",
                detail: "Grant Accessibility permission to forward keyboard and pointer input.",
                actionTitle: "Open Settings",
                action: .openAccessibilitySettings
            ))
        }
        if case let .failed(message) = streamState {
            alerts.append(ViewerHealthAlert(
                id: "stream",
                severity: .critical,
                title: "Session stream failed",
                detail: message,
                actionTitle: "Retry stream",
                action: .retryStream
            ))
        }
        for session in sessions where session.runtimeAttached != false {
            let presentation = ViewerSessionPresentation(session: session)
            if presentation.badge == .cleanupPending
                || presentation.badge == .abandoned
                || presentation.badge == .reclaimable {
                alerts.append(ViewerHealthAlert(
                    id: "session-\(session.id)",
                    severity: presentation.badge == .cleanupPending ? .critical : .warning,
                    title: "\(session.id): \(presentation.badge?.title ?? "Needs attention")",
                    detail: presentation.timingText
                        ?? "Review the session ownership and runtime state.",
                    actionTitle: "Inspect",
                    action: .selectSession(session.id)
                ))
            }
        }
        return alerts.sorted { $0.severity > $1.severity }
    }

    func perform(_ action: ViewerHealthAction) {
        switch action {
        case .requestPermissions:
            requestPermissions()
        case .openScreenRecordingSettings:
            openPrivacySettings(pane: "Privacy_ScreenCapture")
        case .openAccessibilitySettings:
            openPrivacySettings(pane: "Privacy_Accessibility")
        case .retryStream:
            retryStream()
        case .refreshDaemon:
            refreshControlPlane()
        case .startDaemon:
            startDaemon()
        case let .selectSession(id):
            selectSession(id)
        }
    }

    init(
        automaticRefresh: Bool = true,
        initialDisplays: [DisplayEntry] = [],
        initialSelectedID: CGDirectDisplayID? = nil,
        initialPermissions: PermissionState = PermissionState(),
        initialStreamRunning: Bool = false,
        streamEngine: any ViewerDisplayStreaming = DisplayStream(),
        discoveryProvider: @escaping DiscoveryProvider = ViewerModel.productionDiscovery,
        daemonTransport: @escaping DaemonTransport = { request in
            try Transport.send(request, to: Wire.socketPath(), timeout: 2)
        },
        permissionPrompt: @escaping PermissionPrompt = ViewerModel.productionPermissionPrompt,
        accessibilityAnnouncement: @escaping (String) -> Void = {
            AccessibilityNotification.Announcement($0).post()
        }
    ) {
        displays = initialDisplays
        selectedID = initialSelectedID
        permissions = initialPermissions
        streamState = initialStreamRunning ? .live : .idle
        self.streamEngine = streamEngine
        self.discoveryProvider = discoveryProvider
        self.daemonTransport = daemonTransport
        self.permissionPrompt = permissionPrompt
        self.accessibilityAnnouncement = accessibilityAnnouncement
        input.onNote = { [weak self] value in
            Task { @MainActor [weak self] in
                self?.note = value
                if let value, value.isWarning {
                    self?.accessibilityAnnouncement(
                        "Viewer input blocked. \(value.text)"
                    )
                }
            }
        }
        input.display = selected
        if automaticRefresh {
            pollDiscovery(restartSelected: false)
            refreshTimer = Timer.scheduledTimer(
                withTimeInterval: 2.0,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.pollDiscovery(restartSelected: false)
                }
            }
        }
    }

    deinit {
        startTask?.cancel()
    }

    // MARK: - Discovery

    /// User-initiated Refresh always restarts the selected stream, even when discovery returns
    /// the same display. The periodic poll uses `restartSelected: false`.
    func refresh() {
        pollDiscovery(restartSelected: true)
    }

    private func pollDiscovery(restartSelected: Bool) {
        let snapshot = discoveryProvider()
        applyDiscovery(
            displays: snapshot.displays,
            permissions: snapshot.permissions,
            restartSelected: restartSelected
        )
        refreshControlPlane()
    }

    func applyDiscovery(
        displays newDisplays: [DisplayEntry],
        permissions newPermissions: PermissionState,
        restartSelected: Bool = false
    ) {
        let previousTarget = currentStreamTarget
        let previousPermissions = permissions

        displays = newDisplays.sorted { left, right in
            if left.isSpaceO != right.isSpaceO { return left.isSpaceO }
            return left.id < right.id
        }
        permissions = newPermissions

        guard let selectedID else { return }
        guard displays.contains(where: { $0.id == selectedID }) else {
            selectedSessionID = nil
            self.selectedID = nil
            return
        }

        // Compare the whole stream target, not just the selected display's geometry. The two
        // must agree: whatever this check calls immaterial keeps streaming, so any field that
        // moves a captured pixel or a routed click has to be represented here.
        let targetChanged: Bool
        switch (previousTarget, currentStreamTarget) {
        case let (previous?, current?): targetChanged = !previous.capturesSameContent(as: current)
        case (nil, nil): targetChanged = false
        default: targetChanged = true
        }
        let capturePermissionChanged =
            previousPermissions.screenRecording != newPermissions.screenRecording

        if restartSelected || targetChanged || capturePermissionChanged {
            restartStreamForCurrentSelection()
            return
        }

        if interactionEnabled && !newPermissions.accessibility {
            interactionEnabled = false
            let warning = "Control disabled because Accessibility permission is unavailable."
            note = InputNote(text: warning, isWarning: true)
            accessibilityAnnouncement(warning)
        }
    }

    private static func productionDiscovery() -> DiscoverySnapshot {
        let spaceO = Set(Stage.spaceODisplayIDs())
        let active = Set(Stage.activeDisplayIDs())
        let displays = Stage.onlineDisplayIDs().map { id in
            DisplayEntry(
                id: id,
                bounds: CGDisplayBounds(id),
                isSpaceO: spaceO.contains(id),
                isActive: active.contains(id),
                name: displayName(for: id, isSpaceO: spaceO.contains(id))
            )
        }
        return (
            displays,
            PermissionState(
                screenRecording: CGPreflightScreenCaptureAccess(),
                accessibility: AXIsProcessTrusted()
            )
        )
    }

    private static func displayName(for id: CGDirectDisplayID, isSpaceO: Bool) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }) {
            return isSpaceO ? "Stage — \(screen.localizedName)" : screen.localizedName
        }
        return isSpaceO ? "SpaceO stage \(id)" : "Display \(id)"
    }

    // MARK: - Viewer control plane

    /// A session and infrastructure read are treated as one Viewer refresh. The daemon's wire
    /// format remains deliberately plain; this typed boundary prevents a missing socket or a
    /// partial response from silently becoming an empty, healthy-looking navigator.
    func refreshControlPlane() {
        let transport = daemonTransport
        Task.detached(priority: .utility) { [weak self] in
            do {
                let sessionsResponse = try transport(Request(cmd: "session.list"))
                guard sessionsResponse.ok else {
                    throw SpaceOError.badRequest(
                        sessionsResponse.error ?? "session.list failed")
                }
                let poolResponse = try transport(Request(cmd: "pool"))
                guard poolResponse.ok else {
                    throw SpaceOError.badRequest(poolResponse.error ?? "pool failed")
                }
                await MainActor.run { [weak self] in
                    self?.applyControlPlane(
                        sessions: sessionsResponse.sessions ?? [],
                        poolResponse: poolResponse
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.applyControlPlaneFailure(error)
                }
            }
        }
    }

    func applyControlPlane(sessions newSessions: [SessionInfo], poolResponse: Response) {
        let oldTarget = currentStreamTarget
        let previousConnectivity = connectivity
        let previousSessionIDs = Set(sessions.map(\.id))
        let previousDensity = infrastructure.configuredDensity

        sessions = newSessions
        infrastructure = ViewerInfrastructureSnapshot(
            displays: poolResponse.displays ?? [],
            usage: poolResponse.usage,
            limits: poolResponse.limits,
            message: poolResponse.message
        )
        daemonError = nil
        daemonFailureStartedAt = nil
        connectivity = .connected

        if previousConnectivity != .connected {
            appendEvent(
                severity: .info,
                title: "Daemon connected",
                detail: "Session and display-pool telemetry are live."
            )
        }

        let currentSessionIDs = Set(newSessions.map(\.id))
        for id in currentSessionIDs.subtracting(previousSessionIDs).sorted() {
            appendEvent(
                severity: .info,
                title: "Session appeared",
                detail: "The daemon attached a new session.",
                sessionID: id
            )
        }
        for id in previousSessionIDs.subtracting(currentSessionIDs).sorted() {
            appendEvent(
                severity: .warning,
                title: "Session ended",
                detail: "The session is no longer attached to this daemon.",
                sessionID: id
            )
        }
        if previousDensity != infrastructure.configuredDensity, !infrastructure.displays.isEmpty {
            appendEvent(
                severity: .info,
                title: "Display density changed",
                detail: "New displays host \(infrastructure.configuredDensity) session(s)."
            )
        }

        if let selectedSessionID,
           !newSessions.contains(where: {
               $0.id == selectedSessionID && $0.runtimeAttached != false
           }) {
            self.selectedSessionID = nil
            interactionEnabled = false
        }
        if selectedSessionID == nil, selectedID == nil, let first = attachedSessions.first {
            selectSession(first.id)
            return
        }
        if oldTarget != currentStreamTarget {
            restartStreamForCurrentSelection()
        }
    }

    func applyControlPlaneFailure(_ error: Error, now: Date = Date()) {
        let previous = connectivity
        let started = daemonFailureStartedAt ?? now
        daemonFailureStartedAt = started
        daemonError = error.localizedDescription
        connectivity = now.timeIntervalSince(started) >= 5 ? .disconnected : .degraded

        if previous != connectivity {
            appendEvent(
                severity: connectivity == .disconnected ? .critical : .warning,
                title: connectivity.title,
                detail: error.localizedDescription
            )
        }
        if connectivity == .disconnected {
            interactionEnabled = false
            selectedSessionID = nil
            sessions = []
            infrastructure = ViewerInfrastructureSnapshot()
        }
    }

    func selectSession(_ id: String) {
        guard let session = sessions.first(where: {
            $0.id == id && $0.runtimeAttached != false
        }) else { return }
        let selectionChanged = selectedSessionID != id || canvasMode != .session
        selectedSessionID = id
        canvasMode = .session
        viewportZoom = 1
        viewportPan = .zero
        inspectorSection = .overview
        if selectedID != session.displayID {
            selectedID = session.displayID
        } else if selectionChanged {
            restartStreamForCurrentSelection()
        }
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        let selectionChanged = selectedID != id || canvasMode != .display
        selectedSessionID = nil
        canvasMode = .display
        viewportZoom = 1
        viewportPan = .zero
        if selectedID != id {
            selectedID = id
        } else if selectionChanged {
            restartStreamForCurrentSelection()
        }
    }

    /// Whether Session/Display scope can be switched right now.
    ///
    /// Session scope needs a session on the selected display to switch *to* — not one already
    /// selected. `setCanvasMode` picks the first one, which is only reachable if the control
    /// that calls it stays enabled after `selectDisplay` clears the session selection.
    var canSwitchCanvasMode: Bool {
        selected != nil && (selectedSession != nil || !sessionsOnSelectedDisplay.isEmpty)
    }

    func setCanvasMode(_ mode: ViewerCanvasMode) {
        guard canvasMode != mode else { return }
        if mode == .session, selectedSession == nil {
            guard let first = sessionsOnSelectedDisplay.first else { return }
            selectSession(first.id)
            return
        }
        canvasMode = mode
        viewportZoom = 1
        viewportPan = .zero
        restartStreamForCurrentSelection()
    }

    func setZoom(_ value: CGFloat) {
        viewportZoom = min(4, max(1, value))
        if viewportZoom == 1 { viewportPan = .zero }
    }

    func pan(by delta: CGPoint) {
        guard viewportZoom > 1 else { return }
        viewportPan = CGPoint(
            x: min(1, max(-1, viewportPan.x + delta.x)),
            y: min(1, max(-1, viewportPan.y + delta.y))
        )
    }

    func startDaemon() {
        guard connectivity != .connected else { return }
        guard let executable = ViewerDaemonExecutable.resolve() else {
            daemonError = "The SpaceO daemon helper is not available in this build."
            appendEvent(
                severity: .critical,
                title: "Daemon could not start",
                detail: daemonError ?? "Helper unavailable"
            )
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshControlPlane() }
        }
        do {
            try process.run()
            daemonProcess = process
            connectivity = .connecting
            appendEvent(
                severity: .info,
                title: "Starting daemon",
                detail: "Waiting for the SpaceO control socket."
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshControlPlane()
            }
        } catch {
            applyControlPlaneFailure(error)
        }
    }

    func stopDaemon() {
        let transport = daemonTransport
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let response = try transport(Request(cmd: "daemon.stop"))
                guard response.ok else {
                    throw SpaceOError.badRequest(response.error ?? "daemon.stop failed")
                }
                await MainActor.run { [weak self] in
                    self?.interactionEnabled = false
                    self?.sessions = []
                    self?.connectivity = .disconnected
                    self?.appendEvent(
                        severity: .warning,
                        title: "Daemon stopped",
                        detail: "All daemon-owned sessions were asked to clean up."
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.applyControlPlaneFailure(error)
                }
            }
        }
    }

    func configureSessionsPerDisplay(_ count: Int) {
        guard count > 0 else { return }
        let transport = daemonTransport
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var request = Request(cmd: "pool.configure")
                request.count = count
                let response = try transport(request)
                guard response.ok else {
                    throw SpaceOError.badRequest(response.error ?? "pool.configure failed")
                }
                await MainActor.run { [weak self] in
                    self?.infrastructure = ViewerInfrastructureSnapshot(
                        displays: response.displays ?? [],
                        usage: response.usage,
                        limits: response.limits,
                        message: response.message
                    )
                    self?.appendEvent(
                        severity: .info,
                        title: "Display density updated",
                        detail: "New displays will host \(count) session(s)."
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.daemonError = error.localizedDescription
                    self?.appendEvent(
                        severity: .warning,
                        title: "Density update failed",
                        detail: error.localizedDescription
                    )
                }
            }
        }
    }

    private func appendEvent(
        severity: ViewerEventSeverity,
        title: String,
        detail: String,
        sessionID: String? = nil
    ) {
        events.insert(
            ViewerEvent(
                timestamp: Date(),
                severity: severity,
                title: title,
                detail: detail,
                sessionID: sessionID
            ),
            at: 0
        )
        if events.count > 100 {
            events.removeLast(events.count - 100)
        }
    }

    // MARK: - Streaming

    func retryStream() {
        restartStreamForCurrentSelection()
    }

    private func restartStreamForCurrentSelection() {
        streamGeneration &+= 1
        let generation = streamGeneration
        let target = currentStreamTarget
        let previousStream = activeStream?.session
        activeStream = nil
        startTask?.cancel()
        startTask = nil
        let precedingTeardown = teardownTask
        let teardown = Task {
            if let precedingTeardown {
                await precedingTeardown.value
            }
            if let previousStream {
                await previousStream.stop()
            }
        }
        teardownTask = teardown

        // One MainActor transition owns both the visible state and the input mapping. Setting
        // Control off releases held keys; assigning display then clears stale drag/key targets
        // and installs the new geometry before any new stream can become live.
        interactionEnabled = false
        input.display = target?.interactionDisplay
        note = nil
        streamError = nil

        guard let target else {
            streamState = .idle
            return
        }

        guard permissions.screenRecording else {
            let message = "Screen Recording permission is required to stream this display."
            streamState = .failed(message)
            streamError = message
            note = InputNote(text: message, isWarning: true)
            accessibilityAnnouncement(message)
            return
        }

        streamState = .starting
        let engine = streamEngine
        startTask = Task { [weak self] in
            await teardown.value
            guard !Task.isCancelled else { return }
            do {
                let session = try await engine.start(
                    displayID: target.display.id,
                    pointSize: target.display.bounds.size,
                    sourceRect: target.sourceRect,
                    onFrame: { [weak self] sample in
                        let delivery = FrameDelivery(sample: sample)
                        Task { @MainActor [weak self] in
                            self?.receiveFrame(delivery.sample, generation: generation)
                        }
                    },
                    onStopped: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleStreamStopped(error, generation: generation)
                        }
                    }
                )
                await self?.completeStart(
                    session,
                    generation: generation,
                    target: target
                )
            } catch is CancellationError {
                // A newer generation owns state now.
            } catch {
                await self?.failStart(error, generation: generation)
            }
        }
    }

    private func completeStart(
        _ session: any ViewerDisplayStreamSession,
        generation: UInt64,
        target: StreamTarget
    ) async {
        guard isCurrent(generation: generation) else {
            await session.stop()
            return
        }
        activeStream = (generation, target, session)
        streamState = .live
        streamError = nil
        startTask = nil
    }

    private func failStart(_ error: Error, generation: UInt64) async {
        guard isCurrent(generation: generation) else { return }
        startTask = nil
        handleStreamStartFailure(error)
    }

    private func receiveFrame(_ sample: CMSampleBuffer, generation: UInt64) {
        guard streamState.isLive,
              activeStream?.generation == generation,
              isCurrent(generation: generation) else { return }
        onFrame?(sample)
    }

    private func handleStreamStopped(_ error: Error?, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }
        let stoppedActiveStream = activeStream?.generation == generation
        guard stoppedActiveStream || streamState == .starting else { return }
        activeStream = nil
        startTask?.cancel()
        startTask = nil
        // If the delegate reports a stop between startCapture returning and model installation,
        // invalidate that completion so it cannot turn this failed generation live again.
        streamGeneration &+= 1
        handleUnexpectedStreamStop(error)
    }

    /// The generation is the only authority over which capture attempt owns viewer state.
    /// `restartStreamForCurrentSelection` is the sole producer of generations and it snapshots
    /// the target at the same instant, so a matching generation already means "this callback
    /// belongs to the stream we most recently asked for".
    ///
    /// Re-deriving the target here and demanding equality would be strictly worse: the target
    /// is computed from the live `DisplayEntry`, which `applyDiscovery` replaces wholesale every
    /// poll. Cosmetic fields — `name` (AppKit refreshes `NSScreen.screens` behind
    /// `CGGetOnlineDisplayList`, so a stage is routinely renamed a poll or two after it appears)
    /// and `isActive` — change without a restart, which would permanently wedge the comparison
    /// and silently drop every frame while `streamState` still claimed `.live`.
    private func isCurrent(generation: UInt64) -> Bool {
        generation == streamGeneration
    }

    func handleUnexpectedStreamStop(_ error: Error?) {
        let detail = error?.localizedDescription ?? "the capture ended unexpectedly"
        transitionToUnavailableStream(
            errorText: "stream stopped: \(detail)",
            warningReason: "the live stream stopped: \(detail)"
        )
    }

    func handleStreamStartFailure(_ error: Error) {
        transitionToUnavailableStream(
            errorText: error.localizedDescription,
            warningReason: "the live stream failed to start: \(error.localizedDescription)"
        )
    }

    private func transitionToUnavailableStream(errorText: String, warningReason: String) {
        let hadControl = interactionEnabled
        interactionEnabled = false
        streamState = .failed(errorText)
        streamError = errorText
        let prefix = hadControl ? "Control disabled because " : "Control unavailable because "
        let warning = prefix + warningReason + "."
        note = InputNote(text: warning, isWarning: true)
        accessibilityAnnouncement(warning)
    }

    // MARK: - Screenshot

    func saveScreenshot() {
        guard let target = currentStreamTarget else { return }
        let entry = target.display
        Task {
            do {
                let image = try await Self.snapshot(
                    of: entry,
                    sourceRect: target.sourceRect
                )
                let panel = NSSavePanel()
                panel.nameFieldStringValue = selectedSessionID.map {
                    "spaceo-session-\($0).png"
                } ?? "spaceo-display-\(entry.id).png"
                panel.allowedContentTypes = [.png]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Capture.pngData(image).write(to: url)
                report(.saved(url))
            } catch {
                report(.failed(error.localizedDescription))
            }
        }
    }

    /// Surface the outcome where the user is looking.
    ///
    /// A screenshot that reported failure only through `streamError` — which no view reads —
    /// meant pressing the toolbar button produced no file, no error, and no clue why.
    private func report(_ result: ViewerScreenshotResult) {
        screenshotResult = result
        note = InputNote(text: result.message, isWarning: result.isFailure)
        accessibilityAnnouncement(result.message)
        appendEvent(
            severity: result.isFailure ? .warning : .info,
            title: result.isFailure ? "Screenshot failed" : "Screenshot saved",
            detail: result.message)
    }

    func revealScreenshot() {
        guard case let .saved(url) = screenshotResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearScreenshotResult() {
        screenshotResult = nil
    }

    private static func snapshot(
        of entry: DisplayEntry,
        sourceRect: CGRect?
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == entry.id }) else {
            throw SpaceOError.captureFailed("display \(entry.id) is not shareable")
        }
        let config = SCStreamConfiguration()
        let dimensions = DisplayStream.frameDimensions(
            pixelWidth: display.width,
            pixelHeight: display.height,
            fallbackPointSize: entry.bounds.size,
            sourceRect: sourceRect
        )
        config.width = dimensions.width
        config.height = dimensions.height
        if let sourceRect {
            config.sourceRect = sourceRect
        }
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    // MARK: - Permissions and Control

    func setInteractionEnabled(_ enabled: Bool) {
        switch ViewerControlPolicy.controlRequest(
            enabling: enabled,
            hasSelectedDisplay: selected != nil,
            streamRunning: streamState.isLive,
            screenRecordingGranted: permissions.screenRecording,
            accessibilityGranted: permissions.accessibility
        ) {
        case .enable:
            interactionEnabled = true
        case .disable:
            interactionEnabled = false
        case let .blocked(message):
            interactionEnabled = false
            note = InputNote(text: message, isWarning: true)
            accessibilityAnnouncement(message)
        }
    }

    /// Raise the system permission prompts for whatever is still missing.
    ///
    /// macOS only ever shows these once per app identity, and it will not show them at all unless
    /// something asks. Because `restartStreamForCurrentSelection` refuses to touch
    /// ScreenCaptureKit without a pre-flight grant, nothing else in the Viewer can trigger the
    /// capture prompt implicitly either — so with no caller here a first-run user was left to
    /// find System Settings and add the app by hand.
    nonisolated(unsafe) static let productionPermissionPrompt: PermissionPrompt = { permissions in
        if !permissions.screenRecording {
            CGRequestScreenCaptureAccess()
        }
        if !permissions.accessibility {
            // Use the documented option value without referencing the SDK's imported mutable
            // global, which is not concurrency-safe under Swift 6 strict checking.
            let options = ["AXTrustedCheckOptionPrompt": true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    func requestPermissions() {
        permissionPrompt(permissions)
        // The prompt is answered out of process, so re-poll rather than assuming the grant
        // landed, and restart the selection so a newly granted capture permission produces a
        // live stream without the user relaunching the app.
        pollDiscovery(restartSelected: true)
    }

    func openPrivacySettings(pane: String) {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        if let url = URL(string: base + pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
