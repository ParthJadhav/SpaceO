import CoreGraphics
import XCTest
@testable import SpaceOKit

final class StageRetirementSettlingTests: XCTestCase {
    private final class Backing: StageDisplayBacking, @unchecked Sendable {
        let displayID: CGDirectDisplayID = 94_501
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        private let lock = NSLock()
        private var invalidations = 0
        private let onRelease: (@Sendable () -> Void)?
        init(onRelease: (@Sendable () -> Void)? = nil) { self.onRelease = onRelease }
        deinit { onRelease?() }
        var calls: Int { lock.withLock { invalidations } }
        var valid: Bool { calls == 0 }
        func invalidate() { lock.withLock { invalidations += 1 } }
    }

    private final class WeakBacking {
        weak var value: Backing?
        init(_ value: Backing?) { self.value = value }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var refusalConsumed = false
        private var checks = 0
        var checkCount: Int { lock.withLock { checks } }
        func allow() { lock.withLock { ready = true } }
        func refuseOnce() {
            lock.withLock {
                guard !refusalConsumed else { return }
                refusalConsumed = true
                ready = false
            }
        }
        func check(_: TimeInterval) throws {
            guard lock.withLock({ checks += 1; return ready }) else {
                throw DisplayHostHealth.ReconfigurationSettlingRefusal(
                    underlyingError: .stageCreationFailed("ColorSync has not settled"))
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = DispatchTime.now()
        private var observedBudgets: [TimeInterval] = []
        var budgets: [TimeInterval] { lock.withLock { observedBudgets } }
        func now() -> DispatchTime { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value + seconds } }
        func record(_ budget: TimeInterval) { lock.withLock { observedBudgets.append(budget) } }
    }

    func testSettlingRefusalPreservesValidDisplayAndDoesNotTripCircuit() {
        let backing = Backing(), gate = Gate(), coordinator = DisplayLifecycleCoordinator()
        let stage = Stage(testingBacking: backing,
                          onlineDisplayIDs: { backing.valid ? [backing.displayID] : [] },
                          coordinator: coordinator,
                          reconfigurationReadiness: { try gate.check($0) })
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(backing.calls, 0)
        XCTAssertTrue(stage.isValid)
        XCTAssertEqual(stage.displayID, backing.displayID)
        XCTAssertNil(coordinator.failureReason)

        gate.allow()
        XCTAssertTrue(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(backing.calls, 1)
    }

    func testPoolRetainsAndReusesDisplayAfterRetirementWasDeferred() throws {
        let backing = Backing(), gate = Gate()
        let stage = Stage(testingBacking: backing,
                          onlineDisplayIDs: { backing.valid ? [backing.displayID] : [] },
                          reconfigurationReadiness: { try gate.check($0) })
        let pool = DisplayPool(displaySize: backing.bounds.size,
                               stageFactory: { _, _, _, _ in stage },
                               stageRetirer: { $0.invalidate(waitingForRemoval: 0) })
        let slot = try pool.allocate()
        XCTAssertFalse(pool.release(slot))
        XCTAssertEqual(pool.displayCount, 1)
        XCTAssertEqual(backing.calls, 0)
        let reused = try pool.allocate()
        XCTAssertTrue(reused.stage === stage)
        gate.allow()
        XCTAssertTrue(pool.release(reused))
        XCTAssertEqual(pool.displayCount, 0)
    }

    func testDefaultBudgetReservesTenSecondsAndDefersWithoutMutationWhenReadinessOverruns() {
        let backing = Backing(), clock = Clock(), coordinator = DisplayLifecycleCoordinator()
        let stage = Stage(testingBacking: backing,
                          onlineDisplayIDs: { [] }, coordinator: coordinator,
                          reconfigurationReadiness: { budget in
                              clock.record(budget)
                              clock.advance(21)
                          }, retirementNow: { clock.now() })
        XCTAssertFalse(stage.invalidate())
        XCTAssertEqual(clock.budgets, [20])
        XCTAssertEqual(backing.calls, 0)
        XCTAssertTrue(stage.isValid)
        XCTAssertNil(coordinator.failureReason)
    }

    func testShortAndZeroTimeoutsDoNotSpendAnyBudgetWaitingForSettling() {
        for timeout in [0.0, 0.5, 10.0] {
            let backing = Backing(), clock = Clock()
            let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                              reconfigurationReadiness: { clock.record($0) })
            XCTAssertTrue(stage.invalidate(waitingForRemoval: timeout))
            XCTAssertEqual(clock.budgets, [0])
            XCTAssertEqual(backing.calls, 1)
        }
    }

    func testWorkerSettlingRecheckAfterConfigurationRestoresValidityAndAllowsRetry() {
        let backing = Backing(), gate = Gate(), coordinator = DisplayLifecycleCoordinator()
        gate.allow()
        let stage = Stage(testingBacking: backing,
                          onlineDisplayIDs: { backing.valid ? [backing.displayID] : [] },
                          coordinator: coordinator,
                          configuration: { gate.refuseOnce(); return nil },
                          reconfigurationCheck: { try gate.check(0) })
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(backing.calls, 0)
        XCTAssertTrue(stage.isValid)
        XCTAssertEqual(stage.displayID, backing.displayID)
        XCTAssertNil(coordinator.failureReason)
        // The same owner remains retryable rather than becoming permanently invalid.
        gate.allow()
        XCTAssertTrue(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(backing.calls, 1)
        XCTAssertNil(coordinator.failureReason)
    }

    func testWorkerBudgetExhaustionBeforeMutationRestoresValidOwnerWithoutTrip() {
        let backing = Backing(), clock = Clock(), coordinator = DisplayLifecycleCoordinator()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                          coordinator: coordinator,
                          configuration: { clock.advance(21); return nil },
                          retirementNow: { clock.now() })
        XCTAssertFalse(stage.invalidate())
        XCTAssertEqual(backing.calls, 0)
        XCTAssertTrue(stage.isValid)
        XCTAssertNil(coordinator.failureReason)
    }

    func testHardReadinessFaultBeforeMutationRemainsSticky() {
        let backing = Backing(), coordinator = DisplayLifecycleCoordinator()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                          coordinator: coordinator,
                          reconfigurationReadiness: { _ in
                              throw SpaceOError.stageCreationFailed("host health blocked")
                          })
        XCTAssertFalse(stage.invalidate())
        XCTAssertEqual(backing.calls, 0)
        XCTAssertFalse(stage.isValid)
        XCTAssertNotNil(coordinator.failureReason)
    }

    func testHardWorkerFaultBeforeMutationRemainsSticky() {
        let backing = Backing(), coordinator = DisplayLifecycleCoordinator()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                          coordinator: coordinator,
                          reconfigurationCheck: {
                              throw SpaceOError.stageCreationFailed("host health unknown")
                          })
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(backing.calls, 0)
        XCTAssertFalse(stage.isValid)
        XCTAssertNotNil(coordinator.failureReason)
    }

    func testFailedPublicationRetainsBackingAndPreservesSpecificFailure() {
        let coordinator = DisplayLifecycleCoordinator()
        var backing: Backing? = Backing()
        let retained = WeakBacking(backing)
        let reason = "published display changed the physical topology"
        XCTAssertThrowsError(try Stage.rejectPublication(backing!, reason: reason, coordinator: coordinator)) {
            guard case SpaceOError.stageCreationFailed(let message) = $0 else {
                return XCTFail("publication must preserve its public error code")
            }
            XCTAssertEqual(message, reason)
        }
        XCTAssertTrue(coordinator.failureReason?.contains(reason) == true)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [94_501])
        let status = coordinator.annotatingDeferredRetirements(
            .init(state: .blocked, reason: coordinator.failureReason))
        XCTAssertEqual(status.deferredRetirementDisplayIDs, [94_501])
        XCTAssertEqual(status.reason, coordinator.failureReason, "retained IDs do not mask hard faults")
        XCTAssertEqual(backing?.calls, 0)
        backing = nil
        XCTAssertNotNil(retained.value, "failed publication retains its backing for explicit recovery")
    }

    func testDeinitSettlingDeferralRetainsBackingWithoutTrippingCircuit() {
        let finished = expectation(description: "fallback retirement completed")
        let coordinator = DisplayLifecycleCoordinator()
        var backing: Backing? = Backing()
        let retained = WeakBacking(backing)
        var stage: Stage? = Stage(testingBacking: backing!, onlineDisplayIDs: { [] },
                                  coordinator: coordinator,
                                  reconfigurationReadiness: { _ in
                                      throw DisplayHostHealth.ReconfigurationSettlingRefusal(
                                          underlyingError: .stageCreationFailed("ColorSync has not settled"))
                                  }, fallbackRetirementCompletion: { finished.fulfill() })
        XCTAssertNotNil(stage)
        stage = nil
        backing = nil
        wait(for: [finished], timeout: 2)
        XCTAssertNotNil(retained.value, "deferred fallback must quarantine its owner")
        XCTAssertEqual(retained.value?.calls, 0)
        XCTAssertNil(coordinator.failureReason)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [94_501])
        XCTAssertThrowsError(try coordinator.requireNoDeferredRetirements())
        XCTAssertNil(coordinator.failureReason, "visible deferred cleanup is not a health circuit fault")
    }

    func testDeinitHardReadinessFaultRetainsBackingAndTripsCircuit() {
        let finished = expectation(description: "fallback retirement completed")
        let coordinator = DisplayLifecycleCoordinator()
        var backing: Backing? = Backing()
        let retained = WeakBacking(backing)
        var stage: Stage? = Stage(testingBacking: backing!, onlineDisplayIDs: { [] },
                                  coordinator: coordinator,
                                  reconfigurationReadiness: { _ in
                                      throw SpaceOError.stageCreationFailed("host health blocked")
                                  }, fallbackRetirementCompletion: { finished.fulfill() })
        XCTAssertNotNil(stage)
        stage = nil
        backing = nil
        wait(for: [finished], timeout: 2)
        XCTAssertNotNil(retained.value)
        XCTAssertEqual(retained.value?.calls, 0)
        XCTAssertNotNil(coordinator.failureReason)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [94_501])
    }

    func testConfirmedRetirementDoesNotRepeatReadinessOrBackingMutation() {
        let backing = Backing(), gate = Gate(), coordinator = DisplayLifecycleCoordinator()
        gate.allow()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                          coordinator: coordinator,
                          reconfigurationReadiness: { try gate.check($0) },
                          reconfigurationCheck: { try gate.check(0) })
        XCTAssertTrue(stage.invalidate(waitingForRemoval: 0))
        let checks = gate.checkCount
        XCTAssertEqual(checks, 3)
        gate.refuseOnce()
        XCTAssertTrue(stage.invalidate())
        XCTAssertTrue(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(gate.checkCount, checks, "verified removal needs no later readiness query")
        XCTAssertEqual(backing.calls, 1)
        XCTAssertNil(coordinator.failureReason)
    }

    func testConfirmedRemovalClearsVisibleDeferredOwnership() {
        let backing = Backing(), coordinator = DisplayLifecycleCoordinator()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] }, coordinator: coordinator)
        coordinator.quarantineDeferred(backing, displayID: backing.displayID)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [backing.displayID])
        XCTAssertTrue(stage.invalidate(waitingForRemoval: 0))
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [])
        XCTAssertNoThrow(try coordinator.requireNoDeferredRetirements())
        XCTAssertNil(coordinator.failureReason)
    }

    func testSinglePoolRetirementLeavesFiveSecondsOfControllerLeaseHeadroom() throws {
        let backing = Backing(), clock = Clock(), gate = Gate()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                          reconfigurationReadiness: { budget in
                              clock.record(budget)
                              try gate.check(budget)
                          })
        // This public factory initializer uses the production timeout-forwarding retirer.
        let pool = DisplayPool(displaySize: backing.bounds.size,
                               stageFactory: { _, _, _, _ in stage })
        let slot = try pool.allocate()
        XCTAssertFalse(pool.release(slot))
        XCTAssertEqual(clock.budgets, [15], "single pool cleanup totals 25s with 10s reserved for removal")
        XCTAssertEqual(backing.calls, 0)
        XCTAssertEqual(pool.displayCount, 1)
        XCTAssertTrue(stage.isValid)
        gate.allow()
        XCTAssertTrue(pool.release(slot))
        XCTAssertEqual(pool.displayCount, 0)
    }

    func testFallbackOwnerIsVisibleBeforeAndDuringReadinessWait() {
        let entered = expectation(description: "fallback readiness entered")
        let finished = expectation(description: "fallback retirement completed")
        let release = DispatchSemaphore(value: 0)
        let coordinator = DisplayLifecycleCoordinator()
        let backing = Backing()
        var stage: Stage? = Stage(testingBacking: backing, onlineDisplayIDs: { [] },
                                  coordinator: coordinator,
                                  reconfigurationReadiness: { _ in
                                      entered.fulfill()
                                      guard release.wait(timeout: .now() + .seconds(10)) == .success else {
                                          throw SpaceOError.stageCreationFailed("fixture gate timed out")
                                      }
                                      throw DisplayHostHealth.ReconfigurationSettlingRefusal(
                                          underlyingError: .stageCreationFailed("ColorSync has not settled"))
                                  }, fallbackRetirementCompletion: { finished.fulfill() })
        XCTAssertNotNil(stage)
        stage = nil
        // Registration occurs synchronously in deinit, before any async work is scheduled.
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [backing.displayID])
        wait(for: [entered], timeout: 2)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [backing.displayID])
        XCTAssertThrowsError(try coordinator.requireNoDeferredRetirements())
        XCTAssertEqual(backing.calls, 0)
        XCTAssertNil(coordinator.failureReason)
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [backing.displayID])
        XCTAssertNil(coordinator.failureReason)
    }

    func testSuccessfulFallbackRemovesVisibleOwnerAndReleasesQuarantine() {
        let finished = expectation(description: "fallback retirement completed")
        let released = expectation(description: "verified backing released")
        let coordinator = DisplayLifecycleCoordinator()
        var backing: Backing? = Backing(onRelease: { released.fulfill() })
        var stage: Stage? = Stage(testingBacking: backing!, onlineDisplayIDs: { [] },
                                  coordinator: coordinator,
                                  fallbackRetirementCompletion: { finished.fulfill() })
        XCTAssertNotNil(stage)
        backing = nil
        stage = nil
        wait(for: [finished, released], timeout: 2)
        XCTAssertEqual(coordinator.deferredRetirementDisplayIDs, [])
        XCTAssertNoThrow(try coordinator.requireNoDeferredRetirements())
        XCTAssertNil(coordinator.failureReason)
    }

}
