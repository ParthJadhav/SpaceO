import Foundation
import CoreGraphics
import SpaceOPrivate

protocol StageDisplayBacking: AnyObject {
    var displayID: CGDirectDisplayID { get }
    var valid: Bool { get }
    var bounds: CGRect { get }
    var pixelWidth: Int? { get }
    func invalidate()
}

extension StageDisplayBacking {
    var pixelWidth: Int? { nil }
}

extension SPOVirtualDisplay: StageDisplayBacking {
    var pixelWidth: Int? { valid ? CGDisplayPixelsWide(displayID) : nil }
}

/// The agent's screen: a headless virtual display the user never sees.
///
/// Why a display and not a Space — a window on an inactive Space is officially "not visible"
/// and macOS tells apps to stop drawing (and Electron AX trees go stale). A window on a second
/// display's active Space renders normally, so every standard API just works. See FINDINGS.md §2.
///
/// Creation refuses an unsafe or unreadable display graph. Lifecycle waits are bounded and
/// permanently stop subsequent mutations after a timeout; a stuck OS call is not cancelled.
/// A stage may be read by capture tasks while lifecycle work runs elsewhere. Immutable metadata
/// is freely shared; every access to the mutable backing display and invalidation flags is
/// serialized by `stateLock`.
public final class Stage: @unchecked Sendable {

    /// Public CoreGraphics state that adding or removing a SpaceO display must not change for
    /// any of the user's existing monitors. Capture it around each lifecycle mutation instead
    /// of assuming WindowServer preserved topology, mirroring, scale, rotation, or refresh.
    struct UserDisplayConfiguration: Equatable, Sendable {
        struct Display: Equatable, Sendable {
            let id: CGDirectDisplayID
            let active: Bool
            let main: Bool
            let bounds: CGRect
            let pixelWidth: Int
            let pixelHeight: Int
            let rotation: Double
            let mirroredTo: CGDirectDisplayID
            let modeWidth: Int
            let modeHeight: Int
            let modePixelWidth: Int
            let modePixelHeight: Int
            let refreshRate: Double
        }

        let displays: [Display]

        func changes(from expected: UserDisplayConfiguration) -> [String] {
            let expectedByID = Dictionary(
                uniqueKeysWithValues: expected.displays.map { ($0.id, $0) })
            let actualByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
            var changes: [String] = []
            let expectedIDs = Set(expectedByID.keys)
            let actualIDs = Set(actualByID.keys)
            let missing = expectedIDs.subtracting(actualIDs).sorted()
            let added = actualIDs.subtracting(expectedIDs).sorted()
            if !missing.isEmpty { changes.append("user display(s) went offline: \(missing)") }
            if !added.isEmpty { changes.append("user display(s) appeared: \(added)") }
            for id in expectedIDs.intersection(actualIDs).sorted() {
                guard let expectedDisplay = expectedByID[id],
                      let actualDisplay = actualByID[id],
                      expectedDisplay != actualDisplay else { continue }
                var fields: [String] = []
                if expectedDisplay.active != actualDisplay.active { fields.append("active state") }
                if expectedDisplay.main != actualDisplay.main { fields.append("main-display role") }
                if expectedDisplay.bounds != actualDisplay.bounds { fields.append("bounds") }
                if expectedDisplay.pixelWidth != actualDisplay.pixelWidth
                    || expectedDisplay.pixelHeight != actualDisplay.pixelHeight {
                    fields.append("pixel dimensions")
                }
                if expectedDisplay.rotation != actualDisplay.rotation { fields.append("rotation") }
                if expectedDisplay.mirroredTo != actualDisplay.mirroredTo {
                    fields.append("mirroring")
                }
                // CoreGraphics republishes a synthetic mode for an inactive mirror follower
                // whenever another display attaches. The active mirror master, its geometry,
                // and the follower's mirror relationship are the effective user settings; the
                // follower's transient independent mode is neither selected nor visible.
                let stableInactiveMirrorFollower = !expectedDisplay.active
                    && !actualDisplay.active
                    && expectedDisplay.mirroredTo != 0
                    && expectedDisplay.mirroredTo == actualDisplay.mirroredTo
                if !stableInactiveMirrorFollower {
                    if expectedDisplay.modeWidth != actualDisplay.modeWidth
                        || expectedDisplay.modeHeight != actualDisplay.modeHeight
                        || expectedDisplay.modePixelWidth != actualDisplay.modePixelWidth
                        || expectedDisplay.modePixelHeight != actualDisplay.modePixelHeight {
                        fields.append("display mode")
                    }
                    if expectedDisplay.refreshRate != actualDisplay.refreshRate {
                        fields.append("refresh rate")
                    }
                }
                if !fields.isEmpty {
                    changes.append("user display \(id) changed \(fields.joined(separator: ", "))")
                }
            }
            return changes
        }
    }

    /// Process-wide display ownership is mutable, but never accessed without this holder's lock.
    private final class OwnershipState: @unchecked Sendable {
        let lock = NSLock()
        var displayIDs: Set<CGDirectDisplayID> = []
    }

    /// Teardown owns the display reference after `Stage.deinit` begins. The wrapper makes that
    /// one-way transfer explicit: the serial lifecycle queue is its only remaining accessor.
    private final class PendingInvalidation: @unchecked Sendable {
        let display: any StageDisplayBacking
        let displayID: CGDirectDisplayID
        let onlineDisplayIDs: @Sendable () throws -> [CGDirectDisplayID]

        init(
            display: any StageDisplayBacking,
            displayID: CGDirectDisplayID,
            onlineDisplayIDs: @escaping @Sendable () throws -> [CGDirectDisplayID]
        ) {
            self.display = display
            self.displayID = displayID
            self.onlineDisplayIDs = onlineDisplayIDs
        }
    }

    private static let lease = DisplayLifecycleLease()
    private static let lifecycle = DisplayLifecycleCoordinator { reason in
        lease.trip(reason)
        DaemonLog.shared.event("display.safety.tripped", ["reason": reason])
    }
    private static let ownership = OwnershipState()

    // Deliberate incident reproduction requires a separately compiled qualification binary
    // AND an explicit reserved-host invocation. Shipping builds cannot enable this with env.
    static var qualifiesPanicConfiguration: Bool {
        #if SPACEO_DISPLAY_QUALIFICATION
        return ProcessInfo.processInfo.environment["SPACEO_LIVE_TESTS"] == "1"
            && ProcessInfo.processInfo.environment["SPACEO_QUALIFY_PANIC_CONFIGURATION"] == "1"
        #else
        return false
        #endif
    }

    /// XCTest's first recorded live failure also stops focused reruns through the shared latch.
    static func stopLiveDisplayWork() {
        lifecycle.trip("live integration test failed; do not continue or automatically rerun")
    }
    private let backing: any StageDisplayBacking
    private let onlineDisplayIDsProvider: @Sendable () throws -> [CGDirectDisplayID]
    private let configurationProvider: @Sendable () throws -> UserDisplayConfiguration?
    private let coordinator: DisplayLifecycleCoordinator
    private let usesLiveLease: Bool
    let retirementSpaces: [UInt64]
    private let stateLock = NSLock()
    private var didInvalidate = false
    private var invalidatedDisplayID: CGDirectDisplayID = 0
    public var backingScale: Double? {
        stateLock.withLock {
            guard !didInvalidate, coordinator.failureReason == nil else { return nil }
            return try? coordinator.perform(timeout: 1, retaining: backing) { [backing] _ in
                let width = backing.bounds.width
                guard let pixels = backing.pixelWidth, pixels > 0, width > 0 else { return nil }
                return Double(pixels) / width
            }
        }
    }
    public let identity = UUID()
    public let name: String
    public let requestedSize: CGSize

    /// The display this stage owns — or, once teardown has begun, the one it last owned.
    ///
    /// The shim drops its display id the instant `invalidate()` is called, long before the
    /// WindowServer has actually detached the framebuffer. Reading straight through to it after
    /// a *failed* retirement therefore reports `0`, which names no display an operator can act
    /// on and is indistinguishable from "already gone" to every retirement check. Keep reporting
    /// the id we owned; `isValid` is the separate question of whether it is still ours.
    public var displayID: CGDirectDisplayID {
        stateLock.withLock {
            didInvalidate ? invalidatedDisplayID : backing.displayID
        }
    }
    public var isValid: Bool {
        stateLock.withLock { !didInvalidate && coordinator.failureReason == nil && backing.valid }
    }
    var hasLifecycleFailure: Bool { coordinator.failureReason != nil }
    /// Global-coordinate rect of the agent's screen.
    public var bounds: CGRect {
        stateLock.withLock {
            guard !didInvalidate, coordinator.failureReason == nil else { return .zero }
            return (try? coordinator.perform(timeout: 1, retaining: backing) { [backing] _ in
                backing.bounds
            }) ?? .zero
        }
    }

    public init(name: String, width: UInt32 = 1920, height: UInt32 = 1080, hiDPI: Bool = true) throws {
        guard width > 0, height > 0 else {
            throw SpaceOError.badRequest("display width and height must be positive")
        }
        guard SPOCapabilityAvailable(.virtualDisplay) else {
            throw SpaceOError.stageCreationFailed(
                SPOCapabilityUnavailableReason(.virtualDisplay)
                    ?? "virtual-display is unavailable on this host"
            )
        }
        try Self.lease.acquire()
        let published: (SPOVirtualDisplay, [UInt64]) = try Self.lifecycle.perform(timeout: 10) { operation in
            let userConfigurationBefore: UserDisplayConfiguration
            let online: [CGDirectDisplayID]
            do {
                userConfigurationBefore = try Self.checkedUserDisplayConfiguration()
                online = try Self.checkedOnlineDisplayIDs()
            } catch {
                Self.lifecycle.trip("pre-creation display inventory failed")
                throw error
            }
            if let failure = Self.admissionFailure(
                configuration: userConfigurationBefore,
                foreignDisplayIDs: online.filter { Self.isSpaceODisplay($0) }
                    .filter { id in !Self.ownership.lock.withLock { Self.ownership.displayIDs.contains(id) } },
                qualifyPanicConfiguration: Self.qualifiesPanicConfiguration) {
                throw SpaceOError.stageCreationFailed(failure)
            }
            try operation.check()
            try Self.lease.begin(creation: true)
            var completed = false
            defer {
                if !completed { Self.lifecycle.trip("display creation did not complete safely") }
            }
            try operation.check()
            guard let display = SPOVirtualDisplay(name: name, width: width,
                                                  height: height, hiDPI: hiDPI) else {
                Self.lifecycle.trip("CGVirtualDisplay creation failed; attachment state is unknown")
                throw SpaceOError.stageCreationFailed("CGVirtualDisplay refused \(width)x\(height)")
            }
            operation.retain(display)
            try operation.check()

            let deadline = ContinuousClock.now + .seconds(3)
            var publicationFailure: String?
            repeat {
                try operation.check()
                publicationFailure = try Self.publicationFailure(
                    for: display, preserving: userConfigurationBefore)
                if publicationFailure == nil { break }
                usleep(200_000)
            } while ContinuousClock.now < deadline
            guard publicationFailure == nil else {
                // A known unhealthy publication is one failed lifecycle, never an automatic
                // create/destroy/retry loop. The same deadline/circuit also bounds rollback.
                _ = try Self.invalidateUnpublished(display, operation: operation)
                Self.lifecycle.trip(publicationFailure ?? "unsafe display publication")
                throw SpaceOError.stageCreationFailed(publicationFailure ?? "unsafe display publication")
            }
            try operation.check()
            let spaces = (SPOSpacesForDisplay(display.displayID) ?? []).map { $0.uint64Value }
            try operation.check()
            try Self.lease.finish()
            Self.recordOwned(display.displayID)
            completed = true
            return (display, spaces)
        }
        self.backing = published.0
        self.retirementSpaces = published.1
        self.onlineDisplayIDsProvider = { try Self.checkedOnlineDisplayIDs() }
        self.configurationProvider = { try Self.checkedUserDisplayConfiguration() }
        self.coordinator = Self.lifecycle
        self.usesLiveLease = true
        self.name = name
        self.requestedSize = CGSize(width: Int(width), height: Int(height))
    }

    init(
        testingBacking: any StageDisplayBacking,
        name: String = "test display",
        onlineDisplayIDs: @escaping @Sendable () throws -> [CGDirectDisplayID],
        coordinator: DisplayLifecycleCoordinator = DisplayLifecycleCoordinator()
    ) {
        backing = testingBacking
        onlineDisplayIDsProvider = onlineDisplayIDs
        configurationProvider = { nil } // Safe tests never query WindowServer.
        self.coordinator = coordinator
        usesLiveLease = false
        retirementSpaces = []
        self.name = name
        requestedSize = testingBacking.bounds.size
        Self.recordOwned(testingBacking.displayID)
    }

    /// Managed Space ids belonging to this display. A healthy stage owns exactly one, and it is
    /// always that display's current Space — which is what keeps agent windows composited.
    public var spaces: [UInt64] {
        guard usesLiveLease, isValid else { return [] }
        let id = displayID
        return (try? coordinator.perform(timeout: 1, retaining: backing) { _ in
            (SPOSpacesForDisplay(id) ?? []).map { $0.uint64Value }
        }) ?? []
    }

    /// True when the stage has its own Space, distinct from the user's active one.
    public var hasOwnSpace: Bool {
        let mine = Set(spaces)
        return !mine.isEmpty && !mine.contains(SPOActiveSpace())
    }

    /// Does this rect sit on the agent's screen?
    public func contains(_ rect: CGRect) -> Bool {
        bounds.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// A sensible default frame for a window placed here: inset from the edges.
    public func defaultWindowFrame(inset: CGFloat = 60) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }

    /// Drop the display.
    ///
    /// WindowServer removes a virtual display asynchronously, so by default we wait for it to
    /// actually leave the online list. Merely becoming inactive is not teardown: an attached
    /// phantom can still poison the next display-graph change.
    @discardableResult
    public func invalidate(waitingForRemoval timeout: TimeInterval = 10.0) -> Bool {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 30) : 10
        let id = stateLock.withLock { () -> CGDirectDisplayID in
            if !didInvalidate {
                didInvalidate = true
                invalidatedDisplayID = backing.displayID
            }
            return invalidatedDisplayID
        }
        let pending = PendingInvalidation(
            display: backing, displayID: id, onlineDisplayIDs: onlineDisplayIDsProvider)
        do {
            return try coordinator.perform(timeout: max(safeTimeout, 0.1), retaining: backing) {
                [configurationProvider, usesLiveLease, coordinator] operation in
                try Self.retire(pending, timeout: safeTimeout, operation: operation,
                                configuration: configurationProvider,
                                liveLease: usesLiveLease, coordinator: coordinator)
            }
        } catch {
            // Unknown is not removed. Keep the original id and refuse reuse/creation.
            coordinator.trip("display \(id) retirement was not confirmed")
            return false
        }
    }

    private static func retire(
        _ pending: PendingInvalidation, timeout: TimeInterval,
        operation: DisplayLifecycleCoordinator.Operation,
        configuration: () throws -> UserDisplayConfiguration?,
        liveLease: Bool, coordinator: DisplayLifecycleCoordinator
    ) throws -> Bool {
        let before = try configuration()
        try operation.check()
        if liveLease { try lease.begin(creation: false) }
        try operation.check()
        pending.display.invalidate()
        let deadline = ContinuousClock.now + .seconds(timeout)
        repeat {
            try operation.check()
            let retired = displayIsRetired(
                pending.displayID, onlineDisplayIDs: try pending.onlineDisplayIDs())
            if retired {
                if let before, let after = try configuration() {
                    let changes = after.changes(from: before)
                    if !changes.isEmpty {
                        if ContinuousClock.now < deadline { usleep(200_000); continue }
                        coordinator.trip("user display configuration changed during retirement")
                        return false
                    }
                }
                try operation.check()
                if liveLease { try lease.finish() }
                recordReleased(pending.displayID)
                return true
            }
            if timeout == 0 {
                if liveLease { coordinator.trip("display removal was not confirmed") }
                return false
            }
            usleep(200_000)
        } while ContinuousClock.now < deadline
        coordinator.trip("display \(pending.displayID) removal was not confirmed")
        return false
    }

    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard count == 0
                || CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard count == 0
                || CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    static func isSpaceODisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x1AF2 && CGDisplayModelNumber(id) == 0x0001
    }

    static func checkedOnlineDisplayIDs() throws -> [CGDirectDisplayID] {
        try checkedDisplayIDs(active: false)
    }

    private static func checkedDisplayIDs(active: Bool) throws -> [CGDirectDisplayID] {
        // One bounded allocation and one call: failure/overflow is unknown, never an empty graph.
        var ids = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        let result = active ? CGGetActiveDisplayList(128, &ids, &count)
            : CGGetOnlineDisplayList(128, &ids, &count)
        guard result == .success, count > 0, count < 128 else {
            throw SpaceOError.stageCreationFailed("display inventory is unavailable or exceeds its bound")
        }
        return Array(ids.prefix(Int(count)))
    }

    /// Diagnostics preserve the existing nonthrowing API; lifecycle uses the checked variant.
    static func userDisplayConfiguration() -> UserDisplayConfiguration {
        (try? checkedUserDisplayConfiguration()) ?? UserDisplayConfiguration(displays: [])
    }

    static func checkedUserDisplayConfiguration() throws -> UserDisplayConfiguration {
        let active = Set(try checkedDisplayIDs(active: true))
        let main = CGMainDisplayID()
        let ids = try checkedOnlineDisplayIDs().filter { !isSpaceODisplay($0) }
        let displays = ids.sorted().map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return UserDisplayConfiguration.Display(
                id: id,
                active: active.contains(id),
                main: id == main,
                bounds: CGDisplayBounds(id),
                pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id),
                rotation: CGDisplayRotation(id),
                mirroredTo: CGDisplayMirrorsDisplay(id),
                modeWidth: mode?.width ?? 0,
                modeHeight: mode?.height ?? 0,
                modePixelWidth: mode?.pixelWidth ?? 0,
                modePixelHeight: mode?.pixelHeight ?? 0,
                refreshRate: mode?.refreshRate ?? 0)
        }
        return UserDisplayConfiguration(displays: displays)
    }

    /// Pure publication checks live behind one helper so unsafe overlap and configuration-drift
    /// scenarios can be unit tested without creating a real virtual monitor.
    static func publicationFailure(
        displayID: CGDirectDisplayID,
        bounds: CGRect,
        activeDisplayIDs: Set<CGDirectDisplayID>,
        spaces: [UInt64],
        activeSpace: UInt64,
        otherDisplayBounds: [(CGDirectDisplayID, CGRect)],
        userConfigurationBefore: UserDisplayConfiguration,
        userConfigurationAfter: UserDisplayConfiguration
    ) -> String? {
        guard displayID != 0 else { return "the virtual display has no display id" }
        guard !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            return "the virtual display has no finite positive bounds"
        }
        guard activeDisplayIDs.contains(displayID) else {
            return "the virtual display is online but inactive"
        }
        guard !spaces.isEmpty else { return "the virtual display has no managed Space" }
        guard activeSpace == 0 || !spaces.contains(activeSpace) else {
            return "the virtual display shares the user's active Space"
        }
        for (otherID, otherBounds) in otherDisplayBounds {
            let overlap = bounds.intersection(otherBounds)
            if !overlap.isNull && overlap.width > 0 && overlap.height > 0 {
                return "the virtual display overlaps display \(otherID)"
            }
        }
        let changes = userConfigurationAfter.changes(from: userConfigurationBefore)
        guard changes.isEmpty else { return changes.joined(separator: "; ") }
        return nil
    }

    private static func publicationFailure(
        for display: SPOVirtualDisplay,
        preserving userConfigurationBefore: UserDisplayConfiguration
    ) throws -> String? {
        let id = display.displayID
        let spaces = (SPOSpacesForDisplay(id) ?? []).map { $0.uint64Value }
        let otherBounds = try checkedOnlineDisplayIDs()
            .filter { $0 != id }
            .map { ($0, CGDisplayBounds($0)) }
        return publicationFailure(
            displayID: id,
            bounds: display.bounds,
            activeDisplayIDs: Set(try checkedDisplayIDs(active: true)),
            spaces: spaces,
            activeSpace: SPOActiveSpace(),
            otherDisplayBounds: otherBounds,
            userConfigurationBefore: userConfigurationBefore,
            userConfigurationAfter: try checkedUserDisplayConfiguration())
    }

    /// Conservative admission, not a claim that any refresh rate or topology is proven safe.
    static func admissionFailure(
        configuration: UserDisplayConfiguration, foreignDisplayIDs: [CGDirectDisplayID],
        qualifyPanicConfiguration: Bool = false
    ) -> String? {
        guard !configuration.displays.isEmpty,
              configuration.displays.contains(where: { $0.active }),
              configuration.displays.allSatisfy({
                  ($0.active || (qualifyPanicConfiguration && $0.mirroredTo != 0))
                     && $0.bounds.width.isFinite && $0.bounds.height.isFinite
                     && $0.bounds.origin.x.isFinite && $0.bounds.origin.y.isFinite
                     && $0.bounds.width > 0 && $0.bounds.height > 0
                     && $0.modeWidth > 0 && $0.modeHeight > 0
              }) else { return "user display configuration is missing, inactive, or unreadable" }
        guard qualifyPanicConfiguration || configuration.displays.allSatisfy({ $0.mirroredTo == 0 }) else {
            return "virtual displays are disabled while user displays are mirrored"
        }
        guard qualifyPanicConfiguration || configuration.displays.allSatisfy({
            $0.refreshRate.isFinite && $0.refreshRate > 0 && $0.refreshRate <= 120
        }) else {
            return "virtual displays require known user display refresh rates no higher than 120 Hz"
        }
        guard foreignDisplayIDs.isEmpty else {
            return "unowned SpaceO displays are still online; refusing another attachment"
        }
        return nil
    }

    /// Active displays that belong to the user's existing display graph, not SpaceO.
    public static func nonSpaceOActiveDisplayIDs() -> [CGDirectDisplayID] {
        activeDisplayIDs().filter { !isSpaceODisplay($0) }
    }

    /// A real, currently active display to which cursor/window recovery may safely return.
    /// `CGMainDisplayID()` is not sufficient: during the lockout it referred to a SpaceO
    /// virtual display while both physical displays were inactive.
    public static func preferredActiveUserDisplayBounds() -> CGRect? {
        let active = nonSpaceOActiveDisplayIDs()
        guard !active.isEmpty else { return nil }
        let main = CGMainDisplayID()
        let selected = active.contains(main) ? main : active[0]
        let bounds = CGDisplayBounds(selected)
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        return bounds
    }

    /// User-facing/third-party displays that are online, even if WindowServer made them inactive.
    public static func nonSpaceOOnlineDisplayIDs() -> [CGDirectDisplayID] {
        onlineDisplayIDs().filter { !isSpaceODisplay($0) }
    }

    /// Mirroring is a known unsafe configuration for CGVirtualDisplay on the verification host.
    public static func mirroredNonSpaceODisplayIDs() -> [CGDirectDisplayID] {
        nonSpaceOOnlineDisplayIDs().filter { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// Online displays created with SpaceO's vendor/model identifiers, including inactive
    /// displays that survived their owner unexpectedly.
    public static func spaceODisplayIDs() -> [CGDirectDisplayID] {
        onlineDisplayIDs().filter(isSpaceODisplay)
    }

    /// SpaceO displays attached to the login session but not owned by this process.
    public static func orphanedSpaceODisplayIDs() -> [CGDirectDisplayID] {
        let owned = ownership.lock.withLock { ownership.displayIDs }
        return spaceODisplayIDs().filter { !owned.contains($0) }
    }

    private static func recordOwned(_ id: CGDirectDisplayID) {
        guard id != 0 else { return }
        _ = ownership.lock.withLock { ownership.displayIDs.insert(id) }
    }

    private static func recordReleased(_ id: CGDirectDisplayID) {
        _ = ownership.lock.withLock { ownership.displayIDs.remove(id) }
    }

    static func displayIsRetired(
        _ id: CGDirectDisplayID,
        onlineDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        id == 0 || !onlineDisplayIDs.contains(id)
    }

    @discardableResult
    private static func invalidateUnpublished(
        _ display: any StageDisplayBacking, operation: DisplayLifecycleCoordinator.Operation
    ) throws -> Bool {
        try operation.check()
        let id = display.displayID
        display.invalidate()
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            try operation.check()
            if displayIsRetired(id, onlineDisplayIDs: try checkedOnlineDisplayIDs()) { return true }
            usleep(200_000)
        } while ContinuousClock.now < deadline
        return false
    }

    deinit {
        let pending = stateLock.withLock { () -> PendingInvalidation? in
            guard !didInvalidate else { return nil }
            didInvalidate = true
            invalidatedDisplayID = backing.displayID
            return PendingInvalidation(
                display: backing, displayID: invalidatedDisplayID,
                onlineDisplayIDs: onlineDisplayIDsProvider)
        }
        guard let pending else { return }
        let coordinator = coordinator
        let configuration = configurationProvider
        let liveLease = usesLiveLease
        // Never query or mutate the display server synchronously from deinit.
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try coordinator.perform(timeout: 10, retaining: pending.display) { operation in
                    try Self.retire(pending, timeout: 10, operation: operation,
                                    configuration: configuration, liveLease: liveLease,
                                    coordinator: coordinator)
                }
            } catch { coordinator.trip("fallback display retirement was not confirmed") }
        }
    }
}
