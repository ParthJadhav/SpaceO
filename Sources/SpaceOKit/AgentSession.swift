import Foundation
import AppKit
import CoreGraphics
import SpaceOPrivate

/// One agent's world: a tile on a (possibly shared) agent display, the apps living on it,
/// and their windows.
///
/// A session owns a *region*, not a display. Several sessions share one virtual display
/// because a display is an entire framebuffer for the WindowServer to composite — see
/// `DisplayPool`. Every tile is still part of a genuinely visible display, so the property the
/// design rests on is unchanged: windows there keep rendering.
public final class AgentSession {

    public let id: String
    public let slot: DisplayPool.Slot
    public private(set) var apps: [LaunchedApp] = []
    public private(set) var windows: [WindowRef] = []
    public let createdAt = Date()

    /// The display this session lives on. Shared with its neighbours.
    public var stage: Stage { slot.stage }
    /// The region of that display this session may use. Agent windows go here.
    public var frame: CGRect { slot.frame }
    /// True when this session has the whole display to itself.
    public var hasExclusiveDisplay: Bool { slot.isExclusive }

    /// The most recent AX walk, kept so `click --element N` can resolve an index the caller
    /// obtained from a previous `ax` call.
    public private(set) var lastSnapshot: AXSnapshot?

    /// DevTools bridges for Chromium browsers this session launched, keyed by pid.
    private var bridges: [pid_t: ChromiumBridge] = [:]

    /// Watchers that pull late-appearing windows (dialogs, prompts, extra documents) into our
    /// tile. Without these an app's second window lands on the user's screen.
    private var watchers: [pid_t: WindowWatcher] = [:]
    /// Prevent teardown from overtaking async work that is still registering resources.
    private let lifecycle = SessionLifecycle()

    /// Whatever the user had frontmost when this session began.
    ///
    /// The fallback for handing focus back. Without it, a teardown that starts while one of our
    /// own apps happens to be frontmost has nothing to restore to, and the user is left wherever
    /// the dying app dumped them.
    private let ownerAtCreation: NSRunningApplication?

    public init(id: String, slot: DisplayPool.Slot) {
        self.id = id
        self.slot = slot
        self.ownerAtCreation = NSWorkspace.shared.frontmostApplication
    }

    /// A manager command holds this lease until its response is fully assembled. Direct destroy
    /// calls then wait too, rather than racing the manager merely because they bypass its actor.
    func beginOperation() throws -> SessionLifecycle.Lease {
        guard let lease = lifecycle.beginOperation() else {
            throw SpaceOError.unknownSession(id)
        }
        return lease
    }

    // MARK: - Apps

    /// Set when a launched app grabbed focus and we had to hand it back to the user.
    public private(set) var lastLaunchRestoredFocus: String?

    @discardableResult
    public nonisolated(nonsending) func launch(
        app appURL: URL,
        opening files: [URL] = []
    ) async throws -> LaunchedApp {
        let lifecycleLease = try beginOperation()
        defer { lifecycleLease.finish() }

        // Some apps activate themselves regardless of `activates = false` — Electron shells are
        // the usual offenders, calling NSApp.activate on startup. We cannot stop them, but we
        // can hand the user's frontmost app straight back, turning a lasting theft into a blip.
        let userRoute = try? InputRouter.captureUserInputRoute()
        lastLaunchRestoredFocus = nil

        let (app, placed) = try await AppLauncher.launch(appURL: appURL, opening: files, into: frame)
        do {
            try ProcessOwnership.claim(app.identity, owner: id)
        } catch {
            // We started this process, so a claim conflict means its PID was recycled onto a
            // stale record. Do not leave an unowned invisible app behind.
            AppLauncher.quit(app, force: true)
            AppLauncher.cleanupTemporaryProfileEventually(for: app)
            throw error
        }

        if let userRoute, userRoute.app.processIdentifier != app.pid {
            // Both notions of "frontmost" matter. AppKit's view and the WindowServer's can
            // disagree for a moment. Key and typing recipients matter too: leaving either route
            // on an invisible app is the freeze this guard exists to prevent.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if InputRouter.currentRouteTargets(app.pid) { break }
            }
            if InputRouter.currentRouteTargets(app.pid) {
                if InputRouter.restoreUserInputRoute(userRoute) {
                    lastLaunchRestoredFocus = userRoute.app.localizedName
                        ?? "pid \(userRoute.app.processIdentifier)"
                }
            }
        }

        register(app: app, windows: placed)
        if let port = app.devToolsPort {
            let bridge = ChromiumBridge(port: port)
            if await bridge.waitUntilReady(),
               (try? await bridge.attachToLaunchedTarget()) != nil {
                bridges[app.pid] = bridge
            }
        }
        // Browser startup can activate late, after its DevTools endpoint and restore prompt
        // appear. Recheck after the full launch sequence, not only after the first window.
        if let userRoute, InputRouter.currentRouteTargets(app.pid) {
            if InputRouter.restoreUserInputRoute(userRoute) {
                lastLaunchRestoredFocus = userRoute.app.localizedName
                    ?? "pid \(userRoute.app.processIdentifier)"
            }
        }
        return app
    }

    // MARK: - Web content
    //
    // Chromium web content cannot be driven with synthetic input at all — see ChromiumBridge.
    // These route through DevTools instead, and are only available for browsers we launched.

    public func webBridge(for pid: pid_t? = nil) -> ChromiumBridge? {
        if let pid { return bridges[pid] }
        if let only = bridges.first, bridges.count == 1 { return only.value }
        if let primary = primaryWindow { return bridges[primary.pid] }
        return nil
    }

    public var hasWebBridge: Bool { !bridges.isEmpty }

    /// Adopt a process the user points us at.
    ///
    /// Ownership is claimed before the first window moves, so a PID already spoken for by
    /// another session is refused without this session having disturbed anything.
    @discardableResult
    public func adopt(pid: pid_t) throws -> LaunchedApp {
        let app = try AppLauncher.describe(pid: pid)
        guard !apps.contains(where: { $0.identity == app.identity }) else {
            throw SpaceOError.badRequest(
                "session '\(id)' already owns pid \(pid)")
        }
        try ProcessOwnership.claim(app.identity, owner: id)
        do {
            let placed = try AppLauncher.place(app, into: frame)
            register(app: app, windows: placed)
            return app
        } catch {
            ProcessOwnership.release(app.identity)
            throw error
        }
    }

    private func register(app: LaunchedApp, windows placed: [WindowRef]) {
        if !apps.contains(where: { $0.pid == app.pid }) { apps.append(app) }
        // Registering what belongs to the agent is what lets IsolationSnapshot tell a breach
        // ("an agent app grabbed focus") from the user simply switching windows.
        AgentActivity.claim(pid: app.pid)
        AgentActivity.claim(spaces: stage.spaces)
        for window in placed where !windows.contains(where: { $0.windowID == window.windowID }) {
            windows.append(window)
        }
        if watchers[app.pid] == nil {
            watchers[app.pid] = WindowWatcher(pid: app.pid, region: { [weak self] in
                self?.frame ?? .zero
            })
        }
        refreshWindows()
    }

    private func unregister(pid: pid_t) {
        watchers.removeValue(forKey: pid)?.stop()
        if let bridge = bridges.removeValue(forKey: pid) {
            Task { await bridge.detach() }
        }
        for app in apps where app.pid == pid { ProcessOwnership.release(app.identity) }
        apps.removeAll { $0.pid == pid }
        windows.removeAll { $0.pid == pid }
        AgentActivity.release(pid: pid)
        lastSnapshot = nil
    }

    /// Drop apps whose process has exited, releasing their PID, ownership claim, and watcher.
    ///
    /// Without this the session holds a claim on a dead process indefinitely, and the janitor
    /// keeps observing an app that will never emit another notification. Returns how many it
    /// reaped, so a caller can report the sweep honestly.
    @discardableResult
    public func reapExitedApps() -> Int {
        let dead = apps.filter { !$0.identity.isAlive }
        for app in dead {
            unregister(pid: app.pid)
            AppLauncher.cleanupTemporaryProfileEventually(for: app)
        }
        return dead.count
    }

    /// How many stray windows the watchers have contained, and how many refused to move.
    public var containment: (placed: Int, refused: Int) {
        watchers.values.reduce(into: (0, 0)) { total, watcher in
            total.0 += watcher.placedCount
            total.1 += watcher.refusedCount
        }
    }

    /// Notifications the AX observers refused to register, per app. Containment for these apps
    /// depends on the periodic sweep alone, so the audit reports it rather than letting a
    /// half-deaf watcher look healthy.
    public var watcherRegistrationFailures: [String] {
        watchers.compactMap { pid, watcher in
            guard !watcher.registrationFailures.isEmpty else { return nil }
            let name = apps.first { $0.pid == pid }?.name ?? "pid \(pid)"
            return "\(name): \(watcher.registrationFailures.joined(separator: ", "))"
        }
    }

    /// Run every watcher now. Cheap, and useful as a belt-and-braces sweep before a screenshot.
    public func sweepStrayWindows() {
        for watcher in watchers.values { watcher.sweep() }
    }

    /// One janitor pass: reap exited apps, then contain whatever is left.
    ///
    /// Reaping first matters — sweeping an app that has already exited is a pointless
    /// WindowServer round trip, and its watcher would otherwise live until the session is
    /// destroyed. Returns how many apps were reaped.
    @discardableResult
    public func runJanitorPass() -> Int {
        let reaped = reapExitedApps()
        sweepStrayWindows()
        return reaped
    }

    // MARK: - Windows

    /// Re-read every owned window's live geometry and drop the ones that closed.
    @discardableResult
    public func refreshWindows() -> [WindowRef] {
        var live: [WindowRef] = []
        for app in apps where app.identity.isAlive {
            live.append(contentsOf: WindowPlacement.windows(of: app.pid))
        }
        windows = live
        return windows
    }

    public func window(id: CGWindowID) -> WindowRef? {
        windows.first { $0.windowID == id }
    }

    /// The window an agent means when it does not say which: the largest one in our tile.
    public var primaryWindow: WindowRef? {
        let mine = windows.filter { WindowPlacement.isInRegion($0, frame) }
        let candidates = mine.isEmpty ? windows : mine
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    public func resolveWindow(_ explicit: CGWindowID?) throws -> WindowRef {
        refreshWindows()
        if let explicit {
            guard let found = window(id: explicit) else {
                throw SpaceOError.windowNotFound("window \(explicit) is not in session '\(id)'")
            }
            return found
        }
        guard let primary = primaryWindow else {
            throw SpaceOError.windowNotFound("session '\(id)' has no windows yet")
        }
        return primary
    }

    // MARK: - Accessibility

    @discardableResult
    public func snapshotAX(window: WindowRef? = nil) throws -> AXSnapshot {
        let target = try window ?? resolveWindow(nil)
        let snapshot = try AXTree.snapshot(pid: target.pid, window: target)
        lastSnapshot = snapshot
        return snapshot
    }

    /// Resolve an element index from the cached walk, taking one automatically if needed.
    public func element(at index: Int) throws -> AXUIElement {
        let snapshot = try lastSnapshot ?? snapshotAX()
        guard let element = snapshot.element(at: index) else {
            throw SpaceOError.badRequest("no element [\(index)] — run `spaceo ax \(id)` for current indices")
        }
        return element
    }

    // MARK: - Janitor

    /// Problems worth reporting: windows that wandered out of our tile, apps that died,
    /// a display that lost its Space.
    public func audit() -> [String] {
        var findings: [String] = []
        if !stage.isValid { findings.append("agent display is no longer valid") }
        if stage.spaces.isEmpty { findings.append("agent display reports no Space of its own") }

        refreshWindows()
        for window in windows where !WindowPlacement.isInRegion(window, frame) {
            let where_ = stage.contains(window.frame)
                ? "drifted into a neighbouring session's tile"
                : "escaped the agent display"
            findings.append("window \(window.windowID) (\(window.title)) \(where_)")
        }
        for app in apps where !app.identity.isAlive {
            findings.append("app \(app.name) (pid \(app.pid)) exited")
        }
        for failure in watcherRegistrationFailures {
            findings.append("window notifications are not fully registered for \(failure); "
                          + "late windows rely on the periodic sweep alone")
        }
        let contained = containment
        if contained.refused > 0 {
            findings.append("\(contained.refused) window(s) refused to move into the tile "
                          + "(usually app-modal sheets, which stay attached to their parent)")
        }
        return findings
    }

    /// Put stray windows back in our tile. Returns how many were moved.
    @discardableResult
    public func reparkEscapedWindows() -> Int {
        refreshWindows()
        var moved = 0
        for window in windows where !WindowPlacement.isInRegion(window, frame) {
            if (try? WindowPlacement.move(window, to: WindowPlacement.defaultFrame(in: frame))) != nil {
                moved += 1
            }
        }
        if moved > 0 { refreshWindows() }
        return moved
    }

    // MARK: - Teardown

    /// Release the session's apps and windows.
    ///
    /// Order is load-bearing. The WindowServer will not retire a virtual display while windows
    /// still live on it, so the tile must be emptied *before* `DisplayPool` releases the slot:
    ///
    ///   1. evacuate windows belonging to apps we are not quitting back to the user's display,
    ///   2. quit the apps we started and wait for them to actually exit,
    ///   3. the pool then frees the tile, and retires the display if we were the last tenant.
    ///
    /// Skipping step 2 leaves a phantom monitor attached until the process dies.
    ///
    /// - Parameter force: after `timeout`, force-terminate apps *we started* that refuse to quit
    ///   (a modal save sheet is the usual reason). Apps we merely adopted are never force-killed.
    public func destroy(quitApps: Bool = true, force: Bool = true, timeout: TimeInterval = 6) {
        lifecycle.destroy {
            destroyResources(quitApps: quitApps, force: force, timeout: timeout)
        }
    }

    private func destroyResources(quitApps: Bool, force: Bool, timeout: TimeInterval) {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 30) : 6
        let ourPIDs = Set(apps.filter(\.startedByUs).map(\.pid))

        // Quitting an app pulls focus just as launching one does — a document with unsaved
        // changes gets brought forward to show its save sheet before it dies. Remember where
        // the user was so we can put them back.
        let userRoute = try? InputRouter.captureUserInputRoute(excluding: ourPIDs)

        // 1. Windows that will outlive this session must not vanish with the display.
        refreshWindows()
        let survivors = windows.filter { !quitApps || !ourPIDs.contains($0.pid) }
        if !survivors.isEmpty, let userDisplay = Stage.preferredActiveUserDisplayBounds() {
            for (index, window) in survivors.enumerated() {
                let offset = CGFloat(index) * 28
                let target = WindowPlacement.defaultFrame(in: userDisplay)
                    .offsetBy(dx: offset, dy: offset)
                // Best effort: a window that refuses to move still gets migrated by the
                // WindowServer when the display goes away, just less tidily.
                _ = try? WindowPlacement.move(window, to: target)
            }
        }

        // 2. Quit ours, then confirm they are really gone. Liveness is by identity throughout:
        // a PID that reappears mid-teardown belongs to someone else and must not be waited on,
        // let alone force-terminated.
        if quitApps {
            for app in apps where app.startedByUs { AppLauncher.quit(app) }
            let deadline = Date().addingTimeInterval(safeTimeout)
            var pending = apps.filter(\.startedByUs)
            while !pending.isEmpty && Date() < deadline {
                usleep(120_000)
                pending = pending.filter { $0.identity.isAlive }
            }
            if force {
                for app in pending { AppLauncher.quit(app, force: true) }
                let hardDeadline = Date().addingTimeInterval(3)
                while Date() < hardDeadline,
                      pending.contains(where: { $0.identity.isAlive }) {
                    usleep(120_000)
                }
            }
        }

        // Hand focus back only if teardown left an agent route behind. If the user switched to
        // another ordinary app while cleanup was waiting, that newer choice takes precedence.
        let currentFrontmostPID =
            NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if let userRoute,
           ourPIDs.contains(currentFrontmostPID) {
            _ = InputRouter.restoreUserInputRoute(userRoute)
        } else if let owner = ownerAtCreation,
                  ourPIDs.contains(currentFrontmostPID),
                  NSRunningApplication(processIdentifier: owner.processIdentifier) != nil {
            // The session may have started while one of its apps was already frontmost, leaving
            // no complete route snapshot. Public activation is a last-resort visual recovery.
            _ = owner.activate()
        }

        for app in apps {
            AgentActivity.release(pid: app.pid)
            ProcessOwnership.release(app.identity)
            AppLauncher.cleanupTemporaryProfileEventually(for: app)
        }
        // Belt and braces: a claim that somehow outlived its app record would lock that process
        // out of every future session, so sweep anything still filed under this session's name.
        ProcessOwnership.releaseAll(owner: id)
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        for bridge in bridges.values { Task { await bridge.detach() } }
        bridges.removeAll()
        apps.removeAll()
        windows.removeAll()
        lastSnapshot = nil
    }
}
