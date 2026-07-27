import XCTest
import CoreGraphics
import AppKit
import Darwin
@testable import SpaceOKit

/// Regressions for SPAO-125 (exclusive process ownership) and SPAO-128 (resource budgets).
///
/// Both are about refusing something *before* it mutates state, so every test here asserts on a
/// refusal that happened early rather than on a cleanup that happened late.
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

    // MARK: - SPAO-128: geometry admission

    func testDefaultBudgetAcceptsTheStandardDisplay() {
        let budget = ResourceBudget.default
        XCTAssertNoThrow(try budget.validateDisplaySize(CGSize(width: 1920, height: 1080),
                                                        capacity: 1))
    }

    func testDisplayEdgeBeyondTheBudgetIsRefusedWithNumbers() {
        let budget = ResourceBudget.default
        let oversized = CGSize(width: CGFloat(budget.maximumDisplayEdge + 1), height: 1080)
        XCTAssertThrowsError(try budget.validateDisplaySize(oversized, capacity: 1)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\(budget.maximumDisplayEdge)"),
                          "the refusal must state the limit: \(message)")
            XCTAssertTrue(message.contains("SPACEO_UNSAFE_RESOURCE_LIMITS"),
                          "the refusal must state the recovery path: \(message)")
        }
    }

    /// UInt32 was the only previous bound, which is no bound at all: 4294967295x4294967295 is
    /// representable and would ask the WindowServer for eighteen exabytes of framebuffer.
    func testUInt32RepresentableGeometryIsNotAutomaticallyAcceptable() {
        let budget = ResourceBudget.default
        let absurd = CGSize(width: CGFloat(UInt32.max), height: CGFloat(UInt32.max))
        XCTAssertThrowsError(try budget.validateDisplaySize(absurd, capacity: 1))
        XCTAssertThrowsError(try ResourceBudget.unsafeOperator.validateDisplaySize(absurd,
                                                                                   capacity: 1),
                             "even the operator escape hatch stays inside representable, sane values")
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

    /// The "successful allocation an agent can do nothing with" case: arbitrary density on a
    /// fixed display used to produce zero-area tiles and still report success.
    func testDensityThatWouldProduceUnusableTilesIsRefused() {
        let budget = ResourceBudget.default
        let display = CGSize(width: 1920, height: 1080)
        XCTAssertNoThrow(try budget.validateDisplaySize(display, capacity: 4))
        XCTAssertThrowsError(try budget.validateDisplaySize(display, capacity: 64)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\(Int(budget.minimumTileSize.width))"),
                          "the refusal must state the minimum tile: \(message)")
        }
    }

    func testTileMinimumIsAppliedAtItsExactBoundary() throws {
        let budget = ResourceBudget.default
        // Two columns, one row: each tile is exactly the minimum width.
        let exact = CGSize(width: budget.minimumTileSize.width * 2,
                           height: budget.minimumTileSize.height)
        XCTAssertNoThrow(try budget.validateDisplaySize(exact, capacity: 2))

        let onePixelShort = CGSize(width: exact.width - 2, height: exact.height)
        XCTAssertThrowsError(try budget.validateDisplaySize(onePixelShort, capacity: 2))
    }

    // MARK: - SPAO-128: usage admission

    private func usage(sessions: Int = 0, displays: Int = 0, pixels: Int = 0,
                       creations: Int = 0) -> ResourceBudget.Usage {
        ResourceBudget.Usage(sessions: sessions, displays: displays, pixels: pixels,
                             bytes: pixels * ResourceBudget.bytesPerPixel,
                             creationsInLastMinute: creations)
    }

    func testSessionCeilingIsEnforcedAndReportsUsage() {
        let budget = ResourceBudget.default
        XCTAssertNoThrow(try budget.admitSession(
            usage: usage(sessions: budget.maximumSessions - 1)))
        XCTAssertThrowsError(try budget.admitSession(
            usage: usage(sessions: budget.maximumSessions))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\(budget.maximumSessions)"), message)
            XCTAssertTrue(message.contains("destroy a session"), message)
        }
    }

    func testDisplayCeilingIsEnforcedAtItsBoundary() {
        let budget = ResourceBudget.default
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertNoThrow(try budget.admitDisplay(
            size: size, capacity: 1, usage: usage(displays: budget.maximumDisplays - 1)))
        XCTAssertThrowsError(try budget.admitDisplay(
            size: size, capacity: 1, usage: usage(displays: budget.maximumDisplays)))
    }

    func testTotalFramebufferPixelsAreEnforcedAcrossDisplays() {
        let budget = ResourceBudget.default
        let size = CGSize(width: 4096, height: 4096)
        let added = 4096 * 4096
        XCTAssertNoThrow(try budget.admitDisplay(
            size: size, capacity: 1,
            usage: usage(pixels: budget.maximumTotalPixels - added)))
        XCTAssertThrowsError(try budget.admitDisplay(
            size: size, capacity: 1,
            usage: usage(pixels: budget.maximumTotalPixels - added + 1))) { error in
            XCTAssertTrue(error.localizedDescription.contains("framebuffer pixels"),
                          error.localizedDescription)
        }
    }

    /// A crash-looping agent can stay under every standing limit while still churning the
    /// WindowServer, so the rate limit is a separate gate.
    func testCreationRateIsEnforcedIndependentlyOfStandingLimits() {
        let budget = ResourceBudget.default
        let size = CGSize(width: 1920, height: 1080)
        let atRate = usage(sessions: 0, displays: 0, pixels: 0,
                           creations: budget.maximumCreationsPerMinute)
        XCTAssertThrowsError(try budget.admitDisplay(size: size, capacity: 1, usage: atRate)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("per minute"), message)
            XCTAssertTrue(message.contains("loop"),
                          "the remedy should point at the actual cause: \(message)")
        }
    }

    func testUnsafeOperatorModeRaisesLimitsAndSaysSo() {
        let unsafeBudget = ResourceBudget.unsafeOperator
        XCTAssertTrue(unsafeBudget.isUnsafe)
        XCTAssertGreaterThan(unsafeBudget.maximumDisplays, ResourceBudget.default.maximumDisplays)
        XCTAssertThrowsError(try unsafeBudget.admitSession(
            usage: usage(sessions: unsafeBudget.maximumSessions))) { error in
            XCTAssertTrue(error.localizedDescription.contains("already the unsafe operator budget"),
                          "an operator at the unsafe ceiling must not be told to set the flag again")
        }
    }

    func testUnsafeModeComesFromTheEnvironmentNotFromARequest() {
        XCTAssertEqual(ResourceBudget.fromEnvironment([:]), .default)
        XCTAssertEqual(ResourceBudget.fromEnvironment(["SPACEO_UNSAFE_RESOURCE_LIMITS": "0"]),
                       .default)
        XCTAssertEqual(ResourceBudget.fromEnvironment(["SPACEO_UNSAFE_RESOURCE_LIMITS": "1"]),
                       .unsafeOperator)
        XCTAssertEqual(ResourceBudget.fromEnvironment(["SPACEO_UNSAFE_RESOURCE_LIMITS": "TRUE"]),
                       .unsafeOperator)
    }

    // MARK: - SPAO-128: the pool refuses before it allocates

    /// A stage factory that records calls and always refuses. If admission runs in the right
    /// order, an over-budget allocation never reaches it.
    private final class RecordingStageFactory {
        let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func make(_ name: String, _ width: UInt32, _ height: UInt32, _ hiDPI: Bool) throws -> Stage {
            lock.withLock { calls += 1 }
            throw SpaceOError.stageCreationFailed("test factory never builds a real display")
        }
    }

    func testAdmissionRunsBeforeAnyStageIsConstructed() {
        let factory = RecordingStageFactory()
        var budget = ResourceBudget.default
        budget.maximumDisplays = 0
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: budget,
                               stageFactory: factory.make)

        XCTAssertThrowsError(try pool.allocate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("virtual displays"),
                          error.localizedDescription)
        }
        XCTAssertEqual(factory.callCount, 0,
                       "the WindowServer must never be asked for a display we would refuse")
    }

    func testAdmissionPassesThroughToTheFactoryWhenWithinBudget() {
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

    /// Concurrent `session.create` calls must not each see room and collectively overshoot.
    func testConcurrentAllocationsAllRefuseUnderAZeroBudget() {
        let factory = RecordingStageFactory()
        var budget = ResourceBudget.default
        budget.maximumDisplays = 0
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1920, height: 1080),
                               budget: budget,
                               stageFactory: factory.make)

        let refusals = NSCountedSet()
        let refusalLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                _ = try pool.allocate()
                refusalLock.withLock { refusals.add("admitted") }
            } catch {
                refusalLock.withLock { refusals.add("refused") }
            }
        }
        XCTAssertEqual(refusals.count(for: "refused"), 64)
        XCTAssertEqual(refusals.count(for: "admitted"), 0)
        XCTAssertEqual(factory.callCount, 0,
                       "no thread may slip past admission while another is inside it")
        XCTAssertEqual(pool.usage().displays, 0)
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
        XCTAssertThrowsError(try pool.setSessionsPerDisplay(48),
                             "48 tiles on a 1920x1080 display is smaller than any usable window")
        XCTAssertEqual(pool.sessionsPerDisplay, 4,
                       "a refused density must not have been applied")
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
