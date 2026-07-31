import SpaceOKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ViewerModel
    @State private var requestedDensity = 1
    @State private var confirmsDaemonStop = false

    var body: some View {
        NavigationSplitView {
            navigator
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 340)
        } content: {
            workspace
                .navigationSplitViewColumnWidth(min: 560, ideal: 820)
        } detail: {
            inspector
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 420)
        }
        .toolbar { toolbar }
        .onChange(of: model.infrastructure.configuredDensity) {
            requestedDensity = model.infrastructure.configuredDensity
        }
        .confirmationDialog(
            "Stop the SpaceO daemon?",
            isPresented: $confirmsDaemonStop,
            titleVisibility: .visible
        ) {
            Button("Stop Daemon and Clean Up Sessions", role: .destructive) {
                model.stopDaemon()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The daemon will quit its owned apps and remove its virtual displays. "
                 + "This does not quit the Viewer.")
        }
    }

    // MARK: - Navigator

    private var navigator: some View {
        List {
            Section {
                if model.filteredSessions.isEmpty {
                    navigatorEmptyState
                } else {
                    ForEach(model.filteredSessions, id: \.id) { session in
                        sessionRow(session)
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Text("\(model.attachedSessions.count)")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Displays") {
                ForEach(model.stages) { display in
                    displayRow(display)
                }
                if !model.physicalDisplays.isEmpty {
                    DisclosureGroup("Physical displays") {
                        ForEach(model.physicalDisplays) { display in
                            displayRow(display)
                        }
                    }
                }
            }

            if !model.detachedSessions.isEmpty {
                Section("Recovery") {
                    ForEach(model.detachedSessions, id: \.id) { session in
                        recoveryRow(session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Sessions, apps, windows")
        .navigationTitle("SpaceO")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            navigatorFooter
        }
    }

    private var navigatorEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                model.searchText.isEmpty ? "No active sessions" : "No matching sessions",
                systemImage: model.searchText.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass"
            )
            .font(.callout.weight(.medium))
            Text(model.searchText.isEmpty
                 ? "Sessions appear automatically when agents connect."
                 : "Search checks session IDs, owners, apps, and window titles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        let presentation = ViewerSessionPresentation(session: session)
        let selected = model.selectedSessionID == session.id && model.canvasMode == .session
        return Button {
            model.selectSession(session.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "rectangle.inset.filled")
                    .foregroundStyle(selected ? Color.accentColor : sessionColor(presentation.badge))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.id)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let badge = presentation.badge {
                            Image(systemName: badge.systemImage)
                                .foregroundStyle(sessionColor(badge))
                                .help(badge.title)
                        }
                    }
                    Text(sessionSummary(session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let owner = presentation.ownerText {
                        Text(owner)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityLabel(presentation.accessibilityDescription(sessionID: session.id))
    }

    private func displayRow(_ display: DisplayEntry) -> some View {
        let selected = model.selectedID == display.id && model.canvasMode == .display
        return Button {
            model.selectDisplay(display.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: display.isSpaceO ? "display.2" : "display")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .lineLimit(1)
                    Text("\(Int(display.bounds.width)) × \(Int(display.bounds.height))"
                         + (display.isActive ? "" : " · inactive"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func recoveryRow(_ session: SessionInfo) -> some View {
        let presentation = ViewerSessionPresentation(session: session)
        return VStack(alignment: .leading, spacing: 3) {
            Label(session.id, systemImage: "wrench.and.screwdriver")
                .font(.callout.weight(.medium))
            Text(presentation.timingText ?? "Detached from a prior daemon")
                .foregroundStyle(.secondary)
            ForEach(Array((session.recoveryBlockers ?? []).prefix(2).enumerated()), id: \.offset) {
                Text($0.element.message)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.vertical, 3)
    }

    private var navigatorFooter: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectivityColor)
                .frame(width: 7, height: 7)
            Text(model.connectivity.title)
                .lineLimit(1)
            Spacer()
            if !model.healthAlerts.isEmpty {
                Label("\(model.healthAlerts.count)", systemImage: "cross.case.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    // MARK: - Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            if !model.permissions.screenRecording || !model.permissions.accessibility {
                permissionBanner
            }
            if case let .failed(error) = model.streamState {
                streamFailureBanner(error)
            }
            if let result = model.screenshotResult {
                screenshotBanner(result)
            }
            if model.currentSelectionTitle != nil {
                consoleHeader
                console
                statusBar
            } else {
                emptyWorkspace
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var consoleHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSelectionTitle ?? "Viewer")
                    .font(.headline)
                Text(selectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.canvasMode == .session {
                Label("Session focus", systemImage: "viewfinder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var console: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                StreamSurface()
                if model.canvasMode == .display, let display = model.selected {
                    sessionOverlay(for: display, in: geometry.size)
                }
                if model.streamState == .starting {
                    ProgressView("Starting secure display stream…")
                        .controlSize(.large)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                }
                if model.interactionEnabled {
                    capturedBoundary
                } else if model.streamState.isLive {
                    captureInvitation
                }
                if model.viewportZoom > 1, !model.interactionEnabled {
                    VStack {
                        Spacer()
                        Text("Scroll over the canvas to pan")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
            }
            .clipped()
        }
    }

    private var capturedBoundary: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .allowsHitTesting(false)
            Text("Input captured  ·  \(ViewerControlPolicy.localExitDescription) to release")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: UnevenRoundedRectangle(
                    bottomLeadingRadius: 7,
                    bottomTrailingRadius: 7
                ))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input captured")
        .accessibilityValue(
            "\(ViewerControlPolicy.localExitDescription) releases input to this Mac."
        )
    }

    private var captureInvitation: some View {
        VStack {
            Spacer()
            Button {
                model.setInteractionEnabled(true)
            } label: {
                Label("Click to capture keyboard and pointer", systemImage: "cursorarrow.motionlines")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func sessionOverlay(for display: DisplayEntry, in size: CGSize) -> some View {
        let mapping = MirrorInput.ViewportMapping(
            displayBounds: display.bounds,
            viewSize: size,
            zoom: model.viewportZoom,
            pan: model.viewportPan
        )
        ForEach(model.sessionsOnSelectedDisplay, id: \.id) { session in
            let frame = CGRect(
                x: session.x,
                y: session.y,
                width: session.width,
                height: session.height
            )
            if let rect = mapping.viewRect(fromGlobalRect: frame) {
                let presentation = ViewerSessionPresentation(session: session)
                Button {
                    model.selectSession(session.id)
                } label: {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .strokeBorder(sessionColor(presentation.badge).opacity(0.8), lineWidth: 1)
                        Text(session.id)
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                            .padding(5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .accessibilityLabel(
                    presentation.accessibilityDescription(sessionID: session.id)
                )
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: streamStatusSymbol)
                .foregroundStyle(streamStatusColor)
            Text(model.streamState.statusText.capitalized)
            if let note = model.note {
                Divider().frame(height: 12)
                Text(note.text)
                    .foregroundStyle(note.isWarning ? .orange : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.interactionEnabled {
                Text("Human and agent can work concurrently")
            } else {
                Text(model.canvasMode == .session ? "Tile-scoped stream" : "Whole display stream")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label(
                model.connectivity == .disconnected ? "Daemon offline" : "Choose a session",
                systemImage: model.connectivity == .disconnected ? "server.rack" : "rectangle.stack"
            )
        } description: {
            Text(model.connectivity == .disconnected
                 ? "Start the daemon to discover agent sessions and virtual displays."
                 : "Select a session to inspect and control its workspace.")
        } actions: {
            if model.connectivity == .disconnected {
                Button("Start Daemon") { model.startDaemon() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Refresh") { model.refresh() }
            }
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            inspectorBody
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Inspector")
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.inspectorSection.title, systemImage: model.inspectorSection.systemImage)
                    .font(.headline)
                Spacer()
                Menu {
                    Picker("Inspector", selection: $model.inspectorSection) {
                        ForEach(ViewerInspectorSection.allCases) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let session = model.selectedSession {
                Text(session.id)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(session.apps.count) app\(session.apps.count == 1 ? "" : "s") · "
                     + "\(session.windows.count) window\(session.windows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let display = model.selected {
                Text(display.name)
                    .font(.title3.weight(.semibold))
            } else {
                Text("Nothing selected")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var inspectorBody: some View {
        switch model.inspectorSection {
        case .overview:
            overviewInspector
        case .apps:
            appsInspector
        case .windows:
            windowsInspector
        case .health:
            healthInspector
        case .infrastructure:
            infrastructureInspector
        case .events:
            eventsInspector
        }
    }

    private var overviewInspector: some View {
        List {
            if let session = model.selectedSession {
                let presentation = ViewerSessionPresentation(session: session)
                Section("Identity") {
                    inspectorValue("Session", session.id)
                    inspectorValue("Display", "\(session.displayID)")
                    inspectorValue("Tile", "\(session.tileIndex + 1) of \(session.tileCapacity)")
                    inspectorValue("Scope", session.exclusiveDisplay ? "Exclusive display" : "Shared display")
                }
                Section("Ownership") {
                    inspectorValue("State", presentation.badge?.title ?? "Active")
                    inspectorValue("Owner", presentation.ownerText ?? "Legacy daemon")
                    if let timing = presentation.timingText {
                        inspectorValue("Activity", timing)
                    }
                }
                Section("Geometry") {
                    inspectorValue(
                        "Frame",
                        "\(Int(session.width)) × \(Int(session.height)) at "
                            + "\(Int(session.x)), \(Int(session.y))"
                    )
                    inspectorValue("Spaces", session.spaces.isEmpty
                                   ? "Unavailable"
                                   : session.spaces.map(String.init).joined(separator: ", "))
                }
            } else if let display = model.selected {
                Section("Display") {
                    inspectorValue("Name", display.name)
                    inspectorValue("ID", "\(display.id)")
                    inspectorValue("Kind", display.isSpaceO ? "SpaceO virtual display" : "Physical display")
                    inspectorValue("State", display.isActive ? "Active" : "Inactive")
                    inspectorValue("Resolution", "\(Int(display.bounds.width)) × \(Int(display.bounds.height))")
                }
            } else {
                Text("Select a session or display to inspect it.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private var appsInspector: some View {
        List {
            if let session = model.selectedSession, !session.apps.isEmpty {
                ForEach(session.apps, id: \.pid) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(app.name, systemImage: "app")
                            .font(.body.weight(.medium))
                        Text("PID \(app.pid)"
                             + (app.startedByUs ? " · launched by SpaceO" : " · adopted"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let bundleID = app.bundleID {
                            Text(bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                inspectorEmpty("No apps reported", systemImage: "app.dashed")
            }
        }
        .listStyle(.inset)
    }

    private var windowsInspector: some View {
        List {
            if let session = model.selectedSession, !session.windows.isEmpty {
                ForEach(session.windows, id: \.windowID) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(window.title.isEmpty ? "Untitled window" : window.title,
                                  systemImage: "macwindow")
                                .font(.body.weight(.medium))
                            Spacer()
                            if !window.onStage {
                                Text("Off stage")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("Window \(window.windowID) · PID \(window.pid)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("\(Int(window.width)) × \(Int(window.height)) at "
                             + "\(Int(window.x)), \(Int(window.y))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            } else {
                inspectorEmpty("No windows reported", systemImage: "macwindow.on.rectangle")
            }
        }
        .listStyle(.inset)
    }

    private var healthInspector: some View {
        List {
            if model.healthAlerts.isEmpty {
                Section {
                    Label("Viewer, daemon, sessions, and permissions look healthy.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.vertical, 4)
                } header: {
                    Text("All systems operational")
                }
            } else {
                ForEach(model.healthAlerts) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(alert.title, systemImage: severitySymbol(alert.severity))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(severityColor(alert.severity))
                        Text(alert.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let title = alert.actionTitle, let action = alert.action {
                            Button(title) { model.perform(action) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.inset)
    }

    private var infrastructureInspector: some View {
        List {
            Section("Daemon") {
                HStack {
                    Label(model.connectivity.title, systemImage: model.connectivity.systemImage)
                        .foregroundStyle(connectivityColor)
                    Spacer()
                    if model.connectivity == .connected {
                        Button("Stop…") { confirmsDaemonStop = true }
                    } else {
                        Button("Start") { model.startDaemon() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let error = model.daemonError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Display pool") {
                inspectorValue("Attached displays", "\(model.infrastructure.displays.count)")
                inspectorValue(
                    "Capacity",
                    "\(model.infrastructure.usedCapacity) used of "
                        + "\(model.infrastructure.totalCapacity)"
                )
                Stepper(value: $requestedDensity, in: 1...64) {
                    VStack(alignment: .leading) {
                        Text("Sessions per new display")
                        Text("\(requestedDensity)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Apply Density") {
                    model.configureSessionsPerDisplay(requestedDensity)
                }
                .disabled(
                    model.connectivity != .connected
                        || requestedDensity == model.infrastructure.configuredDensity
                )
            }
            if !model.infrastructure.displays.isEmpty {
                Section("Displays") {
                    ForEach(model.infrastructure.displays, id: \.displayID) { display in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Display \(display.displayID)")
                                .font(.body.weight(.medium))
                            Text("\(Int(display.width)) × \(Int(display.height)) · "
                                 + "\(display.used)/\(display.capacity) sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var eventsInspector: some View {
        List {
            if model.events.isEmpty {
                inspectorEmpty("No Viewer events yet", systemImage: "list.bullet.rectangle")
            } else {
                ForEach(model.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(event.title, systemImage: severitySymbol(event.severity))
                                .font(.body.weight(.medium))
                                .foregroundStyle(severityColor(event.severity))
                            Spacer()
                            Text(event.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(event.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let sessionID = event.sessionID {
                            Button(sessionID) { model.selectSession(sessionID) }
                                .buttonStyle(.link)
                                .font(.caption.monospaced())
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Banners and toolbar

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Viewer permissions need attention")
                    .font(.callout.weight(.semibold))
                Text(permissionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { model.inspectorSection = .health }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private func streamFailureBanner(_ error: String) -> some View {
        HStack {
            Label(error, systemImage: "xmark.octagon.fill")
                .lineLimit(2)
            Spacer()
            Button("Retry") { model.retryStream() }
        }
        .font(.callout)
        .padding(9)
        .background(Color.red.opacity(0.12))
    }

    private func screenshotBanner(_ result: ViewerScreenshotResult) -> some View {
        HStack {
            Label(
                result.message,
                systemImage: result.isFailure
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill"
            )
            .lineLimit(2)
            Spacer()
            if case .saved = result {
                Button("Reveal in Finder") { model.revealScreenshot() }
            }
            Button("Dismiss") { model.clearScreenshotResult() }
        }
        .font(.callout)
        .padding(9)
        .background((result.isFailure ? Color.orange : Color.green).opacity(0.12))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Scope", selection: Binding(
                get: { model.canvasMode },
                set: { model.setCanvasMode($0) }
            )) {
                ForEach(ViewerCanvasMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            // Gating on a *selected* session made this a one-way door: picking a display row
            // clears the session selection, so the control that switches back disabled itself.
            // What actually matters is whether the display has a session to switch to.
            .disabled(!model.canSwitchCanvasMode)

            ControlGroup {
                Button {
                    model.setZoom(model.viewportZoom - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(model.viewportZoom <= 1)

                Text("\(Int(model.viewportZoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38)

                Button {
                    model.setZoom(model.viewportZoom + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(model.viewportZoom >= 4)
            }

            Toggle(isOn: Binding(
                get: { model.interactionEnabled },
                set: { model.setInteractionEnabled($0) }
            )) {
                Label(
                    model.interactionEnabled ? "Release Input" : "Capture Input",
                    systemImage: model.interactionEnabled
                        ? "lock.open.display"
                        : "cursorarrow.motionlines"
                )
            }
            .toggleStyle(.button)
            .tint(model.interactionEnabled ? .orange : .accentColor)
            .disabled(!controlAvailable && !model.interactionEnabled)
            .help(controlHelp)

            Button {
                model.saveScreenshot()
            } label: {
                Label(
                    model.canvasMode == .session ? "Capture Tile" : "Capture Display",
                    systemImage: "camera"
                )
            }
            .disabled(model.selected == nil)

            Button {
                model.inspectorSection = .health
            } label: {
                Label("Health", systemImage: model.healthAlerts.isEmpty
                      ? "checkmark.circle"
                      : "cross.case.fill")
            }
            .help(model.healthAlerts.isEmpty ? "All systems operational" : "Review health alerts")

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Formatting

    private var controlAvailable: Bool {
        model.selected != nil
            && model.streamState.isLive
            && model.permissions.screenRecording
            && model.permissions.accessibility
    }

    private var controlHelp: String {
        if model.interactionEnabled {
            return "Release the human operator's input. "
                + "\(ViewerControlPolicy.localExitDescription) always works."
        }
        if !controlAvailable {
            return "A live stream plus Screen Recording and Accessibility permissions are required."
        }
        return "Capture keyboard, pointer, and host shortcuts for this session. "
            + "The agent remains active."
    }

    private var selectionSubtitle: String {
        if let session = model.selectedSession, model.canvasMode == .session {
            return "Display \(session.displayID) · tile \(session.tileIndex + 1) of "
                + "\(session.tileCapacity) · \(Int(session.width)) × \(Int(session.height))"
        }
        if let display = model.selected {
            return "Display \(display.id) · \(Int(display.bounds.width)) × "
                + "\(Int(display.bounds.height))"
        }
        return ""
    }

    private var permissionSummary: String {
        var missing: [String] = []
        if !model.permissions.screenRecording { missing.append("Screen Recording") }
        if !model.permissions.accessibility { missing.append("Accessibility") }
        return "Missing " + missing.joined(separator: " and ") + ". Open Health for fixes."
    }

    private func sessionSummary(_ session: SessionInfo) -> String {
        let appNames = session.apps.prefix(2).map(\.name)
        if !appNames.isEmpty {
            return appNames.joined(separator: ", ")
                + (session.apps.count > 2 ? " +\(session.apps.count - 2)" : "")
        }
        if let window = session.windows.first, !window.title.isEmpty {
            return window.title
        }
        return "Waiting for an app"
    }

    private func inspectorValue(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func inspectorEmpty(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func sessionColor(_ badge: ViewerSessionBadge?) -> Color {
        switch badge {
        case .owned: .blue
        case .abandoned: .orange
        case .reclaimable: .green
        case .cleanupPending: .red
        case nil: .cyan
        }
    }

    private var connectivityColor: Color {
        switch model.connectivity {
        case .connecting: .blue
        case .connected: .green
        case .degraded: .orange
        case .disconnected: .red
        }
    }

    private var streamStatusSymbol: String {
        switch model.streamState {
        case .idle: "pause.circle"
        case .starting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .live: "dot.radiowaves.left.and.right"
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

    private func severitySymbol(_ severity: ViewerEventSeverity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private func severityColor(_ severity: ViewerEventSeverity) -> Color {
        switch severity {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

private extension ViewerModel {
    var currentSelectionTitle: String? {
        if canvasMode == .session, let selectedSession {
            if let appName = selectedSession.apps.first?.name {
                return "\(selectedSession.id) · \(appName)"
            }
            return selectedSession.id
        }
        return selected?.name
    }
}
