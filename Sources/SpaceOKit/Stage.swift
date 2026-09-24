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

/// Serializes display reconfiguration.
///
/// Attaching and retiring several virtual framebuffers in quick succession can overrun the
/// WindowServer/display pipeline on active mirrored or high-refresh setups. This coordinator is
/// process-wide because separate pools still mutate the same login-session display graph.
private final class DisplayLifecycleCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "spaceo.display-lifecycle")

    func perform<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync { try body() }
    }

    func enqueue(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }
}

/// The agent's screen: a headless virtual display the user never sees.
///
/// Why a display and not a Space — a window on an inactive Space is officially "not visible"
/// and macOS tells apps to stop drawing (and Electron AX trees go stale). A window on a second
/// display's active Space renders normally, so every standard API just works. See FINDINGS.md §2.
///
/// Normal teardown explicitly waits for the display to disappear. Display-graph state — mirroring,
/// ownerless SpaceO displays, physical-display activity, overlap — is inventoried for diagnostics
/// but never refuses creation.
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
        let onlineDisplayIDs: @Sendable () -> [CGDirectDisplayID]

        init(
            display: any StageDisplayBacking,
            displayID: CGDirectDisplayID,
            onlineDisplayIDs: @escaping @Sendable () -> [CGDirectDisplayID]
        ) {
            self.display = display
            self.displayID = displayID
            self.onlineDisplayIDs = onlineDisplayIDs
        }
    }

    private static let lifecycle = DisplayLifecycleCoordinator()
    private static let ownership = OwnershipState()
    private let backing: any StageDisplayBacking
    private let onlineDisplayIDsProvider: @Sendable () -> [CGDirectDisplayID]
    private let stateLock = NSLock()
    private var didInvalidate = false
    private var invalidatedDisplayID: CGDirectDisplayID = 0
    public var backingScale: Double? {
        stateLock.withLock {
            guard let pixels = backing.pixelWidth, pixels > 0, backing.bounds.width > 0 else { return nil }
            return Double(pixels) / backing.bounds.width
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
            let live = backing.displayID
            return live != 0 ? live : invalidatedDisplayID
        }
    }
    public var isValid: Bool {
        stateLock.withLock { backing.valid }
    }
    /// Global-coordinate rect of the agent's screen.
    public var bounds: CGRect {
        stateLock.withLock { backing.bounds }
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
        let display: SPOVirtualDisplay = try Self.lifecycle.perform {
            let userConfigurationBefore = Self.userDisplayConfiguration()
            guard let display = SPOVirtualDisplay(name: name, width: width,
                                                  height: height, hiDPI: hiDPI) else {
                throw SpaceOError.stageCreationFailed(
                    "CGVirtualDisplay refused \(width)x\(height)")
            }

            // Do not let the next lifecycle operation begin while this one is only partially
            // published. Bounds alone are insufficient: the macOS 27 failure mode produced a
            // nonzero, online display that was inactive, overlapped the user's monitor, and had
            // no managed Space. No app may launch until all of those properties are healthy and
            // every pre-existing monitor still has its exact public configuration.
            let deadline = Date().addingTimeInterval(3.0)
            var publicationFailure: String?
            repeat {
                publicationFailure = Self.publicationFailure(
                    for: display,
                    preserving: userConfigurationBefore)
                if publicationFailure == nil { break }
                usleep(20_000)
            } while Date() < deadline
            guard publicationFailure == nil else {
                let unsafeDisplayID = display.displayID
                Self.invalidateUnpublished(display)
                let restorationChanges = Self.userDisplayConfiguration()
                    .changes(from: userConfigurationBefore)
                let restoration = restorationChanges.isEmpty
                    ? "user display configuration was preserved"
                    : restorationChanges.joined(separator: "; ")
                throw SpaceOError.stageCreationFailed(
                    "display \(unsafeDisplayID) was not safe to use: "
                        + (publicationFailure ?? "unknown publication failure")
                        + "; \(restoration)")
            }

            Self.recordOwned(display.displayID)
            return display
        }
        self.backing = display
        self.onlineDisplayIDsProvider = { Self.onlineDisplayIDs() }
        self.name = name
        self.requestedSize = CGSize(width: Int(width), height: Int(height))
    }

    init(
        testingBacking: any StageDisplayBacking,
        name: String = "test display",
        onlineDisplayIDs: @escaping @Sendable () -> [CGDirectDisplayID]
    ) {
        backing = testingBacking
        onlineDisplayIDsProvider = onlineDisplayIDs
        self.name = name
        requestedSize = testingBacking.bounds.size
        Self.recordOwned(testingBacking.displayID)
    }

    /// Managed Space ids belonging to this display. A healthy stage owns exactly one, and it is
    /// always that display's current Space — which is what keeps agent windows composited.
    public var spaces: [UInt64] {
        (SPOSpacesForDisplay(displayID) ?? []).map { $0.uint64Value }
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
        return stateLock.withLock {
            let id: CGDirectDisplayID
            if didInvalidate {
                id = invalidatedDisplayID
            } else {
                didInvalidate = true
                id = backing.displayID
                invalidatedDisplayID = id
            }
            return Self.lifecycle.perform {
                let userConfigurationBefore = Self.userDisplayConfiguration()
                // Repeating invalidation is intentional: a retained failed teardown must be able
                // to ask the backing object to drop its display again on the next cleanup pass.
                backing.invalidate()
                guard id != 0 else {
                    Self.recordReleased(id)
                    return true
                }
                guard safeTimeout > 0 else {
                    let retired = Self.displayIsRetired(
                        id,
                        onlineDisplayIDs: onlineDisplayIDsProvider())
                    if retired { Self.recordReleased(id) }
                    if retired {
                        Self.recordUserDisplayChanges(
                            after: "retiring display \(id)",
                            expected: userConfigurationBefore)
                    }
                    return retired
                }

                // The display's lifecycle runs on a private queue inside the shim, so a plain
                // sleep is sufficient here — no main run loop required from the caller.
                let deadline = Date().addingTimeInterval(safeTimeout)
                while Date() < deadline {
                    if Self.displayIsRetired(
                        id,
                        onlineDisplayIDs: onlineDisplayIDsProvider()) {
                        // Detaching a monitor can briefly republish the physical graph. Give the
                        // same bounded lifecycle window a chance to restore the exact pre-detach
                        // user configuration before recording a diagnostic failure.
                        if Self.userDisplayConfiguration() == userConfigurationBefore {
                            Self.recordReleased(id)
                            return true
                        }
                    }
                    usleep(50_000)
                }
                let retired = Self.displayIsRetired(
                    id,
                    onlineDisplayIDs: onlineDisplayIDsProvider())
                if retired {
                    Self.recordReleased(id)
                    Self.recordUserDisplayChanges(
                        after: "retiring display \(id)",
                        expected: userConfigurationBefore)
                }
                return retired
            }
        }
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

    /// Exact public configuration of non-SpaceO displays in the current login session.
    static func userDisplayConfiguration() -> UserDisplayConfiguration {
        let active = Set(activeDisplayIDs())
        let main = CGMainDisplayID()
        let displays = nonSpaceOOnlineDisplayIDs().sorted().map { id in
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
    ) -> String? {
        let id = display.displayID
        let spaces = (SPOSpacesForDisplay(id) ?? []).map { $0.uint64Value }
        let otherBounds = onlineDisplayIDs()
            .filter { $0 != id }
            .map { ($0, CGDisplayBounds($0)) }
        return publicationFailure(
            displayID: id,
            bounds: display.bounds,
            activeDisplayIDs: Set(activeDisplayIDs()),
            spaces: spaces,
            activeSpace: SPOActiveSpace(),
            otherDisplayBounds: otherBounds,
            userConfigurationBefore: userConfigurationBefore,
            userConfigurationAfter: userDisplayConfiguration())
    }

    private static func recordUserDisplayChanges(
        after operation: String,
        expected: UserDisplayConfiguration
    ) {
        let changes = userDisplayConfiguration().changes(from: expected)
        guard !changes.isEmpty else { return }
        DaemonLog.shared.event("display.user-configuration.changed", [
            "operation": operation,
            "changes": changes.joined(separator: "; "),
        ])
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
    private static func invalidateUnpublished(_ display: any StageDisplayBacking) -> Bool {
        let id = display.displayID
        display.invalidate()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !displayIsRetired(id, onlineDisplayIDs: onlineDisplayIDs()) {
            usleep(50_000)
        }
        return displayIsRetired(id, onlineDisplayIDs: onlineDisplayIDs())
    }

    deinit {
        let pending = stateLock.withLock { () -> PendingInvalidation? in
            guard !didInvalidate else { return nil }
            didInvalidate = true
            invalidatedDisplayID = backing.displayID
            return PendingInvalidation(
                display: backing,
                displayID: backing.displayID,
                onlineDisplayIDs: onlineDisplayIDsProvider)
        }
        guard let pending else { return }
        // Do not block deinit, but still serialize the fallback teardown with every other
        // display graph change.
        Self.lifecycle.enqueue {
            pending.display.invalidate()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline,
                  !Stage.displayIsRetired(
                    pending.displayID,
                    onlineDisplayIDs: pending.onlineDisplayIDs()) {
                usleep(50_000)
            }
            if Stage.displayIsRetired(
                pending.displayID,
                onlineDisplayIDs: pending.onlineDisplayIDs()) {
                Stage.recordReleased(pending.displayID)
            }
        }
    }
}
