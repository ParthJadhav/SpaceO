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

    func hasMaterialGeometryChange(from other: DisplayEntry,
                                   tolerance: CGFloat = 0.5) -> Bool {
        guard id == other.id else { return true }
        let values = [
            abs(bounds.minX - other.bounds.minX),
            abs(bounds.minY - other.bounds.minY),
            abs(bounds.width - other.bounds.width),
            abs(bounds.height - other.bounds.height),
        ]
        return values.contains { !$0.isFinite || $0 >= tolerance }
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
                && selected != nil
                && streamState.isLive
            if !interactionEnabled { note = nil }
            guard oldValue != interactionEnabled else { return }
            accessibilityAnnouncement(
                ViewerAccessibility.controlAnnouncement(
                    enabled: interactionEnabled,
                    displayName: selected?.name
                )
            )
        }
    }
    @Published private(set) var streamState: ViewerStreamState = .idle
    @Published private(set) var streamError: String?
    @Published private(set) var permissions = PermissionState()
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var note: InputNote?

    let input = ViewerInputController()
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let streamEngine: any ViewerDisplayStreaming
    private let discoveryProvider: DiscoveryProvider
    private let accessibilityAnnouncement: (String) -> Void
    private var refreshTimer: Timer?
    private var startTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var activeStream: (
        generation: UInt64,
        target: DisplayEntry,
        session: any ViewerDisplayStreamSession
    )?
    private(set) var streamGeneration: UInt64 = 0

    /// ScreenCaptureKit owns the sample while its callback is running. The receiving surface
    /// keeps the buffer alive once this immutable reference reaches the main actor.
    private struct FrameDelivery: @unchecked Sendable {
        let sample: CMSampleBuffer
    }

    var streamRunning: Bool { streamState.isLive }
    var selected: DisplayEntry? { displays.first { $0.id == selectedID } }
    var stages: [DisplayEntry] { displays.filter(\.isSpaceO) }
    var physicalDisplays: [DisplayEntry] { displays.filter { !$0.isSpaceO } }
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

    init(
        automaticRefresh: Bool = true,
        initialDisplays: [DisplayEntry] = [],
        initialSelectedID: CGDirectDisplayID? = nil,
        initialPermissions: PermissionState = PermissionState(),
        initialStreamRunning: Bool = false,
        streamEngine: any ViewerDisplayStreaming = DisplayStream(),
        discoveryProvider: @escaping DiscoveryProvider = ViewerModel.productionDiscovery,
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
        refreshSessions()
    }

    func applyDiscovery(
        displays newDisplays: [DisplayEntry],
        permissions newPermissions: PermissionState,
        restartSelected: Bool = false
    ) {
        let previousSelected = selected
        let previousPermissions = permissions

        displays = newDisplays.sorted { left, right in
            if left.isSpaceO != right.isSpaceO { return left.isSpaceO }
            return left.id < right.id
        }
        permissions = newPermissions

        guard let selectedID else { return }
        guard let updatedSelected = displays.first(where: { $0.id == selectedID }) else {
            self.selectedID = nil
            return
        }

        let geometryChanged = previousSelected.map {
            updatedSelected.hasMaterialGeometryChange(from: $0)
        } ?? true
        let capturePermissionChanged =
            previousPermissions.screenRecording != newPermissions.screenRecording

        if restartSelected || geometryChanged || capturePermissionChanged {
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

    /// Session tiles come from the daemon when one is running; the viewer degrades to a plain
    /// display view when there is none to ask.
    private func refreshSessions() {
        Task.detached(priority: .utility) { [weak self] in
            let path = Wire.socketPath()
            var found: [SessionInfo] = []
            if FileManager.default.fileExists(atPath: path),
               let response = try? Transport.send(
                   Request(cmd: "session.list"),
                   to: path,
                   timeout: 2
               ),
               response.ok {
                found = response.sessions ?? []
            }
            let sessions = found
            await MainActor.run { [weak self] in self?.sessions = sessions }
        }
    }

    // MARK: - Streaming

    func retryStream() {
        restartStreamForCurrentSelection()
    }

    private func restartStreamForCurrentSelection() {
        streamGeneration &+= 1
        let generation = streamGeneration
        let target = selected
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
        input.display = target
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
                    displayID: target.id,
                    pointSize: target.bounds.size,
                    onFrame: { [weak self] sample in
                        let delivery = FrameDelivery(sample: sample)
                        Task { @MainActor [weak self] in
                            self?.receiveFrame(
                                delivery.sample,
                                generation: generation,
                                target: target
                            )
                        }
                    },
                    onStopped: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleStreamStopped(
                                error,
                                generation: generation,
                                target: target
                            )
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
                await self?.failStart(error, generation: generation, target: target)
            }
        }
    }

    private func completeStart(
        _ session: any ViewerDisplayStreamSession,
        generation: UInt64,
        target: DisplayEntry
    ) async {
        guard isCurrent(generation: generation, target: target) else {
            await session.stop()
            return
        }
        activeStream = (generation, target, session)
        streamState = .live
        streamError = nil
        startTask = nil
    }

    private func failStart(_ error: Error,
                           generation: UInt64,
                           target: DisplayEntry) async {
        guard isCurrent(generation: generation, target: target) else { return }
        startTask = nil
        handleStreamStartFailure(error)
    }

    private func receiveFrame(_ sample: CMSampleBuffer,
                              generation: UInt64,
                              target: DisplayEntry) {
        guard streamState.isLive,
              activeStream?.generation == generation,
              isCurrent(generation: generation, target: target) else { return }
        onFrame?(sample)
    }

    private func handleStreamStopped(_ error: Error?,
                                     generation: UInt64,
                                     target: DisplayEntry) {
        guard isCurrent(generation: generation, target: target) else { return }
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

    private func isCurrent(generation: UInt64, target: DisplayEntry) -> Bool {
        guard generation == streamGeneration, let selected else { return false }
        return selected.id == target.id
            && !selected.hasMaterialGeometryChange(from: target)
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
        guard let entry = selected else { return }
        Task {
            do {
                let image = try await Self.snapshot(of: entry)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "spaceo-display-\(entry.id).png"
                panel.allowedContentTypes = [.png]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Capture.pngData(image).write(to: url)
            } catch {
                streamError = "screenshot failed: \(error.localizedDescription)"
            }
        }
    }

    private static func snapshot(of entry: DisplayEntry) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == entry.id }) else {
            throw SpaceOError.captureFailed("display \(entry.id) is not shareable")
        }
        let config = SCStreamConfiguration()
        let dimensions = DisplayStream.frameDimensions(
            pixelWidth: display.width,
            pixelHeight: display.height,
            fallbackPointSize: entry.bounds.size
        )
        config.width = dimensions.width
        config.height = dimensions.height
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

    func requestPermissions() {
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

    func openPrivacySettings(pane: String) {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        if let url = URL(string: base + pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
