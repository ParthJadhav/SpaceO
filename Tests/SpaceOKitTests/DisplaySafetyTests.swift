import XCTest
import CoreGraphics
@testable import SpaceOKit

final class DisplaySafetyTests: XCTestCase {
    private final class DisplayBacking: StageDisplayBacking, @unchecked Sendable {
        let displayID: CGDirectDisplayID
        let bounds = CGRect(x: 2_000, y: 0, width: 1_280, height: 800)
        private let lock = NSLock()
        private var attached = true
        private var invalidations = 0

        init(displayID: CGDirectDisplayID) { self.displayID = displayID }

        var valid: Bool { lock.withLock { attached } }
        var isAttached: Bool { lock.withLock { attached } }
        var invalidationCount: Int { lock.withLock { invalidations } }

        func invalidate() {
            lock.withLock {
                invalidations += 1
                attached = false
            }
        }
    }

    private func userDisplay(
        id: CGDirectDisplayID = 1,
        active: Bool = true,
        main: Bool = true,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        modeWidth: Int? = nil,
        mirroredTo: CGDirectDisplayID = 0,
        refreshRate: Double = 60
    ) -> Stage.UserDisplayConfiguration.Display {
        Stage.UserDisplayConfiguration.Display(
            id: id,
            active: active,
            main: main,
            bounds: bounds,
            pixelWidth: Int(bounds.width),
            pixelHeight: Int(bounds.height),
            rotation: 0,
            mirroredTo: mirroredTo,
            modeWidth: modeWidth ?? Int(bounds.width),
            modeHeight: Int(bounds.height),
            modePixelWidth: Int(bounds.width),
            modePixelHeight: Int(bounds.height),
            refreshRate: refreshRate)
    }

    private func configuration(
        _ displays: [Stage.UserDisplayConfiguration.Display]
    ) -> Stage.UserDisplayConfiguration {
        Stage.UserDisplayConfiguration(displays: displays.sorted { $0.id < $1.id })
    }

    private func publicationFailure(
        active: Bool = true,
        spaces: [UInt64] = [200],
        activeSpace: UInt64 = 100,
        bounds: CGRect = CGRect(x: 1_920, y: 0, width: 1_280, height: 800),
        otherBounds: [(CGDirectDisplayID, CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
        ],
        before: Stage.UserDisplayConfiguration? = nil,
        after: Stage.UserDisplayConfiguration? = nil
    ) -> String? {
        let baseline = before ?? configuration([userDisplay()])
        return Stage.publicationFailure(
            displayID: 90_001,
            bounds: bounds,
            activeDisplayIDs: active ? [90_001] : [],
            spaces: spaces,
            activeSpace: activeSpace,
            otherDisplayBounds: otherBounds,
            userConfigurationBefore: baseline,
            userConfigurationAfter: after ?? baseline)
    }

    override func setUp() {
        super.setUp()
        ProcessOwnership.reset()
        AgentActivity.reset()
    }

    override func tearDown() {
        ProcessOwnership.reset()
        AgentActivity.reset()
        super.tearDown()
    }

    func testHealthyPublishedDisplayIsAccepted() {
        XCTAssertNil(publicationFailure())
        // Touching an edge is not overlap and is the normal side-by-side arrangement.
        XCTAssertNil(publicationFailure(
            bounds: CGRect(x: 1_920, y: 0, width: 1_280, height: 800)))
    }

    func testInactiveOverlappingOrSpacelessDisplayIsRefused() {
        XCTAssertTrue(publicationFailure(active: false)?.contains("inactive") == true)
        XCTAssertTrue(publicationFailure(spaces: [])?.contains("no managed Space") == true)
        XCTAssertTrue(publicationFailure(spaces: [100])?.contains("active Space") == true)
        XCTAssertTrue(publicationFailure(
            bounds: CGRect(x: 1_800, y: 0, width: 1_280, height: 800))?
            .contains("overlaps display 1") == true)
    }

    func testUserDisplayTopologyOrModeChangeIsRefused() {
        let before = configuration([userDisplay()])
        let moved = configuration([userDisplay(
            bounds: CGRect(x: 50, y: 0, width: 1_920, height: 1_080))])
        XCTAssertTrue(publicationFailure(before: before, after: moved)?
            .contains("changed bounds") == true)

        let missing = configuration([])
        XCTAssertTrue(publicationFailure(before: before, after: missing)?
            .contains("went offline") == true)
    }

    func testInactiveMirrorFollowerSyntheticModeDoesNotRejectAHealthyStage() {
        let before = configuration([
            userDisplay(
                id: 1, active: false, main: false, modeWidth: 1_920, mirroredTo: 2),
            userDisplay(id: 2),
        ])
        let after = configuration([
            userDisplay(
                id: 1, active: false, main: false, modeWidth: 3_840, mirroredTo: 2),
            userDisplay(id: 2),
        ])
        XCTAssertNil(publicationFailure(before: before, after: after))

        let activeModeChange = configuration([userDisplay(id: 2, modeWidth: 3_840)])
        XCTAssertTrue(publicationFailure(
            before: configuration([userDisplay(id: 2)]),
            after: activeModeChange)?.contains("display mode") == true)
    }

    func testLastSessionRetiresEveryDisplayAfterIdleGrace() async throws {
        let backing = DisplayBacking(displayID: 90_010)
        let stage = Stage(
            testingBacking: backing,
            onlineDisplayIDs: { backing.isAttached ? [backing.displayID] : [] })
        let pool = DisplayPool(
            stageFactory: { _, _, _, _ in stage },
            stageRetirer: { $0.invalidate(waitingForRemoval: 0) })
        let manager = SessionManager(
            pool: pool,
            runJanitor: false,
            idleDisplayGraceNanoseconds: 5_000_000,
            sessionFactory: { AgentSession(id: $0, slot: $1) })

        let created = await manager.handle(TestController.createRequest())
        XCTAssertTrue(created.ok, created.error ?? "")
        let destroyed = await manager.handle(TestController.request("session.destroy"))
        XCTAssertTrue(destroyed.ok, destroyed.error ?? "")

        let deadline = ContinuousClock.now + .seconds(1)
        while await manager.displayCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalDisplayCount = await manager.displayCount
        XCTAssertEqual(finalDisplayCount, 0)
        XCTAssertFalse(backing.isAttached)
        XCTAssertEqual(backing.invalidationCount, 1)
    }

    func testExclusiveAllocationReusesAnIdleDisplayOfTheSameSize() throws {
        let backing = DisplayBacking(displayID: 90_020)
        let stage = Stage(
            testingBacking: backing,
            onlineDisplayIDs: { backing.isAttached ? [backing.displayID] : [] })
        var built = 0
        let pool = DisplayPool(
            stageFactory: { _, _, _, _ in built += 1; return stage },
            stageRetirer: { $0.invalidate(waitingForRemoval: 0) })
        let size = CGSize(width: 1_920, height: 1_080)

        let first = try pool.allocateExclusive(size: size)
        XCTAssertTrue(pool.release(first, retainEmpty: true))
        _ = try pool.allocateExclusive(size: size)
        XCTAssertEqual(built, 1, "the idle display is handed out again, not rebuilt")
        XCTAssertEqual(pool.displayCount, 1)

        _ = try pool.allocateExclusive(size: CGSize(width: 2_560, height: 1_440))
        XCTAssertEqual(built, 2, "a different size is a different display")
    }

    func testPoolRemoveEndsTheDisplaysSessionsAndRetiresIt() async throws {
        let backing = DisplayBacking(displayID: 90_021)
        let stage = Stage(
            testingBacking: backing,
            onlineDisplayIDs: { backing.isAttached ? [backing.displayID] : [] })
        let pool = DisplayPool(
            stageFactory: { _, _, _, _ in stage },
            stageRetirer: { $0.invalidate(waitingForRemoval: 0) })
        let manager = SessionManager(
            pool: pool,
            runJanitor: false,
            idleDisplayGraceNanoseconds: 60_000_000_000,
            sessionFactory: { AgentSession(id: $0, slot: $1) })
        let created = await manager.handle(TestController.createRequest())
        XCTAssertTrue(created.ok, created.error ?? "")

        var remove = Request(cmd: "pool.remove")
        remove.display = 90_021
        let refused = await manager.handle(remove)
        XCTAssertFalse(refused.ok, "removing a display ends other controllers' sessions")
        XCTAssertTrue(refused.error?.contains("--operator") == true, refused.error ?? "")

        remove.operatorScope = true
        let removed = await manager.handle(remove)
        XCTAssertTrue(removed.ok, removed.error ?? "")
        let displayCount = await manager.displayCount
        XCTAssertEqual(displayCount, 0, "retired now, not after the idle grace")
        XCTAssertFalse(backing.isAttached)
        let listed = await manager.handle(Request(cmd: "session.list"))
        XCTAssertEqual(listed.sessions?.count ?? 0, 0)

        var unknown = Request(cmd: "pool.remove")
        unknown.display = 12_345
        unknown.operatorScope = true
        let missing = await manager.handle(unknown)
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.error?.contains("not a SpaceO virtual display") == true,
                      missing.error ?? "")
    }

    func testIdleTimerNeverRetiresAReusedActiveDisplay() async throws {
        let backing = DisplayBacking(displayID: 90_011)
        let stage = Stage(
            testingBacking: backing,
            onlineDisplayIDs: { backing.isAttached ? [backing.displayID] : [] })
        let pool = DisplayPool(
            stageFactory: { _, _, _, _ in stage },
            stageRetirer: { $0.invalidate(waitingForRemoval: 0) })
        let manager = SessionManager(
            pool: pool,
            runJanitor: false,
            idleDisplayGraceNanoseconds: 50_000_000,
            sessionFactory: { AgentSession(id: $0, slot: $1) })

        let firstCreate = await manager.handle(TestController.createRequest())
        let firstDestroy = await manager.handle(TestController.request("session.destroy"))
        let secondCreate = await manager.handle(TestController.createRequest())
        XCTAssertTrue(firstCreate.ok, firstCreate.error ?? "")
        XCTAssertTrue(firstDestroy.ok, firstDestroy.error ?? "")
        XCTAssertTrue(secondCreate.ok, secondCreate.error ?? "")
        try await Task.sleep(for: .milliseconds(100))

        let activeDisplayCount = await manager.displayCount
        XCTAssertEqual(activeDisplayCount, 1)
        XCTAssertTrue(backing.isAttached)
        XCTAssertEqual(backing.invalidationCount, 0)

        let secondDestroy = await manager.handle(TestController.request("session.destroy"))
        XCTAssertTrue(secondDestroy.ok, secondDestroy.error ?? "")
        let deadline = ContinuousClock.now + .seconds(1)
        while await manager.displayCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalDisplayCount = await manager.displayCount
        XCTAssertEqual(finalDisplayCount, 0)
        XCTAssertFalse(backing.isAttached)
    }
}
