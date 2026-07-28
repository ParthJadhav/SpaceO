import XCTest
@testable import SpaceOKit

/// Deterministic SPAO-124 regressions. These exercise the exact coordinators used by
/// `SessionManager` and `AgentSession` without creating a virtual display or GUI process.
final class SessionLifecycleRaceTests: XCTestCase {

    private final class Resources: @unchecked Sendable {
        private let lock = NSLock()
        private var apps = 0
        private var displays: Int

        init(displays: Int) {
            self.displays = displays
        }

        func registerPartiallyLaunchedApp() {
            lock.withLock { apps += 1 }
        }

        func cleanSession() {
            lock.withLock {
                if apps > 0 { apps -= 1 }
            }
        }

        func retireAllDisplays() {
            lock.withLock { displays = 0 }
        }

        var snapshot: (apps: Int, displays: Int) {
            lock.withLock { (apps, displays) }
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [String] { lock.withLock { values } }
    }

    func testDestroyWaitsForInFlightLaunchThenCleansPartialResources() async throws {
        let lifecycle = SessionLifecycle()
        let resources = Resources(displays: 1)
        let launchLease = try XCTUnwrap(lifecycle.beginOperation())

        let destroy = Task.detached {
            lifecycle.destroy {
                resources.cleanSession()
                resources.retireAllDisplays()
            }
        }

        while lifecycle.currentState == .active { await Task.yield() }
        XCTAssertEqual(lifecycle.currentState, .destroying)
        XCTAssertEqual(resources.snapshot.displays, 1,
                       "destroy must not retire the tile under an in-flight launch")

        // The process appears after destroy was requested, matching the original actor-
        // reentrancy race. Cleanup must wait long enough to see and remove it.
        resources.registerPartiallyLaunchedApp()
        launchLease.finish()

        let performedCleanup = await destroy.value
        XCTAssertTrue(performedCleanup)
        XCTAssertEqual(lifecycle.currentState, .destroyed)
        XCTAssertEqual(resources.snapshot.apps, 0)
        XCTAssertEqual(resources.snapshot.displays, 0)
        XCTAssertNil(lifecycle.beginOperation(),
                     "no operation may start or report success after destruction")
    }

    func testShutdownWaitsForEverySessionAndLeavesZeroResources() async throws {
        let first = SessionLifecycle()
        let second = SessionLifecycle()
        let firstLaunch = try XCTUnwrap(first.beginOperation())
        let secondCapture = try XCTUnwrap(second.beginOperation())
        let resources = Resources(displays: 2)

        let shutdown = Task.detached {
            _ = first.destroy { resources.cleanSession() }
            _ = second.destroy { resources.cleanSession() }
            resources.retireAllDisplays()
        }

        while first.currentState == .active { await Task.yield() }
        resources.registerPartiallyLaunchedApp()
        firstLaunch.finish()

        while second.currentState == .active { await Task.yield() }
        resources.registerPartiallyLaunchedApp()
        XCTAssertEqual(resources.snapshot.displays, 2,
                       "shutdown cannot retire displays while capture is in flight")
        secondCapture.finish()

        await shutdown.value
        XCTAssertEqual(first.currentState, .destroyed)
        XCTAssertEqual(second.currentState, .destroyed)
        XCTAssertEqual(resources.snapshot.apps, 0)
        XCTAssertEqual(resources.snapshot.displays, 0)
    }

    func testManagerGateDoesNotLetDestroyOvertakeLaunch() async {
        let gate = SessionOperationGate()
        let events = EventLog()
        let launch = await gate.enter()

        let destroy = Task.detached {
            let lease = await gate.enter()
            events.append("destroy")
            lease.finish()
        }

        while gate.pendingCount == 0 { await Task.yield() }
        XCTAssertTrue(events.snapshot.isEmpty)

        events.append("launch-finished")
        launch.finish()
        await destroy.value

        XCTAssertEqual(events.snapshot, ["launch-finished", "destroy"])
    }

    func testManagerRejectsCommandsAfterShutdownCompletes() async {
        let manager = SessionManager(runJanitor: false)

        let stopped = await manager.handle(Request(cmd: "daemon.stop"))
        XCTAssertTrue(stopped.ok)

        let lateCommand = await manager.handle(Request(cmd: "ping"))
        XCTAssertFalse(lateCommand.ok)
        XCTAssertTrue(lateCommand.error?.contains("shutting down") == true)
        let isEmpty = await manager.isEmpty
        let displayCount = await manager.displayCount
        XCTAssertTrue(isEmpty)
        XCTAssertEqual(displayCount, 0)
    }
}
