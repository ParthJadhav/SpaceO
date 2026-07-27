import Foundation
import CoreGraphics
import SpaceOPrivate

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

    func enqueue(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }
}

/// The agent's screen: a headless virtual display the user never sees.
///
/// Why a display and not a Space — a window on an inactive Space is officially "not visible"
/// and macOS tells apps to stop drawing (and Electron AX trees go stale). A window on a second
/// display's active Space renders normally, so every standard API just works. See FINDINGS.md §2.
///
/// Normal teardown explicitly waits for the display to disappear. Diagnostics still inventory
/// ownerless displays, but their presence does not block creating another stage.
public final class Stage {

    private static let lifecycle = DisplayLifecycleCoordinator()
    private static let ownershipLock = NSLock()
    private static var processOwnedDisplayIDs: Set<CGDirectDisplayID> = []
    private let backing: SPOVirtualDisplay
    private var didInvalidate = false
    private var invalidatedDisplayID: CGDirectDisplayID = 0
    public let name: String
    public let requestedSize: CGSize

    public var displayID: CGDirectDisplayID { backing.displayID }
    public var isValid: Bool { backing.valid }
    /// Global-coordinate rect of the agent's screen.
    public var bounds: CGRect { backing.bounds }

    public init(name: String, width: UInt32 = 1920, height: UInt32 = 1080, hiDPI: Bool = true) throws {
        guard width > 0, height > 0 else {
            throw SpaceOError.badRequest("display width and height must be positive")
        }
        let display: SPOVirtualDisplay = try Self.lifecycle.perform {
            guard let display = SPOVirtualDisplay(name: name, width: width,
                                                  height: height, hiDPI: hiDPI) else {
                throw SpaceOError.stageCreationFailed(
                    "CGVirtualDisplay refused \(width)x\(height)")
            }

            // Do not let the next lifecycle operation begin while this one is still only
            // partially published in the display graph.
            let deadline = Date().addingTimeInterval(2.0)
            while display.bounds == .zero && Date() < deadline {
                usleep(20_000)
            }
            guard display.bounds != .zero else {
                Self.invalidateUnpublished(display)
                throw SpaceOError.stageCreationFailed(
                    "display \(display.displayID) never reported bounds")
            }

            Self.recordOwned(display.displayID)
            return display
        }
        self.backing = display
        self.name = name
        self.requestedSize = CGSize(width: Int(width), height: Int(height))
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
        if didInvalidate {
            return Stage.displayIsRetired(
                invalidatedDisplayID, onlineDisplayIDs: Stage.onlineDisplayIDs())
        }
        didInvalidate = true
        let id = displayID
        invalidatedDisplayID = id
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 30) : 10
        return Self.lifecycle.perform {
            defer { Self.recordReleased(id) }
            backing.invalidate()
            guard id != 0 else { return true }
            guard safeTimeout > 0 else {
                return Self.displayIsRetired(id, onlineDisplayIDs: Self.onlineDisplayIDs())
            }

            // The display's lifecycle runs on a private queue inside the shim, so a plain sleep
            // is sufficient here — no main run loop required from the caller.
            let deadline = Date().addingTimeInterval(safeTimeout)
            while Date() < deadline {
                if Self.displayIsRetired(id, onlineDisplayIDs: Self.onlineDisplayIDs()) {
                    return true
                }
                usleep(50_000)
            }
            return false
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

    private static func isSpaceODisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x1AF2 && CGDisplayModelNumber(id) == 0x0001
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

    /// Mirroring is a known unsafe configuration for CGVirtualDisplay on the verification host:
    /// repeated attachment made every physical display inactive while virtual displays remained.
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
        let owned = ownershipLock.withLock { processOwnedDisplayIDs }
        return spaceODisplayIDs().filter { !owned.contains($0) }
    }

    private static func recordOwned(_ id: CGDirectDisplayID) {
        guard id != 0 else { return }
        _ = ownershipLock.withLock { processOwnedDisplayIDs.insert(id) }
    }

    private static func recordReleased(_ id: CGDirectDisplayID) {
        _ = ownershipLock.withLock { processOwnedDisplayIDs.remove(id) }
    }

    static func displayIsRetired(
        _ id: CGDirectDisplayID,
        onlineDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        id == 0 || !onlineDisplayIDs.contains(id)
    }

    private static func invalidateUnpublished(_ display: SPOVirtualDisplay) {
        let id = display.displayID
        display.invalidate()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !displayIsRetired(id, onlineDisplayIDs: onlineDisplayIDs()) {
            usleep(50_000)
        }
    }

    deinit {
        guard !didInvalidate else { return }
        // Do not block deinit, but still serialize the fallback teardown with every other
        // display graph change.
        let display = backing
        let id = display.displayID
        Self.lifecycle.enqueue {
            display.invalidate()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline,
                  !Stage.displayIsRetired(id, onlineDisplayIDs: Stage.onlineDisplayIDs()) {
                usleep(50_000)
            }
            Stage.recordReleased(id)
        }
    }
}
