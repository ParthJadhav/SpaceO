import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import SpaceOKit
import SwiftUI

struct DisplayEntry: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let isSpaceO: Bool
    let isActive: Bool
    let name: String
}

struct PermissionState: Equatable {
    var screenRecording = false
    var accessibility = false
}

@MainActor
final class ViewerModel: ObservableObject {

    @Published private(set) var displays: [DisplayEntry] = []
    @Published var selectedID: CGDirectDisplayID? {
        didSet { if oldValue != selectedID { restartStream() } }
    }
    @Published var interactionEnabled = false {
        didSet {
            input.interactionEnabled = interactionEnabled && selected != nil
            if !interactionEnabled { note = nil }
        }
    }
    @Published private(set) var streamRunning = false
    @Published private(set) var streamError: String?
    @Published private(set) var permissions = PermissionState()
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var note: InputNote?

    let stream = DisplayStream()
    let input = ViewerInputController()

    private var refreshTimer: Timer?
    private var streamGeneration = 0

    var selected: DisplayEntry? { displays.first { $0.id == selectedID } }
    var stages: [DisplayEntry] { displays.filter(\.isSpaceO) }
    var physicalDisplays: [DisplayEntry] { displays.filter { !$0.isSpaceO } }
    var sessionsOnSelectedDisplay: [SessionInfo] {
        guard let selectedID else { return [] }
        return sessions.filter { $0.displayID == selectedID }
    }

    init() {
        stream.onStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.streamRunning = false
                if let error {
                    self?.streamError = "stream stopped: \(error.localizedDescription)"
                }
            }
        }
        input.onNote = { [weak self] value in
            Task { @MainActor [weak self] in self?.note = value }
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Discovery

    func refresh() {
        let spaceo = Set(Stage.spaceODisplayIDs())
        let active = Set(Stage.activeDisplayIDs())
        let online = Stage.onlineDisplayIDs()
        displays = online.map { id in
            DisplayEntry(id: id,
                         bounds: CGDisplayBounds(id),
                         isSpaceO: spaceo.contains(id),
                         isActive: active.contains(id),
                         name: Self.displayName(for: id, isSpaceO: spaceo.contains(id)))
        }
        .sorted { left, right in
            if left.isSpaceO != right.isSpaceO { return left.isSpaceO }
            return left.id < right.id
        }
        if let selectedID, !online.contains(selectedID) {
            self.selectedID = nil
        }
        permissions = PermissionState(screenRecording: CGPreflightScreenCaptureAccess(),
                                      accessibility: AXIsProcessTrusted())
        refreshSessions()
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
               let response = try? Transport.send(Request(cmd: "session.list"),
                                                  to: path, timeout: 2),
               response.ok {
                found = response.sessions ?? []
            }
            let sessions = found
            await MainActor.run { [weak self] in self?.sessions = sessions }
        }
    }

    // MARK: - Streaming

    private func restartStream() {
        streamError = nil
        note = nil
        interactionEnabled = false
        input.display = selected
        streamGeneration += 1
        let generation = streamGeneration
        let target = selected
        Task {
            await stream.stop()
            guard generation == streamGeneration else { return }
            await MainActor.run { self.streamRunning = false }
            guard let target else { return }
            do {
                try await stream.start(displayID: target.id, pointSize: target.bounds.size)
                guard generation == streamGeneration else { return }
                await MainActor.run { self.streamRunning = true }
            } catch {
                guard generation == streamGeneration else { return }
                await MainActor.run { self.streamError = error.localizedDescription }
            }
        }
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
            fallbackPointSize: entry.bounds.size)
        config.width = dimensions.width
        config.height = dimensions.height
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }

    // MARK: - Permissions

    func requestPermissions() {
        if !permissions.screenRecording {
            CGRequestScreenCaptureAccess()
        }
        if !permissions.accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
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
