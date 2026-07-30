import Foundation
import CoreGraphics
import SpaceOPrivate

protocol StageDisplayBacking: AnyObject {
    var displayID: CGDirectDisplayID { get }
    var valid: Bool { get }
    var bounds: CGRect { get }
    func invalidate()
}

extension SPOVirtualDisplay: StageDisplayBacking {}

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
/// Normal teardown explicitly waits for the display to disappear. Creation fails closed before
/// attachment, and rolls a new display back if attachment makes the user-display graph hazardous.
/// A stage may be read by capture tasks while lifecycle work runs elsewhere. Immutable metadata
/// is freely shared; every access to the mutable backing display and invalidation flags is
/// serialized by `stateLock`.
public final class Stage: @unchecked Sendable {

    struct DisplayGraphSnapshot: Equatable {
        var userOnlineDisplayIDs: [CGDirectDisplayID]
        var userActiveDisplayIDs: [CGDirectDisplayID]
        var mirroredUserDisplayIDs: [CGDirectDisplayID]
        var orphanedSpaceODisplayIDs: [CGDirectDisplayID]
        var boundsByDisplayID: [CGDirectDisplayID: CGRect]
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
    public let name: String
    public let requestedSize: CGSize

    public var displayID: CGDirectDisplayID {
        stateLock.withLock { backing.displayID }
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
            let before = Self.currentDisplayGraphSnapshot()
            let existingHazards = Self.displayCreationHazards(in: before)
            guard existingHazards.isEmpty else {
                throw SpaceOError.stageCreationFailed(
                    "display graph is hazardous; refusing to attach a virtual display: "
                    + existingHazards.joined(separator: "; "))
            }

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
            let after = Self.currentDisplayGraphSnapshot()
            let newHazards = Self.displayCreationHazards(in: after)
            guard newHazards.isEmpty else {
                let displayID = display.displayID
                let removed = Self.invalidateUnpublished(display)
                Self.recordReleased(displayID)
                throw SpaceOError.stageCreationFailed(
                    "display graph became hazardous after attaching display \(displayID): "
                    + newHazards.joined(separator: "; ")
                    + (removed
                       ? ". The new display was removed"
                       : ". Removal of the new display could not be confirmed; stop creating "
                         + "displays and run `spaceo doctor`"))
            }
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
                    return retired
                }

                // The display's lifecycle runs on a private queue inside the shim, so a plain
                // sleep is sufficient here — no main run loop required from the caller.
                let deadline = Date().addingTimeInterval(safeTimeout)
                while Date() < deadline {
                    if Self.displayIsRetired(
                        id,
                        onlineDisplayIDs: onlineDisplayIDsProvider()) {
                        Self.recordReleased(id)
                        return true
                    }
                    usleep(50_000)
                }
                return false
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

    /// Refuse every display graph implicated in the 2026-07-26 lockout, plus incomplete display
    /// inventory. This pure classifier is shared by the pre-attach and post-attach checks.
    static func displayCreationHazards(in snapshot: DisplayGraphSnapshot) -> [String] {
        let userOnline = Set(snapshot.userOnlineDisplayIDs)
        let userActive = Set(snapshot.userActiveDisplayIDs)
        var hazards: [String] = []

        if userOnline.isEmpty {
            hazards.append("no non-SpaceO user display is online")
        }
        if userActive.isEmpty {
            hazards.append("no non-SpaceO user display is active")
        }

        let inactive = userOnline.subtracting(userActive).sorted()
        if !inactive.isEmpty {
            hazards.append(
                "user display(s) online but inactive: \(idList(inactive))")
        }
        let activeButNotOnline = userActive.subtracting(userOnline).sorted()
        if !activeButNotOnline.isEmpty {
            hazards.append(
                "display inventory is inconsistent; active user display(s) are not online: "
                + idList(activeButNotOnline))
        }
        if !snapshot.mirroredUserDisplayIDs.isEmpty {
            hazards.append(
                "user display mirroring is enabled: "
                + idList(snapshot.mirroredUserDisplayIDs))
        }
        if !snapshot.orphanedSpaceODisplayIDs.isEmpty {
            hazards.append(
                "ownerless SpaceO display(s) are still attached: "
                + idList(snapshot.orphanedSpaceODisplayIDs))
        }

        let expectedBounds = userOnline.union(snapshot.orphanedSpaceODisplayIDs)
            .union(snapshot.boundsByDisplayID.keys)
        let missingBounds = expectedBounds.filter {
            guard let bounds = snapshot.boundsByDisplayID[$0] else { return true }
            return !bounds.origin.x.isFinite || !bounds.origin.y.isFinite
                || !bounds.width.isFinite || !bounds.height.isFinite
                || bounds.width <= 0 || bounds.height <= 0
        }.sorted()
        if !missingBounds.isEmpty {
            hazards.append(
                "display bounds are missing or invalid: \(idList(missingBounds))")
        }

        let bounded = snapshot.boundsByDisplayID
            .filter { !missingBounds.contains($0.key) }
            .sorted { $0.key < $1.key }
        var overlaps: [String] = []
        for firstIndex in bounded.indices {
            for secondIndex in bounded.index(after: firstIndex)..<bounded.endIndex {
                let first = bounded[firstIndex]
                let second = bounded[secondIndex]
                let intersection = first.value.intersection(second.value)
                if !intersection.isNull,
                   intersection.width > 0, intersection.height > 0 {
                    overlaps.append("\(first.key)-\(second.key)")
                }
            }
        }
        if !overlaps.isEmpty {
            hazards.append(
                "display framebuffers overlap (display id pairs \(overlaps.joined(separator: ", ")))")
        }
        return hazards
    }

    private static func currentDisplayGraphSnapshot() -> DisplayGraphSnapshot {
        let online = onlineDisplayIDs()
        let active = activeDisplayIDs()
        let userOnline = online.filter { !isSpaceODisplay($0) }
        let userActive = active.filter { !isSpaceODisplay($0) }
        let spaceO = online.filter(isSpaceODisplay)
        let owned = ownership.lock.withLock { ownership.displayIDs }
        var bounds: [CGDirectDisplayID: CGRect] = [:]
        for id in online {
            bounds[id] = CGDisplayBounds(id)
        }
        return DisplayGraphSnapshot(
            userOnlineDisplayIDs: userOnline.sorted(),
            userActiveDisplayIDs: userActive.sorted(),
            mirroredUserDisplayIDs:
                userOnline.filter { CGDisplayIsInMirrorSet($0) != 0 }.sorted(),
            orphanedSpaceODisplayIDs:
                spaceO.filter { !owned.contains($0) }.sorted(),
            boundsByDisplayID: bounds)
    }

    private static func idList(_ ids: some Sequence<CGDirectDisplayID>) -> String {
        ids.map(String.init).joined(separator: ", ")
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
