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
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable launches as an accessory process; without a regular activation
        // policy it would have no Dock icon and its window could not become key.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
