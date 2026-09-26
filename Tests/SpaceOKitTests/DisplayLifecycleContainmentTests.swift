import XCTest
import CoreGraphics
@testable import SpaceOKit

final class DisplayLifecycleContainmentTests: XCTestCase {
    private final class Backing: StageDisplayBacking, @unchecked Sendable {
        let displayID: CGDirectDisplayID = 99_111
        let bounds = CGRect(x: 2000, y: 0, width: 1280, height: 800)
        let valid = true
        let block: () -> Void
        init(_ block: @escaping () -> Void = {}) { self.block = block }
        func invalidate() { block() }
    }

    private final class WeakBacking: @unchecked Sendable {
        private let lock = NSLock()
        private weak var storage: Backing?
        var value: Backing? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    func testBlockedInventoryReturnsFalseAndNoRetryRuns() {
        let unblock = DispatchSemaphore(value: 0)
        let completed = expectation(description: "late inventory returned")
        let coordinator = DisplayLifecycleCoordinator()
        let backing = Backing()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: {
            unblock.wait()
            completed.fulfill()
            return []
        }, coordinator: coordinator)
        let start = ContinuousClock.now
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0.1))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(stage.displayID, 99_111)
        XCTAssertFalse(stage.isValid)
        XCTAssertNotNil(coordinator.failureReason)
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0.1))
        unblock.signal()
        wait(for: [completed], timeout: 1)
        // The late empty inventory cannot turn the failed operation back into success.
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0.1))
    }

    func testBlockedBackingInvalidationAlsoHasABoundedCaller() {
        let unblock = DispatchSemaphore(value: 0)
        let completed = expectation(description: "backing returned")
        let stage = Stage(testingBacking: Backing {
            unblock.wait()
            completed.fulfill()
        }, onlineDisplayIDs: {
            XCTFail("must not query after a timed-out mutation")
            return []
        })
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0.1))
        XCTAssertEqual(stage.displayID, 99_111)
        unblock.signal()
        wait(for: [completed], timeout: 1)
    }

    func testBlockedFailurePersistenceCannotExtendTheCallerDeadlineIndefinitely() {
        let unblockWorker = DispatchSemaphore(value: 0)
        let unblockFailure = DispatchSemaphore(value: 0)
        let saved = expectation(description: "failure persistence released")
        let coordinator = DisplayLifecycleCoordinator { _ in
            unblockFailure.wait()
            saved.fulfill()
        }
        let start = ContinuousClock.now
        XCTAssertThrowsError(try coordinator.perform(timeout: 0.1) { _ in unblockWorker.wait() })
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertNotNil(coordinator.failureReason)
        XCTAssertThrowsError(try coordinator.perform(timeout: 0.1) { _ in XCTFail("must not restart work") })
        unblockWorker.signal()
        unblockFailure.signal()
        wait(for: [saved], timeout: 1)
    }

    func testFailedInventoryIsUnknownRatherThanSuccessfulRemoval() {
        let stage = Stage(testingBacking: Backing(), onlineDisplayIDs: {
            throw SpaceOError.stageCreationFailed("injected display service failure")
        })
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0.1))
        XCTAssertEqual(stage.displayID, 99_111)
    }

    func testManagerDoesNotReenterDisplayIPCToPruneATimedOutRetirement() async throws {
        let stage = Stage(testingBacking: Backing(), onlineDisplayIDs: {
            throw SpaceOError.stageCreationFailed("injected unavailable inventory")
        })
        let pool = DisplayPool(stageFactory: { _, _, _, _ in stage },
                               stageRetirer: { $0.invalidate(waitingForRemoval: 0.1) })
        let manager = SessionManager(pool: pool, runJanitor: false,
                                     onlineDisplayIDs: {
            XCTFail("must preserve unknown display IDs without another synchronous query")
            return []
        }, sessionFactory: { AgentSession(id: $0, slot: $1) })
        let created = await manager.handle(TestController.createRequest())
        XCTAssertTrue(created.ok)
        var destroy = TestController.request("session.destroy")
        destroy.full = true
        let result = await manager.handle(destroy)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.teardown?.stillAttachedDisplayIDs, [99_111])
        let ping = await manager.handle(Request(cmd: "ping"))
        XCTAssertTrue(ping.message?.contains("failed display teardown: [99111]") == true)
        let lost = await manager.revalidateDisplays(reason: "injected test event")
        XCTAssertTrue(lost.isEmpty)
    }

    func testLateCreationResultIsRetainedWithoutImplicitTeardown() {
        let unblock = DispatchSemaphore(value: 0)
        let completed = expectation(description: "late creation stopped")
        let coordinator = DisplayLifecycleCoordinator()
        let observed = WeakBacking()
        XCTAssertThrowsError(try coordinator.perform(timeout: 0.1) { operation in
            unblock.wait()
            let backing = Backing()
            operation.retain(backing)
            observed.value = backing
            defer { completed.fulfill() }
            try operation.check()
            XCTFail("a late creation must not be published")
        })
        unblock.signal()
        wait(for: [completed], timeout: 1)
        XCTAssertNotNil(observed.value, "ARC must not implicitly detach a late display")
        XCTAssertThrowsError(try coordinator.perform(timeout: 0.1) { _ in
            XCTFail("circuit must reject subsequent work")
        })
    }

    func testQueuedOperationNeverStartsAfterItsDeadlineTripsTheCircuit() {
        let coordinator = DisplayLifecycleCoordinator()
        let started = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let finished = expectation(description: "first operation stopped")
        DispatchQueue.global().async {
            do {
                try coordinator.perform(timeout: 2) { operation in
                    started.signal()
                    unblock.wait()
                    try operation.check()
                }
                XCTFail("the first operation must observe the circuit failure")
            } catch { /* Expected: the queued operation's deadline opened the circuit. */ }
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try coordinator.perform(timeout: 0.1) { _ in
            XCTFail("a timed-out queued operation must never execute")
        })
        unblock.signal()
        wait(for: [finished], timeout: 1)
    }

    func testRetirementPreambleConsumesTheSameDeadlineAndCannotInvalidateLate() {
        let unblock = DispatchSemaphore(value: 0)
        let returned = expectation(description: "late preflight returned")
        let stage = Stage(testingBacking: Backing { XCTFail("expired preflight must not detach a display") },
                          onlineDisplayIDs: { XCTFail("expired preflight must not query removal"); return [] },
                          configuration: {
            unblock.wait()
            returned.fulfill()
            return nil
        })
        XCTAssertFalse(stage.invalidate(waitingForRemoval: 0.1))
        unblock.signal()
        wait(for: [returned], timeout: 1)
        XCTAssertTrue(stage.hasLifecycleFailure)
    }

    func testPoolNeverPublishesAllocationAfterLifecycleFailure() throws {
        for exclusive in [false, true] {
            let coordinator = DisplayLifecycleCoordinator()
            let stage = Stage(testingBacking: Backing(), onlineDisplayIDs: { [] }, coordinator: coordinator)
            coordinator.trip("injected managed-Space query deadline")
            let pool = DisplayPool(stageFactory: { _, _, _, _ in stage })
            XCTAssertThrowsError(try exclusive ? pool.allocateExclusive() : pool.allocate())
            XCTAssertEqual(pool.sessionCount, 0)
            XCTAssertEqual(pool.displayCount, 0)
        }
    }

    private func withJournal(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("safety.json").path)
    }

    func testLeaseExcludesOtherOwnersAndRetainsRateHistoryAcrossRestart() throws {
        try withJournal { path in
            var first: DisplayLifecycleLease? = DisplayLifecycleLease(path: path)
            try first!.acquire()
            let other = DisplayLifecycleLease(path: path)
            XCTAssertThrowsError(try other.acquire())
            let now = Date(timeIntervalSince1970: 1000)
            for _ in 0..<4 {
                try first!.begin(creation: true, now: now)
                try first!.finish()
            }
            XCTAssertThrowsError(try first!.begin(creation: true, now: now))
            first = nil
            try other.acquire()
            XCTAssertThrowsError(try other.begin(creation: true, now: now))
            try other.begin(creation: true, now: now.addingTimeInterval(60))
            try other.finish()
        }
    }

    func testInterruptedMutationAndCircuitFailureSurviveRestart() throws {
        for trip in [false, true] {
            try withJournal { path in
                var owner: DisplayLifecycleLease? = DisplayLifecycleLease(path: path)
                try owner!.acquire()
                try owner!.begin(creation: true)
                if trip { owner!.trip("injected timeout") }
                owner = nil
                let restarted = DisplayLifecycleLease(path: path)
                XCTAssertThrowsError(try restarted.acquire())
            }
        }
    }

    func testLiveFailureBeforeAnyDisplayMutationSurvivesRestart() throws {
        try withJournal { path in
            var owner: DisplayLifecycleLease? = DisplayLifecycleLease(path: path)
            try owner!.acquire()
            try owner!.beginLiveTest()
            // No Stage, mutation or failure callback is needed for interruption to persist.
            owner = nil
            let restarted = DisplayLifecycleLease(path: path)
            XCTAssertThrowsError(try restarted.acquire())
            XCTAssertThrowsError(try restarted.acquire(), "a second acquire must not bypass the latch")
        }
    }

    func testCompletedLiveCaseAllowsMutationAndAnotherCaseAndRestart() throws {
        try withJournal { path in
            var owner: DisplayLifecycleLease? = DisplayLifecycleLease(path: path)
            try owner!.acquire()
            for _ in 0..<2 {
                try owner!.beginLiveTest()
                try owner!.begin(creation: true)
                try owner!.finish()
                try owner!.finishLiveTest()
            }
            owner = nil
            try DisplayLifecycleLease(path: path).acquire()
        }
    }

    func testTenMinuteBudgetCannotBeBypassedByPerMinutePacing() throws {
        try withJournal { path in
            let lease = DisplayLifecycleLease(path: path)
            try lease.acquire()
            let start = Date(timeIntervalSince1970: 1000)
            for index in 0..<12 {
                try lease.begin(creation: true, now: start.addingTimeInterval(Double(index * 30)))
                try lease.finish()
            }
            XCTAssertThrowsError(try lease.begin(creation: true, now: start.addingTimeInterval(360))) { error in
                guard case let SpaceOError.resourceLimit(_, _, retry) = error else {
                    return XCTFail("expected a creation budget refusal")
                }
                XCTAssertEqual(retry, 240)
            }
            try lease.begin(creation: true, now: start.addingTimeInterval(600))
            try lease.finish()
            XCTAssertThrowsError(try lease.begin(creation: true, now: start))
        }
    }

    func testMinuteBudgetReturnsItsActualRemainingWait() throws {
        try withJournal { path in
            let lease = DisplayLifecycleLease(path: path)
            try lease.acquire()
            let start = Date(timeIntervalSince1970: 1000)
            for _ in 0..<4 { try lease.begin(creation: true, now: start); try lease.finish() }
            XCTAssertThrowsError(try lease.begin(creation: true, now: start.addingTimeInterval(12))) { error in
                guard case let SpaceOError.resourceLimit(_, _, retry) = error else {
                    return XCTFail("expected a creation budget refusal")
                }
                XCTAssertEqual(retry, 48)
            }
        }
    }

    func testDiagnosticReportsLatchesWithoutTakingLeaseOrChangingJournal() throws {
        try withJournal { path in
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .ready)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            let owner = DisplayLifecycleLease(path: path)
            try owner.acquire()
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .ready)
            try owner.beginLiveTest()
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .blocked)
            try owner.finishLiveTest()
            try owner.begin(creation: true)
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .blocked)
            try owner.finish()
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .ready)
            owner.trip("injected timeout")
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(DisplayLifecycleLease.status(path: path),
                           DisplaySafetyStatus(state: .blocked, reason: "injected timeout"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        }
    }

    func testDiagnosticRefusesMalformedNonPrivateAndNonRegularJournals() throws {
        try withJournal { path in
            var owner: DisplayLifecycleLease? = DisplayLifecycleLease(path: path)
            try owner!.acquire()
            owner = nil
            try Data("invalid".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .unknown)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .unknown)
            try FileManager.default.removeItem(atPath: path)
            XCTAssertEqual(mkfifo(path, 0o600), 0)
            XCTAssertEqual(DisplayLifecycleLease.status(path: path).state, .unknown)
        }
    }

    func testMalformedOrNonPrivateJournalRefusesAdmission() throws {
        try withJournal { path in
            var owner: DisplayLifecycleLease? = DisplayLifecycleLease(path: path)
            try owner!.acquire()
            owner = nil
            try Data("invalid".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try DisplayLifecycleLease(path: path).acquire())
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            XCTAssertThrowsError(try DisplayLifecycleLease(path: path).acquire())
        }
    }
}
