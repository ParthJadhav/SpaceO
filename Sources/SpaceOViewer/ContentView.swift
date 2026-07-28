import SpaceOKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ViewerModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedID) {
            Section("Agent displays") {
                if model.stages.isEmpty {
                    Text("No agent displays are attached.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.stages, content: displayRow)
                }
            }
            Section("Physical displays") {
                ForEach(model.physicalDisplays, content: displayRow)
            }
        }
        .listStyle(.sidebar)
    }

    private func displayRow(_ entry: DisplayEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: entry.isSpaceO ? "display.2" : "display")
                Text(entry.name)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(Int(entry.bounds.width))×\(Int(entry.bounds.height))")
                if !entry.isActive {
                    Text("inactive")
                        .padding(.horizontal, 4)
                        .background(.orange.opacity(0.25), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(entry.id)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if !model.permissions.screenRecording || !model.permissions.accessibility {
                permissionBanner
            }
            if case let .failed(error) = model.streamState {
                streamFailureBanner(error)
            } else if let error = model.streamError {
                banner(text: error, color: .red)
            }
            if let selected = model.selected {
                console(for: selected)
                statusBar(for: selected)
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func console(for entry: DisplayEntry) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                StreamSurface()
                sessionOverlay(for: entry, in: geometry.size)
                if model.streamState == .starting {
                    ProgressView("Starting display stream…")
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Starting display stream")
                }
            }
        }
    }

    /// Session tiles from the daemon, projected through the same aspect-fit mapping the
    /// renderer uses, so the outlines sit exactly on the tiles they describe.
    @ViewBuilder
    private func sessionOverlay(for entry: DisplayEntry, in size: CGSize) -> some View {
        let mapping = MirrorInput.ViewportMapping(displayBounds: entry.bounds, viewSize: size)
        ForEach(model.sessionsOnSelectedDisplay, id: \.id) { session in
            let frame = CGRect(x: session.x, y: session.y,
                               width: session.width, height: session.height)
            if let rect = mapping.viewRect(fromGlobalRect: frame) {
                let presentation = ViewerSessionPresentation(session: session)
                let color = sessionColor(for: presentation.badge)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(color.opacity(0.75), lineWidth: 1)
                        .accessibilityHidden(true)
                    sessionLabel(
                        id: session.id,
                        presentation: presentation,
                        color: color
                    )
                    .padding(4)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    presentation.accessibilityDescription(sessionID: session.id)
                )
            }
        }
    }

    private func sessionLabel(
        id: String,
        presentation: ViewerSessionPresentation,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(id)
                    .font(.caption2.monospaced().weight(.semibold))
                    .lineLimit(1)
                if let badge = presentation.badge {
                    sessionBadge(badge, color: color)
                }
            }
            if let ownerText = presentation.ownerText {
                Label(ownerText, systemImage: "person.crop.circle")
                    .lineLimit(1)
            }
            if let timingText = presentation.timingText {
                Text(timingText)
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.45), lineWidth: 0.5)
        }
    }

    private func sessionBadge(_ badge: ViewerSessionBadge, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: badge.systemImage)
                .foregroundStyle(color)
            Text(badge.title)
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule())
        .overlay {
            Capsule()
                .stroke(color.opacity(0.45), lineWidth: 0.5)
        }
        .fixedSize()
    }

    private func sessionColor(for badge: ViewerSessionBadge?) -> Color {
        switch badge {
        case .owned: .blue
        case .abandoned: .orange
        case .reclaimable: .green
        case .cleanupPending: .red
        case nil: .cyan
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Select a display",
                systemImage: "display.2",
                description: Text(emptyStateDetail))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateDetail: String {
        if model.stages.isEmpty {
            return "No SpaceO virtual displays are attached. Agent displays appear here when "
                + "a SpaceO daemon creates sessions. Physical displays remain available below."
        }
        return "Pick an agent display in the sidebar to watch it, then turn on Control "
            + "to drive it like a VM."
    }

    // MARK: - Status and banners

    private func statusBar(for entry: DisplayEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: streamStatusSymbol)
                .foregroundStyle(streamStatusColor)
            Text(model.streamState.statusText)
                .foregroundStyle(.secondary)
            if let note = model.note {
                Text(note.text)
                    .foregroundStyle(note.isWarning ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.interactionEnabled {
                Text("control enabled — \(ViewerControlPolicy.localExitDescription) exits")
                    .foregroundStyle(.secondary)
            } else if !model.streamState.isLive {
                Text(controlUnavailableStatus)
                    .foregroundStyle(.secondary)
            } else {
                Text("viewing only — turn on Control to drive")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Viewer status")
        .accessibilityValue(statusAccessibilityValue(for: entry))
    }

    private var streamStatusSymbol: String {
        switch model.streamState {
        case .idle: "pause.circle"
        case .starting: "clock.arrow.circlepath"
        case .live: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var streamStatusColor: Color {
        switch model.streamState {
        case .idle: .secondary
        case .starting: .blue
        case .live: .green
        case .failed: .red
        }
    }

    private var controlUnavailableStatus: String {
        switch model.streamState {
        case .idle: "control unavailable — no stream selected"
        case .starting: "control unavailable — stream starting"
        case .failed: "control unavailable — stream failed"
        case .live: "viewing only — turn on Control to drive"
        }
    }

    private func statusAccessibilityValue(for entry: DisplayEntry) -> String {
        var parts = [
            ViewerAccessibility.surfaceValue(
                streamRunning: model.streamRunning,
                controlEnabled: model.interactionEnabled
            ),
            "Stream status: \(model.streamState.statusText).",
            "Selected display: \(entry.name)."
        ]
        if model.interactionEnabled {
            parts.append(
                "Press \(ViewerControlPolicy.localExitDescription) to exit Control."
            )
        } else if !model.streamRunning {
            parts.append("Control is unavailable until the display has a live stream.")
        }
        if let note = model.note {
            parts.append(note.isWarning ? "Warning: \(note.text)" : note.text)
        }
        return parts.joined(separator: " ")
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.permissions.screenRecording {
                HStack {
                    Label("Screen Recording permission is needed to view displays. "
                          + "The viewer retries automatically after granting.",
                          systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Open Settings") {
                        model.openPrivacySettings(pane: "Privacy_ScreenCapture")
                    }
                }
            }
            if !model.permissions.accessibility {
                HStack {
                    Label("Accessibility permission is needed to send input to the stage.",
                          systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Request") { model.requestPermissions() }
                    Button("Open Settings") {
                        model.openPrivacySettings(pane: "Privacy_Accessibility")
                    }
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.15))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewer permissions")
    }

    private func banner(text: String, color: Color) -> some View {
        HStack {
            Label(text, systemImage: "xmark.octagon.fill")
                .lineLimit(3)
            Spacer()
        }
        .font(.callout)
        .padding(10)
        .background(color.opacity(0.15))
    }

    private func streamFailureBanner(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "xmark.octagon.fill")
                .lineLimit(3)
            Spacer()
            Button("Retry") { model.retryStream() }
                .disabled(model.selected == nil || !model.permissions.screenRecording)
        }
        .font(.callout)
        .padding(10)
        .background(.red.opacity(0.15))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display stream failed")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: Binding(
                get: { model.interactionEnabled },
                set: { model.setInteractionEnabled($0) }
            )) {
                Label("Control", systemImage: "keyboard")
            }
            .toggleStyle(.button)
            .disabled(
                model.selected == nil
                    || !model.streamState.isLive
                    || !model.permissions.screenRecording
                    || !model.permissions.accessibility
            )
            .help(controlHelp)

            Button {
                model.saveScreenshot()
            } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .disabled(model.selected == nil)
            .help("Save a PNG of this display")

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-scan displays and restart the selected display stream")
        }
    }

    private var controlHelp: String {
        guard model.selected != nil else {
            return "Select a display before turning on Control."
        }
        guard model.streamState.isLive else {
            return "Control is unavailable while the selected display stream is "
                + "\(model.streamState.statusText)."
        }
        guard model.permissions.screenRecording else {
            return "Grant Screen Recording permission before turning on Control."
        }
        guard model.permissions.accessibility else {
            return "Grant Accessibility permission before turning on Control."
        }
        return "Forward your mouse and keyboard to this display. "
            + "\(ViewerControlPolicy.localExitDescription) always exits locally."
    }
}
