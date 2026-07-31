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
    public struct Slot: Sendable {
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
        /// Framebuffer area as *requested*, not as the display later reports it. Budget
        /// accounting must not depend on a WindowServer round trip that can fail or lag —
        /// the cost was incurred when we asked for the pixels.
        let pixels: Int
        var taken: Set<Int> = []
        init(stage: Stage, capacity: Int, pixels: Int) {
            self.stage = stage
            self.capacity = capacity
            self.pixels = pixels
        }
        var isFull: Bool { taken.count >= capacity }
        var isEmpty: Bool { taken.isEmpty }
        var free: Int? { (0..<capacity).first { !taken.contains($0) } }
    }

    /// How a `Stage` is built. Injectable so allocation behavior can be tested without asking the
    /// WindowServer for a real framebuffer.
    public typealias StageFactory = (_ name: String, _ width: UInt32, _ height: UInt32,
                                     _ hiDPI: Bool) throws -> Stage

    private var displays: [Occupancy] = []
    private var nextDisplayNumber = 0
    /// Creation timestamps inside the rate window, oldest first.
    private var recentCreations: [Date] = []
    private let stageFactory: StageFactory
    private let stageRetirer: @Sendable (Stage) -> Bool
    private let lock = NSLock()

    /// How many sessions share one display. Changing it affects displays created afterwards;
    /// existing displays keep the capacity they were built with, because re-tiling underneath
    /// a running agent would move its windows out from under it.
    public private(set) var sessionsPerDisplay: Int
    public let displaySize: CGSize
    public let hiDPI: Bool
    public let budget: ResourceBudget

    public init(sessionsPerDisplay: Int = 1,
                displaySize: CGSize = CGSize(width: 1920, height: 1080),
                hiDPI: Bool = true,
                budget: ResourceBudget = .fromEnvironment(),
                stageFactory: StageFactory? = nil) {
        self.sessionsPerDisplay = max(1, sessionsPerDisplay)
        self.displaySize = displaySize
        self.hiDPI = hiDPI
        self.budget = budget
        self.stageFactory = stageFactory ?? { name, width, height, hiDPI in
            try Stage(name: name, width: width, height: height, hiDPI: hiDPI)
        }
        self.stageRetirer = { $0.invalidate() }
    }

    init(sessionsPerDisplay: Int = 1,
         displaySize: CGSize = CGSize(width: 1920, height: 1080),
         hiDPI: Bool = true,
         budget: ResourceBudget = .fromEnvironment(),
         stageFactory: StageFactory? = nil,
         stageRetirer: @escaping @Sendable (Stage) -> Bool) {
        self.sessionsPerDisplay = max(1, sessionsPerDisplay)
        self.displaySize = displaySize
        self.hiDPI = hiDPI
        self.budget = budget
        self.stageFactory = stageFactory ?? { name, width, height, hiDPI in
            try Stage(name: name, width: width, height: height, hiDPI: hiDPI)
        }
        self.stageRetirer = stageRetirer
    }

    public var displayCount: Int { lock.withLock { displays.count } }
    public var sessionCount: Int { lock.withLock { displays.reduce(0) { $0 + $1.taken.count } } }
    public var stages: [Stage] { lock.withLock { displays.map(\.stage) } }

    /// Change the packing density for displays created from now on.
    public func setSessionsPerDisplay(_ value: Int) throws {
        guard value > 0 else {
            throw SpaceOError.badRequest("sessions per display must be a positive integer")
        }
        // Validate technical layout bounds before applying the new density.
        _ = try budget.validateDisplaySize(displaySize, capacity: value)
        lock.withLock { sessionsPerDisplay = value }
    }

    // MARK: - Allocation

    /// Reserve a tile, reusing a display that has room before making a new one.
    ///
    /// Allocation runs under one lock so concurrent callers receive distinct slots/displays.
    public func allocate() throws -> Slot {
        lock.lock()
        defer { lock.unlock() }

        if let existing = displays.first(where: { !$0.isFull }), let index = existing.free {
            try budget.admitSession(usage: usageLocked())
            existing.taken.insert(index)
            return Slot(stage: existing.stage, index: index, capacity: existing.capacity)
        }

        pruneCreationWindowLocked()
        let dimensions = try budget.validateDisplaySize(displaySize, capacity: sessionsPerDisplay)
        try budget.admitDisplay(size: displaySize,
                                capacity: sessionsPerDisplay,
                                usage: usageLocked())

        nextDisplayNumber = nextDisplayNumber == Int.max ? 1 : nextDisplayNumber + 1
        let stage = try stageFactory("SpaceO display \(nextDisplayNumber)",
                                     dimensions.width, dimensions.height, hiDPI)
        AgentActivity.claim(spaces: stage.spaces)
        recentCreations.append(Date())

        let occupancy = Occupancy(stage: stage,
                                  capacity: sessionsPerDisplay,
                                  pixels: Int(dimensions.width) * Int(dimensions.height))
        occupancy.taken.insert(0)
        displays.append(occupancy)
        return Slot(stage: stage, index: 0, capacity: occupancy.capacity)
    }

    // MARK: - Budget accounting

    /// What the pool is currently holding. Read by `pool` and `doctor`.
    public func usage() -> ResourceBudget.Usage {
        lock.withLock {
            pruneCreationWindowLocked()
            return usageLocked()
        }
    }

    private func usageLocked() -> ResourceBudget.Usage {
        let pixels = displays.reduce(0) { $0 + $1.pixels }
        return ResourceBudget.Usage(
            sessions: displays.reduce(0) { $0 + $1.taken.count },
            displays: displays.count,
            pixels: pixels,
            bytes: pixels * ResourceBudget.bytesPerPixel,
            creationsInLastMinute: recentCreations.count)
    }

    private func pruneCreationWindowLocked() {
        let cutoff = Date().addingTimeInterval(-60)
        recentCreations.removeAll { $0 < cutoff }
    }

    /// Give a tile back.
    ///
    /// With `retainEmpty`, an empty display remains fenced and available for immediate reuse
    /// until `retireEmptyDisplays()` or `releaseAll()` is called.
    @discardableResult
    public func release(_ slot: Slot, retainEmpty: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let position = displays.firstIndex(where: { $0.stage === slot.stage }) else {
            return true
        }
        let occupancy = displays[position]
        occupancy.taken.remove(slot.index)
        guard occupancy.isEmpty else { return true }
        guard !retainEmpty else { return true }

        guard retire(occupancy) else { return false }
        displays.remove(at: position)
        return true
    }

    /// Retire empty displays, optionally preserving a small warm standby set.
    @discardableResult
    public func retireEmptyDisplays(keeping retainedCount: Int = 0) -> [CGDirectDisplayID] {
        lock.lock()
        defer { lock.unlock() }
        let empty = displays.filter(\.isEmpty)
        let retiring = Array(empty.dropFirst(max(0, retainedCount)))
        let retiredStages = Set(retiring.compactMap { occupancy -> ObjectIdentifier? in
            retire(occupancy) ? ObjectIdentifier(occupancy.stage) : nil
        })
        displays.removeAll {
            retiredStages.contains(ObjectIdentifier($0.stage))
        }
        return retiring.compactMap {
            retiredStages.contains(ObjectIdentifier($0.stage))
                ? nil
                : $0.stage.displayID
        }
    }

    /// Tear down everything. Used on daemon shutdown.
    @discardableResult
    public func releaseAll() -> [CGDirectDisplayID] {
        lock.lock()
        defer { lock.unlock() }
        // Direct pool users call this after destroying their sessions and do not release every
        // slot individually. Mark those reservations empty, but retain any display whose actual
        // invalidation still fails so a later releaseAll can retry it.
        for occupancy in displays { occupancy.taken.removeAll() }
        let retiredStages = Set(displays.compactMap { occupancy -> ObjectIdentifier? in
            return retire(occupancy) ? ObjectIdentifier(occupancy.stage) : nil
        })
        displays.removeAll {
            retiredStages.contains(ObjectIdentifier($0.stage))
        }
        // `recentCreations` deliberately survives: the rate limit exists to stop churn, and a
        // create/destroy loop that reset it on every cycle would sail straight through.
        return displays.map { $0.stage.displayID }.sorted()
    }

    private func retire(_ occupancy: Occupancy) -> Bool {
        let spaces = occupancy.stage.spaces
        guard stageRetirer(occupancy.stage) else { return false }
        AgentActivity.release(spaces: spaces)
        return true
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
        lock.withLock { displays }.map { occupancy in
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
