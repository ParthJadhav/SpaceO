import XCTest
import CoreGraphics
import AppKit
import Darwin
@testable import SpaceOKit

/// Regressions for exclusive process ownership and runtime geometry/accounting.
final class OwnershipAndBudgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProcessOwnership.reset()
    }

    override func tearDown() {
        ProcessOwnership.reset()
        super.tearDown()
    }

    // MARK: - SPAO-125: process identity

    func testIdentityPairsThePIDWithAStartTime() throws {
        let mine = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        XCTAssertEqual(mine.pid, getpid())
        XCTAssertTrue(mine.isPrecise, "the kernel reports our own start time")
        XCTAssertTrue(mine.isAlive)
    }

    func testIdentityOfAVanishedProcessIsNil() {
        // A PID far above the system maximum cannot name a live process.
        XCTAssertNil(ProcessIdentity.current(of: pid_t(999_999)))
        XCTAssertNil(ProcessIdentity.current(of: 0))
        XCTAssertNil(ProcessIdentity.current(of: -1))
    }

    /// The bug this whole ticket exists for: a stale record must not confer authority over
    /// whatever inherited its number.
    func testARecycledPIDDoesNotInheritTheOldIdentitysAuthority() throws {
        let live = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        let stale = ProcessIdentity(pid: getpid(),
                                    startedAtMicroseconds: live.startedAtMicroseconds &- 1)

        XCTAssertNotEqual(stale, live, "same pid, different start time is a different process")
        XCTAssertFalse(stale.isAlive,
                       "the process that started at that moment is gone, whatever holds the pid now")
        XCTAssertTrue(live.isAlive)
    }

    func testStaleClaimsAreNotAllowedToBlockTheLiveProcess() throws {
        let live = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        let stale = ProcessIdentity(pid: getpid(),
                                    startedAtMicroseconds: live.startedAtMicroseconds &- 1)
        try ProcessOwnership.claim(stale, owner: "dead-session")

        // Reading prunes the dead claim, so the live process is free to be adopted.
        XCTAssertNil(ProcessOwnership.owner(of: stale))
        XCTAssertNoThrow(try ProcessOwnership.claim(live, owner: "new-session"))
        XCTAssertEqual(ProcessOwnership.owner(of: live), "new-session")
    }

    // MARK: - SPAO-125: exclusive ownership

    func testASecondSessionCannotAdoptAnOwnedProcess() throws {
        let identity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        try ProcessOwnership.claim(identity, owner: "agent-1")

        XCTAssertThrowsError(try ProcessOwnership.claim(identity, owner: "agent-2")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("agent-1"),
                          "the refusal must name the session that already owns it: \(message)")
        }
        XCTAssertEqual(ProcessOwnership.owner(of: identity), "agent-1",
                       "a refused claim must not have moved ownership")
    }

    func testReclaimingByTheSameSessionIsNotAConflict() throws {
        let identity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        try ProcessOwnership.claim(identity, owner: "agent-1")
        XCTAssertNoThrow(try ProcessOwnership.claim(identity, owner: "agent-1"))
    }

    func testDestroyReleasesOwnershipSoTheProcessCanBeAdoptedAgain() throws {
        let identity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        try ProcessOwnership.claim(identity, owner: "agent-1")
        ProcessOwnership.releaseAll(owner: "agent-1")

        XCTAssertNil(ProcessOwnership.owner(of: identity))
        XCTAssertNoThrow(try ProcessOwnership.claim(identity, owner: "agent-2"))
    }

    func testReleasingOneSessionLeavesAnotherSessionsClaimsAlone() throws {
        let identity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        try ProcessOwnership.claim(identity, owner: "agent-1")
        ProcessOwnership.releaseAll(owner: "agent-2")
        XCTAssertEqual(ProcessOwnership.owner(of: identity), "agent-1")
    }

    /// Concurrent adoption of the same PID must produce exactly one winner. Losing this race is
    /// how two sessions ended up both believing they could terminate one process.
    func testConcurrentClaimsProduceExactlyOneOwner() throws {
        let identity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        let winners = NSMutableArray()
        let winnerLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                try ProcessOwnership.claim(identity, owner: "agent-\(index)")
                winnerLock.withLock { winners.add("agent-\(index)") }
            } catch {
                // Expected for all but one.
            }
        }
        XCTAssertEqual(winners.count, 1,
                       "exactly one session may own a process; got \(winners)")
    }

    func testDescribeRefusesNonsensePIDsBeforeTouchingAnything() {
        XCTAssertThrowsError(try AppLauncher.describe(pid: 0))
        XCTAssertThrowsError(try AppLauncher.describe(pid: -5))
        XCTAssertThrowsError(try AppLauncher.describe(pid: 999_999))
    }

    /// `quit(force:)` is the one irreversible action here, so it must refuse an identity whose
    /// process is gone rather than signalling whatever now holds the number.
    func testForceQuitIsRefusedForAStaleIdentity() throws {
        let live = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        let stale = ProcessIdentity(pid: getpid(),
                                    startedAtMicroseconds: live.startedAtMicroseconds &- 1)
        let app = LaunchedApp(pid: getpid(),
                              identity: stale,
                              bundleIdentifier: nil,
                              name: "ghost",
                              url: URL(fileURLWithPath: "/"),
                              startedByUs: true,
                              devToolsPort: nil,
                              temporaryProfile: nil)
        // If the identity guard were missing this would terminate the test runner, so simply
        // surviving the call is the assertion.
        AppLauncher.quit(app, force: true)
        XCTAssertTrue(live.isAlive, "the live process must be untouched")
    }

    // MARK: - Runtime geometry

    func testDefaultBudgetAcceptsTheStandardDisplay() {
        let budget = ResourceBudget.default
        XCTAssertNoThrow(try budget.validateDisplaySize(CGSize(width: 1920, height: 1080),
                                                        capacity: 1))
    }

    func testGeometryThatOverflowsProcessArithmeticIsRejected() {
        let budget = ResourceBudget.default
        let absurd = CGSize(width: CGFloat(UInt32.max), height: CGFloat(UInt32.max))
        XCTAssertThrowsError(try budget.validateDisplaySize(absurd, capacity: 1))
    }

    func testFractionalAndNonFiniteGeometryIsRefused() {
        let budget = ResourceBudget.default
        for size in [CGSize(width: 1920.5, height: 1080),
                     CGSize(width: CGFloat.nan, height: 1080),
                     CGSize(width: CGFloat.infinity, height: 1080),
                     CGSize(width: 0, height: 1080),
                     CGSize(width: -1920, height: 1080)] {
            XCTAssertThrowsError(try budget.validateDisplaySize(size, capacity: 1),
                                 "\(size) must not be accepted")
        }
    }

    func testUnusableTileDensityIsRejected() {
        let budget = ResourceBudget.default
        XCTAssertNoThrow(try budget.validateDisplaySize(
            CGSize(width: 1920, height: 1080), capacity: 4))
        XCTAssertThrowsError(try budget.validateDisplaySize(
            CGSize(width: 1920, height: 1080), capacity: 64))
    }

    func testZeroAreaTileAndUnboundedMaterializationAreRejected() throws {
        let budget = ResourceBudget.default
        XCTAssertThrowsError(try budget.validateDisplaySize(
            CGSize(width: 1, height: 1), capacity: 2))
        XCTAssertThrowsError(try budget.validateDisplaySize(
            CGSize(width: 1920, height: 1080),
            capacity: TileLayout.maximumCapacity + 1))
    }

    // MARK: - Bounded usage admission

    private func usage(sessions: Int = 0, displays: Int = 0, pixels: Int = 0,
                       creations: Int = 0) -> ResourceBudget.Usage {
        ResourceBudget.Usage(sessions: sessions, displays: displays, pixels: pixels,
                             bytes: pixels * ResourceBudget.bytesPerPixel,
                             creationsInLastMinute: creations)
    }

    func testSessionAndDisplayCeilingsAreEnforced() {
        let budget = ResourceBudget.default
        XCTAssertNoThrow(try budget.admitSession(
            usage: usage(sessions: budget.maximumSessions - 1)))
        XCTAssertThrowsError(try budget.admitSession(
            usage: usage(sessions: budget.maximumSessions)))
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertNoThrow(try budget.admitDisplay(
            size: size, capacity: 1,
            usage: usage(displays: budget.maximumDisplays - 1)))
        XCTAssertThrowsError(try budget.admitDisplay(
            size: size, capacity: 1,
            usage: usage(displays: budget.maximumDisplays)))
    }

    func testFramebufferAndCreationRateLimitsAreEnforced() {
        let budget = ResourceBudget.default
        let size = CGSize(width: 1920, height: 1080)
        let added = 1920 * 1080
        XCTAssertThrowsError(try budget.admitDisplay(
            size: size, capacity: 1,
            usage: usage(pixels: budget.maximumTotalPixels - added + 1))) { error in
            XCTAssertTrue(error.localizedDescription.contains("framebuffer pixels"))
        }

        var byteUsage = usage()
        byteUsage.bytes = budget.maximumTotalBytes
        XCTAssertThrowsError(try budget.admitDisplay(
            size: size, capacity: 1, usage: byteUsage)) { error in
            XCTAssertTrue(error.localizedDescription.contains("framebuffer bytes"))
        }

        XCTAssertThrowsError(try budget.admitDisplay(
            size: size, capacity: 1,
            usage: usage(creations: budget.maximumCreationsPerMinute))) { error in
            XCTAssertTrue(error.localizedDescription.contains("per minute"))
        }
    }

    func testOperatorOverrideIsExplicitBoundedAndDoesNotDisableAdmission() {
        XCTAssertEqual(ResourceBudget.fromEnvironment([:]), .default)
        XCTAssertEqual(ResourceBudget.fromEnvironment(
            ["SPACEO_UNSAFE_RESOURCE_LIMITS": "TRUE"]), .unsafeOperator)
        XCTAssertTrue(ResourceBudget.unsafeOperator.isUnsafe)
        XCTAssertGreaterThan(ResourceBudget.unsafeOperator.maximumDisplays,
                             ResourceBudget.default.maximumDisplays)
        XCTAssertLessThan(ResourceBudget.unsafeOperator.maximumDisplays, Int.max)
        XCTAssertThrowsError(try ResourceBudget.unsafeOperator.admitSession(
            usage: usage(sessions: ResourceBudget.unsafeOperator.maximumSessions)))
    }

    // MARK: - Pool allocation

    /// A stage factory that records calls and always returns a technical allocation error.
    private final class RecordingStageFactory {
        let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func make(_ name: String, _ width: UInt32, _ height: UInt32, _ hiDPI: Bool) throws -> Stage {
            lock.withLock { calls += 1 }
            throw SpaceOError.stageCreationFailed("test factory never builds a real display")
        }
    }

    func testValidAllocationPassesThroughToTheFactory() {
        let factory = RecordingStageFactory()
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: .default,
                               stageFactory: factory.make)
        XCTAssertThrowsError(try pool.allocate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("test factory"),
                          "a within-budget request must reach the allocator: \(error)")
        }
        XCTAssertEqual(factory.callCount, 1)
    }

    func testOverBudgetAllocationNeverConstructsAStage() {
        let factory = RecordingStageFactory()
        var budget = ResourceBudget.default
        budget.maximumDisplays = 0
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: budget,
                               stageFactory: factory.make)
        XCTAssertThrowsError(try pool.allocate())
        XCTAssertEqual(factory.callCount, 0)
    }

    func testFailedConcurrentCreationAttemptsStillConsumeTheRateBudget() {
        let factory = RecordingStageFactory()
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: .default,
                               stageFactory: factory.make)

        let failures = NSCountedSet()
        let failureLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                _ = try pool.allocate()
                failureLock.withLock { failures.add("allocated") }
            } catch {
                failureLock.withLock { failures.add("factory-error") }
            }
        }
        XCTAssertEqual(failures.count(for: "factory-error"), 64)
        XCTAssertEqual(failures.count(for: "allocated"), 0)
        XCTAssertEqual(factory.callCount, ResourceBudget.default.maximumCreationsPerMinute)
        XCTAssertEqual(pool.usage().displays, 0)
        XCTAssertEqual(pool.usage().creationsInLastMinute,
                       ResourceBudget.default.maximumCreationsPerMinute)
    }

    func testPoolReportsUsageAgainstItsBudget() {
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: .default,
                               stageFactory: RecordingStageFactory().make)
        let usage = pool.usage()
        XCTAssertEqual(usage.displays, 0)
        XCTAssertEqual(usage.sessions, 0)
        XCTAssertEqual(usage.pixels, 0)
        XCTAssertEqual(pool.budget, .default)
    }

    func testDensityChangeIsValidatedAgainstTheNewTileSize() throws {
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: .default,
                               stageFactory: RecordingStageFactory().make)
        XCTAssertNoThrow(try pool.setSessionsPerDisplay(4))
        XCTAssertThrowsError(try pool.setSessionsPerDisplay(0))
        XCTAssertThrowsError(try pool.setSessionsPerDisplay(TileLayout.maximumCapacity + 1))
        XCTAssertThrowsError(try pool.setSessionsPerDisplay(48))
        XCTAssertEqual(pool.sessionsPerDisplay, 4)
    }

    // MARK: - SPAO-128: tile lookup stays bounded

    func testTileLookupIsBoundedAndIndividualLookupNeedsNoFullLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNotNil(TileLayout.rect(in: bounds,
                                        capacity: TileLayout.maximumCapacity, index: 0))
        XCTAssertNil(TileLayout.rect(in: bounds,
                                     capacity: TileLayout.maximumCapacity + 1, index: 0),
                     "a capacity past the bound must be refused, not silently tiled")
        XCTAssertEqual(TileLayout.rects(in: bounds, capacity: Int.max).count,
                       TileLayout.maximumCapacity,
                       "the materialised layout must never scale with a caller-supplied integer")
    }
}
