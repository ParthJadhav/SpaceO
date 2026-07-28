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
            if let error = model.streamError {
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
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .strokeBorder(.cyan.opacity(0.6), lineWidth: 1)
                    Text(session.id)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 4)
                        .background(.cyan.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black)
                        .padding(2)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            }
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
            Circle()
                .fill(model.streamRunning ? .green : .red)
                .frame(width: 8, height: 8)
            Text(model.streamRunning ? "live" : "no stream")
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
            } else if !model.streamRunning {
                Text("control unavailable — waiting for live stream")
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

    private func statusAccessibilityValue(for entry: DisplayEntry) -> String {
        var parts = [
            ViewerAccessibility.surfaceValue(
                streamRunning: model.streamRunning,
                controlEnabled: model.interactionEnabled
            ),
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
                          + "Relaunch the viewer after granting.",
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
            .disabled(model.selected == nil || !model.streamRunning)
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
            .help("Re-scan displays and sessions")
        }
    }

    private var controlHelp: String {
        guard model.selected != nil else {
            return "Select a display before turning on Control."
        }
        guard model.streamRunning else {
            return "Control is unavailable until the selected display has a live stream."
        }
        return "Forward your mouse and keyboard to this display. "
            + "\(ViewerControlPolicy.localExitDescription) always exits locally."
    }
}
