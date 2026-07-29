import Foundation
import AppKit
import CoreGraphics
import SpaceOPrivate

/// Injectable process operations keep teardown deterministic in tests without weakening the
/// production identity checks in `AppLauncher`.
struct SessionAppTeardownDriver: Sendable {
    let isAlive: @Sendable (ProcessIdentity) -> Bool
    let quit: @Sendable (LaunchedApp, Bool) -> Void
    let waitForExit: @Sendable ([LaunchedApp], TimeInterval) -> [LaunchedApp]
    let cleanupTemporaryProfile: @Sendable (LaunchedApp) -> Void

    static let live = SessionAppTeardownDriver(
        isAlive: { $0.isAlive },
        quit: { AppLauncher.quit($0, force: $1) },
        waitForExit: { apps, timeout in
            let deadline = Date().addingTimeInterval(timeout)
            var pending = apps.filter { $0.identity.isAlive }
            while !pending.isEmpty && Date() < deadline {
                usleep(120_000)
                pending = pending.filter { $0.identity.isAlive }
            }
            return pending
        },
        cleanupTemporaryProfile: { AppLauncher.cleanupTemporaryProfileEventually(for: $0) }
    )
}

/// Runtime policy for controller lease expiry and abandoned-session reclamation.
///
/// The clock and liveness probe are injectable so expiry, PID reuse, and grace periods can be
/// tested without sleeping or launching a controller process.
struct SessionReclamationPolicy: Sendable {
    static let clientTTLRange: ClosedRange<TimeInterval> = 30...3_600

    let defaultTTL: TimeInterval
    let gracePeriod: TimeInterval
    let now: @Sendable () -> Date
    let ownerIsAlive: @Sendable (DurableSessionOwner) -> Bool

    init(
        defaultTTL: TimeInterval = 300,
        gracePeriod: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        ownerIsAlive: @escaping @Sendable (DurableSessionOwner) -> Bool = {
            $0.processIdentity?.isAlive ?? true
        }
    ) {
        precondition(defaultTTL.isFinite && defaultTTL > 0)
        precondition(gracePeriod.isFinite && gracePeriod >= 0)
        self.defaultTTL = defaultTTL
        self.gracePeriod = gracePeriod
        self.now = now
        self.ownerIsAlive = ownerIsAlive
    }

    func duration(requested: TimeInterval?) throws -> TimeInterval {
        guard let requested else { return defaultTTL }
        guard requested.isFinite, Self.clientTTLRange.contains(requested) else {
            throw SpaceOError.badRequest(
                "controller TTL must be a finite value from "
                    + "\(Int(Self.clientTTLRange.lowerBound)) through "
                    + "\(Int(Self.clientTTLRange.upperBound)) seconds")
        }
        return requested
    }
}

struct SessionControllerSnapshot: Sendable {
    let owner: DurableSessionOwner
    let lease: DurableSessionLease
    let lastActivityAt: Date
    let abandonedAt: Date?
    let ageSeconds: TimeInterval
    let abandoned: Bool
    let reclaimable: Bool
}

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
    /// True when cleanup is terminal for new work but retained resources still need a retry.
    public var teardownPending: Bool {
        lifecycle.currentState != .active && !apps.isEmpty
    }

    /// The most recent AX walk, kept so `click --element N` can resolve an index the caller
    /// obtained from a previous `ax` call. The cache also binds that walk to the exact window,
    /// process identity, and session generation that produced it.
    private var axSnapshotCache = AXSnapshotCache()
    public var lastSnapshot: AXSnapshot? { axSnapshotCache.snapshot }

    /// DevTools bridges for Chromium browsers this session launched, keyed by pid.
    private var bridges: [pid_t: ChromiumBridge] = [:]

    /// Watchers that pull late-appearing windows (dialogs, prompts, extra documents) into our
    /// tile. Without these an app's second window lands on the user's screen.
    private var watchers: [pid_t: WindowWatcher] = [:]
    /// Prevent teardown from overtaking async work that is still registering resources.
    private let lifecycle = SessionLifecycle()
    /// Serializes the initial destroy with later cleanup retries.
    private let teardownLock = NSLock()
    private let teardownDriver: SessionAppTeardownDriver
    private let capturesInputRouteDuringTeardown: Bool
    private let controllerLock = NSLock()
    private var controllerRuntime: ControllerRuntime?

    private struct ControllerRuntime {
        var owner: DurableSessionOwner
        var lease: DurableSessionLease
        var duration: TimeInterval
        var lastActivityAt: Date
        var abandonedAt: Date?
        var policy: SessionReclamationPolicy
        var allowsLeaseOmission: Bool
    }

    /// Whatever the user had frontmost when this session began.
    ///
    /// The fallback for handing focus back. Without it, a teardown that starts while one of our
    /// own apps happens to be frontmost has nothing to restore to, and the user is left wherever
    /// the dying app dumped them.
    private let ownerAtCreation: NSRunningApplication?

    public init(id: String, slot: DisplayPool.Slot) {
        self.id = id
        self.slot = slot
        self.teardownDriver = .live
        self.capturesInputRouteDuringTeardown = true
        self.ownerAtCreation = NSWorkspace.shared.frontmostApplication
    }

    /// Test-only construction of a real session ledger around injected process behavior.
    init(
        id: String,
        slot: DisplayPool.Slot,
        teardownDriver: SessionAppTeardownDriver,
        initialApps: [LaunchedApp]
    ) throws {
        self.id = id
        self.slot = slot
        self.teardownDriver = teardownDriver
        self.capturesInputRouteDuringTeardown = false
        self.ownerAtCreation = nil
        var claimed: [LaunchedApp] = []
        do {
            for app in initialApps {
                try ProcessOwnership.claim(app.identity, owner: id)
                AgentActivity.claim(pid: app.pid)
                claimed.append(app)
            }
        } catch {
            for app in claimed {
                ProcessOwnership.release(app.identity)
                AgentActivity.release(pid: app.pid)
            }
            throw error
        }
        self.apps = initialApps
    }

    /// A manager command holds this lease until its response is fully assembled. Direct destroy
    /// calls then wait too, rather than racing the manager merely because they bypass its actor.
    func beginOperation() throws -> SessionLifecycle.Lease {
        guard let lease = lifecycle.beginOperation() else {
            throw SpaceOError.unknownSession(id)
        }
        return lease
    }

    // MARK: - Controller lease

    func configureController(
        owner: DurableSessionOwner,
        daemonInstanceID: UUID,
        leaseID: UUID,
        duration: TimeInterval,
        policy: SessionReclamationPolicy,
        allowsLeaseOmission: Bool
    ) {
        let now = policy.now()
        controllerLock.withLock {
            controllerRuntime = ControllerRuntime(
                owner: owner,
                lease: DurableSessionLease(
                    daemonInstanceID: daemonInstanceID,
                    leaseID: leaseID,
                    generation: 1,
                    acquiredAt: now,
                    lastHeartbeatAt: now,
                    expiresAt: now.addingTimeInterval(duration)),
                duration: duration,
                lastActivityAt: now,
                abandonedAt: nil,
                policy: policy,
                allowsLeaseOmission: allowsLeaseOmission)
        }
    }

    func controllerSnapshot() -> SessionControllerSnapshot? {
        controllerLock.withLock {
            guard var runtime = controllerRuntime else { return nil }
            let now = runtime.policy.now()
            Self.refreshControllerState(&runtime, at: now)
            controllerRuntime = runtime
            return Self.snapshot(runtime, at: now)
        }
    }

    /// Validate that an owner-scoped mutation may start. Explicit controllers must supply the
    /// current lease; omission remains available only to the legacy in-process API.
    func authorizeControllerMutation(leaseID: UUID?) throws {
        try controllerLock.withLock {
            guard var runtime = controllerRuntime else { return }
            let now = runtime.policy.now()
            Self.refreshControllerState(&runtime, at: now)
            controllerRuntime = runtime
            guard runtime.abandonedAt == nil else {
                throw SpaceOError.badRequest(
                    "session '\(id)' is abandoned and awaiting reclamation")
            }
            if leaseID == nil, !runtime.allowsLeaseOmission {
                throw SpaceOError.badRequest(
                    "controller lease is required for session '\(id)'")
            }
            if let leaseID, leaseID != runtime.lease.leaseID {
                throw SpaceOError.badRequest(
                    "controller lease does not match session '\(id)'")
            }
        }
    }

    /// Renew only after an owner-scoped mutation has completed successfully.
    func recordSuccessfulControllerMutation(leaseID: UUID?) throws {
        try controllerLock.withLock {
            guard var runtime = controllerRuntime else { return }
            let now = runtime.policy.now()
            // Authorization happened before the mutation under SessionManager's global gate.
            // Crossing the wall-clock expiry while that authorized mutation is in flight must
            // not turn a completed effect into a reported failure or abandon it retroactively.
            guard runtime.abandonedAt == nil else {
                throw SpaceOError.badRequest(
                    "session '\(id)' became abandoned before its lease could renew")
            }
            if leaseID == nil, !runtime.allowsLeaseOmission {
                throw SpaceOError.badRequest(
                    "controller lease is required for session '\(id)'")
            }
            if let leaseID, leaseID != runtime.lease.leaseID {
                throw SpaceOError.badRequest(
                    "controller lease does not match session '\(id)'")
            }
            let heartbeatAt = max(
                now,
                runtime.lastActivityAt,
                runtime.lease.acquiredAt,
                runtime.lease.lastHeartbeatAt)
            runtime.lastActivityAt = heartbeatAt
            runtime.lease.lastHeartbeatAt = heartbeatAt
            runtime.lease.expiresAt =
                heartbeatAt.addingTimeInterval(runtime.duration)
            controllerRuntime = runtime
        }
    }

    @discardableResult
    func heartbeatController(leaseID: UUID) throws -> SessionControllerSnapshot {
        try controllerLock.withLock {
            guard var runtime = controllerRuntime else {
                throw SpaceOError.badRequest(
                    "session '\(id)' has no controller lease")
            }
            let now = runtime.policy.now()
            Self.refreshControllerState(&runtime, at: now)
            guard runtime.abandonedAt == nil else {
                controllerRuntime = runtime
                throw SpaceOError.badRequest(
                    "session '\(id)' is abandoned and cannot renew its old lease")
            }
            guard leaseID == runtime.lease.leaseID else {
                throw SpaceOError.badRequest(
                    "controller lease does not match session '\(id)'")
            }
            let heartbeatAt = max(
                now,
                runtime.lastActivityAt,
                runtime.lease.acquiredAt,
                runtime.lease.lastHeartbeatAt)
            runtime.lastActivityAt = heartbeatAt
            runtime.lease.lastHeartbeatAt = heartbeatAt
            runtime.lease.expiresAt =
                heartbeatAt.addingTimeInterval(runtime.duration)
            controllerRuntime = runtime
            return Self.snapshot(runtime, at: max(now, heartbeatAt))
        }
    }

    private static func refreshControllerState(
        _ runtime: inout ControllerRuntime,
        at now: Date
    ) {
        guard runtime.abandonedAt == nil else { return }
        if now >= runtime.lease.expiresAt {
            // Expiry is known exactly, so the grace interval starts there rather than at the
            // next periodic janitor observation.
            runtime.abandonedAt = runtime.lease.expiresAt
        } else if !runtime.policy.ownerIsAlive(runtime.owner) {
            // Process death has no timestamp in the kernel API used here. The first exact-
            // identity observation is the earliest honest abandonment time.
            runtime.abandonedAt = max(
                now,
                runtime.lastActivityAt,
                runtime.lease.acquiredAt)
        }
    }

    private static func snapshot(
        _ runtime: ControllerRuntime,
        at now: Date
    ) -> SessionControllerSnapshot {
        let abandoned = runtime.abandonedAt != nil
        let reclaimable = runtime.abandonedAt.map {
            now >= $0.addingTimeInterval(runtime.policy.gracePeriod)
        } ?? false
        return SessionControllerSnapshot(
            owner: runtime.owner,
            lease: runtime.lease,
            lastActivityAt: runtime.lastActivityAt,
            abandonedAt: runtime.abandonedAt,
            ageSeconds: max(0, now.timeIntervalSince(runtime.lease.acquiredAt)),
            abandoned: abandoned,
            reclaimable: reclaimable)
    }

    // MARK: - Apps

    /// Set when a launched app grabbed focus and we had to hand it back to the user.
    public private(set) var lastLaunchRestoredFocus: String?

    @discardableResult
    public nonisolated(nonsending) func launch(
        app appURL: URL,
        opening files: [URL] = [],
        onMaterialized: (LaunchedApp) throws -> Void = { _ in }
    ) async throws -> LaunchedApp {
        let lifecycleLease = try beginOperation()
        defer { lifecycleLease.finish() }

        // Some apps activate themselves regardless of `activates = false` — Electron shells are
        // the usual offenders, calling NSApp.activate on startup. We cannot stop them, but we
        // can hand the user's frontmost app straight back, turning a lasting theft into a blip.
        let userRoute = try? InputRouter.captureUserInputRoute()
        lastLaunchRestoredFocus = nil

        let (app, placed) = try await AppLauncher.launch(
            appURL: appURL,
            opening: files,
            into: frame,
            onMaterialized: { materialized in
                do {
                    try self.registerMaterializedApp(materialized)
                } catch {
                    // We started this process, so a claim conflict means another live session
                    // already accounts for the exact identity. Ask it to exit rather than leave
                    // a newly spawned, unowned invisible process behind.
                    AppLauncher.quit(materialized, force: true)
                    AppLauncher.cleanupTemporaryProfileEventually(for: materialized)
                    throw error
                }
                try onMaterialized(materialized)
            })

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

    /// Claim and register the exact process at the durable materialization boundary, before
    /// launch waits or placement. Internal for deterministic crash-boundary tests.
    func registerMaterializedApp(_ app: LaunchedApp) throws {
        try ProcessOwnership.claim(app.identity, owner: id)
        removeStaleRegistrationSharingPID(with: app)
        invalidateAXSnapshot()
        if let index = apps.firstIndex(where: { $0.identity == app.identity }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
        // Keep this boundary deliberately minimal. Stage Space discovery, watcher creation, and
        // AX/window enumeration can block; the daemon must persist the exact process first.
        AgentActivity.claim(pid: app.pid)
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
        invalidateAXSnapshot()
        removeStaleRegistrationSharingPID(with: app)
        if let index = apps.firstIndex(where: { $0.identity == app.identity }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
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

    /// Replace dead/recycled bookkeeping before a newly materialized exact identity reuses its
    /// PID. A PID-only duplicate check would silently retain and persist the old process instead.
    private func removeStaleRegistrationSharingPID(with app: LaunchedApp) {
        let stale = apps.filter {
            $0.pid == app.pid && $0.identity != app.identity
        }
        guard !stale.isEmpty else { return }

        watchers.removeValue(forKey: app.pid)?.stop()
        if let bridge = bridges.removeValue(forKey: app.pid) {
            Task { await bridge.detach() }
        }
        for old in stale {
            ProcessOwnership.release(old.identity)
            AppLauncher.cleanupTemporaryProfileEventually(for: old)
        }
        apps.removeAll {
            $0.pid == app.pid && $0.identity != app.identity
        }
        windows.removeAll { $0.pid == app.pid }
        AgentActivity.release(pid: app.pid)
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
        invalidateAXSnapshot()
    }

    /// Undo a resource registration whose first durable post-effect save failed.
    ///
    /// Launched apps are terminated by exact identity; adopted apps are evacuated and released
    /// without termination. A false result keeps the app in this session's in-memory ledger so a
    /// later persistence or teardown retry still owns it.
    func rollbackUndurableApp(_ app: LaunchedApp) -> Bool {
        guard apps.contains(where: { $0.identity == app.identity }) else { return true }

        if app.startedByUs {
            if teardownDriver.isAlive(app.identity) {
                teardownDriver.quit(app, false)
            }
            var pending = teardownDriver.waitForExit([app], 2)
            if !pending.isEmpty {
                pending.forEach { teardownDriver.quit($0, true) }
                pending = teardownDriver.waitForExit(pending, 1)
            }
            guard !teardownDriver.isAlive(app.identity), pending.isEmpty else {
                return false
            }
            teardownDriver.cleanupTemporaryProfile(app)
            unregister(pid: app.pid)
            return true
        }

        refreshWindows()
        let adoptedWindows = windows.filter { $0.pid == app.pid }
        if !adoptedWindows.isEmpty {
            guard let userDisplay = Stage.preferredActiveUserDisplayBounds() else {
                return false
            }
            for (index, window) in adoptedWindows.enumerated() {
                let target = WindowPlacement.defaultFrame(in: userDisplay)
                    .offsetBy(dx: CGFloat(index) * 28, dy: CGFloat(index) * 28)
                guard (try? WindowPlacement.move(window, to: target)) != nil else {
                    return false
                }
            }
        }
        unregister(pid: app.pid)
        return true
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
        if Self.sortedWindows(live) != Self.sortedWindows(windows) {
            invalidateAXSnapshot()
        }
        windows = live
        return windows
    }

    private static func sortedWindows(_ windows: [WindowRef]) -> [WindowRef] {
        windows.sorted {
            if $0.windowID != $1.windowID { return $0.windowID < $1.windowID }
            return $0.pid < $1.pid
        }
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
        let identity = try liveProcessIdentity(for: target)
        let generation = axSnapshotCache.generation
        let snapshot = try AXTree.snapshot(
            pid: target.pid,
            window: target,
            generation: generation)
        guard snapshot.processIdentity == identity else {
            throw SpaceOError.windowNotFound(
                "the process behind window \(target.windowID) changed during "
                    + "accessibility traversal")
        }
        try axSnapshotCache.store(snapshot)
        return snapshot
    }

    /// Resolve an element index only when it belongs to the explicitly requested live window.
    public func element(at index: Int, for window: WindowRef) throws -> AXUIElement {
        try axSnapshotCache.element(
            at: index,
            for: window,
            processIdentity: liveProcessIdentity(for: window))
    }

    /// Compatibility path for direct library callers. Command handling always passes its
    /// already-resolved target explicitly, and this path still refuses a cache from any other
    /// current primary window.
    public func element(at index: Int) throws -> AXUIElement {
        try element(at: index, for: resolveWindow(nil))
    }

    /// Any operation that may change the window hierarchy expires all previously published
    /// indices. A UUID generation also keeps an in-flight traversal from repopulating the cache.
    func invalidateAXSnapshot() {
        axSnapshotCache.invalidate()
    }

    private func liveProcessIdentity(for window: WindowRef) throws -> ProcessIdentity {
        guard let identity = apps.first(where: {
            $0.pid == window.pid && $0.identity.isAlive
        })?.identity else {
            throw SpaceOError.windowNotFound(
                "window \(window.windowID) is no longer backed by a live process "
                    + "owned by session '\(id)'")
        }
        return identity
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
    @discardableResult
    public func destroy(
        quitApps: Bool = true,
        force: Bool = true,
        timeout: TimeInterval = 6
    ) -> TeardownReport {
        teardownLock.lock()
        defer { teardownLock.unlock() }

        var firstReport: TeardownReport?
        let performedInitialCleanup = lifecycle.destroy {
            firstReport = destroyResources(
                quitApps: quitApps,
                force: force,
                timeout: timeout)
        }
        if performedInitialCleanup, let firstReport { return firstReport }

        // The lifecycle remains terminal, but its retained resource ledger is intentionally
        // retryable. No new operation can start while this pass attempts the cleanup again.
        return destroyResources(quitApps: quitApps, force: force, timeout: timeout)
    }

    private func destroyResources(
        quitApps: Bool,
        force: Bool,
        timeout: TimeInterval
    ) -> TeardownReport {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 30) : 6
        let ourPIDs = Set(apps.filter(\.startedByUs).map(\.pid))

        // Quitting an app pulls focus just as launching one does — a document with unsaved
        // changes gets brought forward to show its save sheet before it dies. Remember where
        // the user was so we can put them back.
        let userRoute = capturesInputRouteDuringTeardown
            ? try? InputRouter.captureUserInputRoute(excluding: ourPIDs)
            : nil

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
        var pending: [LaunchedApp] = []
        if quitApps {
            for app in apps
            where app.startedByUs && teardownDriver.isAlive(app.identity) {
                teardownDriver.quit(app, false)
            }
            pending = teardownDriver.waitForExit(
                apps.filter(\.startedByUs),
                safeTimeout)
            if force {
                for app in pending { teardownDriver.quit(app, true) }
                pending = teardownDriver.waitForExit(pending, 3)
            }
            pending = pending.filter { teardownDriver.isAlive($0.identity) }
        }
        let survivingIdentities = Set(pending.map(\.identity))

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

        let completedApps = apps.filter {
            !survivingIdentities.contains($0.identity)
        }
        for app in completedApps {
            AgentActivity.release(pid: app.pid)
            ProcessOwnership.release(app.identity)
            // `--keep-apps` releases a live launched process. Its temporary browser profile is
            // still in use and belongs with that surviving process, not with session cleanup.
            if !app.startedByUs
                || quitApps
                || !teardownDriver.isAlive(app.identity) {
                teardownDriver.cleanupTemporaryProfile(app)
            }
            watchers.removeValue(forKey: app.pid)?.stop()
            if let bridge = bridges.removeValue(forKey: app.pid) {
                Task { await bridge.detach() }
            }
        }
        apps = pending
        let survivingPIDs = Set(pending.map(\.pid))
        windows.removeAll { !survivingPIDs.contains($0.pid) }
        invalidateAXSnapshot()

        if pending.isEmpty {
            // Belt and braces: a completed teardown must not leave an unrepresented stale claim.
            ProcessOwnership.releaseAll(owner: id)
            for watcher in watchers.values { watcher.stop() }
            watchers.removeAll()
            for bridge in bridges.values { Task { await bridge.detach() } }
            bridges.removeAll()
            windows.removeAll()
        }

        return TeardownReport(
            survivingProcesses: pending.map(SurvivingProcessInfo.init),
            stillAttachedDisplayIDs: pending.isEmpty ? [] : [stage.displayID],
            pendingSessionIDs: pending.isEmpty ? [] : [id])
    }
}
