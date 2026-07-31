import AppKit
import SwiftUI

/// A VM-style console onto SpaceO's virtual displays: watch an agent's screen live and, when
/// you flip the Control toggle, drive it with your own mouse and keyboard — delivered per-PID,
/// so the real cursor, keyboard focus, and frontmost app never change hands.
@main
struct SpaceOViewerApp: App {
    @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var delegate
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        WindowGroup("SpaceO Viewer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 640)
        }
        .defaultSize(width: 1_420, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .toolbar) {
                Button(model.interactionEnabled ? "Release Input" : "Capture Input") {
                    model.setInteractionEnabled(!model.interactionEnabled)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.streamRunning && !model.interactionEnabled)
            }
        }
    }
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable launches as an accessory process; without a regular activation
        // policy it would have no Dock icon and its window could not become key.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Repair first, arm second. A previous run that was force-quit while holding Control
        // left this Mac with a hidden cursor, a mouse decoupled from that cursor, and Spotlight
        // and Mission Control switched off; nothing else in the system undoes any of it.
        if HostInputGuard.repairAbandonedCapture() {
            NSLog("SpaceO Viewer: restored host input state abandoned by a previous run")
        }
        HostInputGuard.installTerminationHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit, logout, and SIGTERM end the process without unwinding the view hierarchy, so
        // the surface's own capture teardown never runs on any of them.
        HostInputGuard.restoreIfCaptureActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
