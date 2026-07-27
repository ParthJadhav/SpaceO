import Foundation
import CoreGraphics

/// Hands out tiles on shared agent displays, and creates a new display only when the existing
/// ones are full.
///
/// A virtual display costs the WindowServer a full framebuffer to composite, so one display per
/// agent does not scale. The pool packs `sessionsPerDisplay` sessions onto each display and
/// normally retires a display once its last tenant leaves. The daemon may retain an empty one
/// for a short grace period so rapid session churn reuses a stable framebuffer.
public final class DisplayPool {

    /// A tile reservation. The frame is derived from the stage's live bounds rather than
    /// cached, so it stays correct if the display arrangement shifts underneath us.
    public struct Slot {
        public let stage: Stage
        public let index: Int
        public let capacity: Int

        public var frame: CGRect {
            TileLayout.rect(in: stage.bounds, capacity: capacity, index: index) ?? stage.bounds
        }
        /// True when this slot is the display's only tenant, i.e. it has the screen to itself.
        public var isExclusive: Bool { capacity == 1 }
    }

    private final class Occupancy {
        let stage: Stage
        let capacity: Int
        var taken: Set<Int> = []
        init(stage: Stage, capacity: Int) { self.stage = stage; self.capacity = capacity }
        var isFull: Bool { taken.count >= capacity }
        var isEmpty: Bool { taken.isEmpty }
        var free: Int? { (0..<capacity).first { !taken.contains($0) } }
    }

    private var displays: [Occupancy] = []
    private var nextDisplayNumber = 0

    /// How many sessions share one display. Changing it affects displays created afterwards;
    /// existing displays keep the capacity they were built with, because re-tiling underneath
    /// a running agent would move its windows out from under it.
    public private(set) var sessionsPerDisplay: Int
    public let displaySize: CGSize
    public let hiDPI: Bool

    public init(sessionsPerDisplay: Int = 1,
                displaySize: CGSize = CGSize(width: 1920, height: 1080),
                hiDPI: Bool = true) {
        self.sessionsPerDisplay = max(1, sessionsPerDisplay)
        self.displaySize = displaySize
        self.hiDPI = hiDPI
    }

    public var displayCount: Int { displays.count }
    public var sessionCount: Int { displays.reduce(0) { $0 + $1.taken.count } }
    public var stages: [Stage] { displays.map(\.stage) }

    /// Change the packing density for displays created from now on.
    public func setSessionsPerDisplay(_ value: Int) throws {
        guard value > 0 else {
            throw SpaceOError.badRequest("sessions per display must be a positive integer")
        }
        _ = try validatedDisplayDimensions()
        sessionsPerDisplay = value
    }

    // MARK: - Allocation

    /// Reserve a tile, reusing a display that has room before making a new one.
    public func allocate() throws -> Slot {
        if let existing = displays.first(where: { !$0.isFull }), let index = existing.free {
            existing.taken.insert(index)
            return Slot(stage: existing.stage, index: index, capacity: existing.capacity)
        }
        let dimensions = try validatedDisplayDimensions()

        nextDisplayNumber = nextDisplayNumber == Int.max ? 1 : nextDisplayNumber + 1
        let stage = try Stage(name: "SpaceO display \(nextDisplayNumber)",
                              width: dimensions.width,
                              height: dimensions.height,
                              hiDPI: hiDPI)
        AgentActivity.claim(spaces: stage.spaces)

        let occupancy = Occupancy(stage: stage, capacity: sessionsPerDisplay)
        occupancy.taken.insert(0)
        displays.append(occupancy)
        return Slot(stage: stage, index: 0, capacity: occupancy.capacity)
    }

    private func validatedDisplayDimensions() throws -> (width: UInt32, height: UInt32) {
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0,
              let width = UInt32(exactly: displaySize.width),
              let height = UInt32(exactly: displaySize.height) else {
            throw SpaceOError.badRequest(
                "display size must use positive whole pixels representable by UInt32")
        }
        return (width, height)
    }

    /// Give a tile back.
    ///
    /// With `retainEmpty`, an empty display remains fenced and available for immediate reuse
    /// until `retireEmptyDisplays()` or `releaseAll()` is called.
    @discardableResult
    public func release(_ slot: Slot, retainEmpty: Bool = false) -> Bool {
        guard let position = displays.firstIndex(where: { $0.stage === slot.stage }) else {
            return true
        }
        let occupancy = displays[position]
        occupancy.taken.remove(slot.index)
        guard occupancy.isEmpty else { return true }
        guard !retainEmpty else { return true }

        displays.remove(at: position)
        return retire(occupancy)
    }

    /// Retire empty displays, optionally preserving a small warm standby set.
    @discardableResult
    public func retireEmptyDisplays(keeping retainedCount: Int = 0) -> [CGDirectDisplayID] {
        let empty = displays.filter(\.isEmpty)
        let retiring = Array(empty.dropFirst(max(0, retainedCount)))
        let retiringStages = Set(retiring.map { ObjectIdentifier($0.stage) })
        displays.removeAll {
            retiringStages.contains(ObjectIdentifier($0.stage))
        }
        return retiring.compactMap { occupancy in
            let id = occupancy.stage.displayID
            return retire(occupancy) ? nil : id
        }
    }

    /// Tear down everything. Used on daemon shutdown.
    @discardableResult
    public func releaseAll() -> [CGDirectDisplayID] {
        let failed = displays.compactMap { occupancy -> CGDirectDisplayID? in
            let id = occupancy.stage.displayID
            return retire(occupancy) ? nil : id
        }
        displays.removeAll()
        return failed
    }

    private func retire(_ occupancy: Occupancy) -> Bool {
        AgentActivity.release(spaces: occupancy.stage.spaces)
        return occupancy.stage.invalidate()
    }

    // MARK: - Reporting

    public struct DisplayReport: Codable, Sendable {
        public var displayID: UInt32
        public var x: Double, y: Double, width: Double, height: Double
        public var capacity: Int
        public var used: Int
        public var spaces: [UInt64]
    }

    public func report() -> [DisplayReport] {
        displays.map { occupancy in
            let bounds = occupancy.stage.bounds
            return DisplayReport(displayID: occupancy.stage.displayID,
                                 x: bounds.origin.x, y: bounds.origin.y,
                                 width: bounds.width, height: bounds.height,
                                 capacity: occupancy.capacity,
                                 used: occupancy.taken.count,
                                 spaces: occupancy.stage.spaces)
        }
    }
}
