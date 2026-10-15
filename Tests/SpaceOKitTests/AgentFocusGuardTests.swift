import XCTest
@testable import SpaceOKit

/// The activation guard against a scripted workspace: no real application is activated.
final class AgentFocusGuardTests: XCTestCase {
    private final class Workspace: @unchecked Sendable {
        private let lock = NSLock()
        private var front: AgentFocusGuard.Application?
        private var apps: [pid_t: String] = [:]
        private var agents: Set<pid_t> = []
        private var owners: [pid_t: String] = [:]
        private var operatorControlled: Set<String> = []
        private var activationTakes = true
        private var isolationLags = 0
        private var frontLag: (reads: Int, stale: AgentFocusGuard.Application?) = (0, nil)
        private var time: TimeInterval = 1_000
        private(set) var activations: [pid_t] = []

        func add(_ pid: pid_t, _ name: String, agent: Bool = false) {
            lock.withLock {
                apps[pid] = name
                if agent { agents.insert(pid); owners[pid] = "session-\(pid)" }
            }
        }
        func adopt(_ pid: pid_t) { lock.withLock { agents.insert(pid); owners[pid] = "session-\(pid)" } }
        func quit(_ pid: pid_t) { lock.withLock { _ = apps.removeValue(forKey: pid) } }
        func bringToFront(_ pid: pid_t) {
            lock.withLock { front = apps[pid].map { .init(pid: pid, name: $0) } }
        }
        func setOperatorControlled(_ pid: pid_t) { lock.withLock { _ = operatorControlled.insert("session-\(pid)") } }
        func ignoreActivation() { lock.withLock { activationTakes = false } }
        /// The Space or input route stays with the agent for this many isolation checks.
        func lagIsolation(_ checks: Int) { lock.withLock { isolationLags = checks } }
        /// The next `reads` frontmost queries still report the application that was in front.
        func bringToFrontLagging(_ pid: pid_t, reads: Int) {
            lock.withLock {
                frontLag = (reads, front)
                front = apps[pid].map { .init(pid: pid, name: $0) }
            }
        }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
        var frontPID: pid_t? { lock.withLock { front?.pid } }
        var activationCount: Int { lock.withLock { activations.count } }

        var environment: AgentFocusGuard.Environment {
            .init(
                frontmost: {
                    self.lock.withLock {
                        guard self.frontLag.reads > 0 else { return self.front }
                        self.frontLag.reads -= 1
                        return self.frontLag.stale
                    }
                },
                application: { pid in self.lock.withLock { self.apps[pid].map { .init(pid: pid, name: $0) } } },
                activate: { pid in
                    self.lock.withLock {
                        self.activations.append(pid)
                        guard self.activationTakes, let name = self.apps[pid] else { return self.apps[pid] != nil }
                        self.front = .init(pid: pid, name: name)
                        return true
                    }
                },
                isAgent: { pid in self.lock.withLock { self.agents.contains(pid) } },
                owner: { pid in self.lock.withLock { self.owners[pid] } },
                isOperatorControlled: { session in self.lock.withLock { self.operatorControlled.contains(session) } },
                isolationIntact: {
                    self.lock.withLock {
                        guard self.isolationLags > 0 else { return true }
                        self.isolationLags -= 1
                        return false
                    }
                },
                uptime: { self.lock.withLock { self.time } },
                sleep: { seconds in self.lock.withLock { self.time += seconds } })
        }
    }

    private func workspace() -> Workspace {
        let workspace = Workspace()
        workspace.add(10, "Editor")
        workspace.add(11, "Notes")
        workspace.add(20, "Google Chrome", agent: true)
        return workspace
    }

    func testNothingHappensWhileThePersonsApplicationIsInFront() {
        let workspace = workspace()
        workspace.bringToFront(10)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 10), .notNeeded)
        XCTAssertEqual(workspace.activationCount, 0)
    }

    func testAgentActivationReturnsToTheApplicationFrontmostBeforeTheAction() {
        let workspace = workspace()
        workspace.bringToFront(20)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 11),
                       .restored(app: "Notes", agentPID: 20, agentName: "Google Chrome", session: "session-20"))
        XCTAssertEqual(workspace.frontPID, 11)
    }

    func testWithoutAPreferenceTheMostRecentPersonalApplicationIsUsed() {
        let workspace = workspace()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guardian.noteActivation(.init(pid: 11, name: "Notes"))
        workspace.bringToFront(20)
        // An agent process named as the preference is never the destination.
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 20),
                       .restored(app: "Notes", agentPID: 20, agentName: "Google Chrome", session: "session-20"))
    }

    func testOperatorControlIsLeftAlone() {
        let workspace = workspace()
        workspace.bringToFront(20)
        workspace.setOperatorControlled(20)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 10), .operatorControl(session: "session-20"),
                       "a person working in the agent's application keeps it")
        XCTAssertEqual(workspace.activationCount, 0)
        XCTAssertEqual(workspace.frontPID, 20)
    }

    func testUnconfirmedRestorationIsReportedAsUnavailable() {
        let workspace = workspace()
        workspace.bringToFront(20)
        workspace.ignoreActivation()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guard case let .unavailable(reason, _, _) = guardian.restoreIfAgentFront(preferring: 10, timeout: 0.2) else {
            return XCTFail("an activation that did not take is not a restoration")
        }
        XCTAssertTrue(reason.contains("Editor"), reason)
    }

    func testAProcessThatKeepsTakingActivationStopsBeingRestored() {
        let workspace = workspace()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        for _ in 0..<AgentFocusGuard.maximumRestores {
            workspace.bringToFront(20)
            guard case .restored = guardian.restoreIfAgentFront(preferring: 10) else {
                return XCTFail("restorations within the budget succeed")
            }
        }
        workspace.bringToFront(20)
        guard case .unavailable = guardian.restoreIfAgentFront(preferring: 10) else {
            return XCTFail("the guard must not trade the front with the agent indefinitely")
        }
        XCTAssertEqual(workspace.activationCount, AgentFocusGuard.maximumRestores)
        workspace.advance(AgentFocusGuard.restoreWindow + 1)
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 10),
                       .restored(app: "Editor", agentPID: 20, agentName: "Google Chrome", session: "session-20"))
    }

    func testBackgroundActivationIsReturnedAndReported() {
        let workspace = workspace()
        workspace.bringToFront(10)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        let reported = expectation(description: "background restoration reported")
        guardian.start(observingWorkspace: false) { outcome in
            XCTAssertEqual(outcome, .restored(app: "Editor", agentPID: 20, agentName: "Google Chrome", session: "session-20"))
            reported.fulfill()
        }
        workspace.bringToFront(20)
        guardian.noteActivation(.init(pid: 20, name: "Google Chrome"))
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(workspace.frontPID, 10)
        guardian.stop()
    }

    func testRestorationWaitsForTheWholeRouteAndReportsALaggingOne() {
        let workspace = workspace()
        workspace.bringToFront(20)
        workspace.lagIsolation(3)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 10),
                       .restored(app: "Editor", agentPID: 20, agentName: "Google Chrome", session: "session-20"),
                       "a short lag is waited out")

        let stuck = self.workspace()
        stuck.bringToFront(20)
        stuck.lagIsolation(Int.max)
        let second = AgentFocusGuard(environment: stuck.environment)
        guard case let .unavailable(reason, 20, "session-20") = second.restoreIfAgentFront(preferring: 10, timeout: 0.3),
              reason.contains("isolation did not recover") else {
            return XCTFail("the front application alone is not a restoration")
        }
    }

    func testARememberedApplicationLaterAdoptedOrQuitIsNotADestination() {
        let workspace = workspace()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guardian.noteActivation(.init(pid: 11, name: "Notes"))
        workspace.adopt(11)
        workspace.bringToFront(11)
        guard case .unavailable(_, 11, "session-11") = guardian.restoreIfAgentFront() else {
            return XCTFail("an adopted process must never be reported as restored to itself")
        }
        XCTAssertEqual(workspace.activationCount, 0)

        let other = self.workspace()
        let second = AgentFocusGuard(environment: other.environment)
        second.noteActivation(.init(pid: 11, name: "Notes"))
        other.quit(11)
        other.bringToFront(20)
        guard case .unavailable = second.restoreIfAgentFront() else {
            return XCTFail("an application that exited is not a destination")
        }
        XCTAssertEqual(other.activationCount, 0)
    }

    func testANonFiniteTimeoutIsBoundedInsteadOfTrapping() {
        let workspace = workspace()
        workspace.bringToFront(20)
        workspace.ignoreActivation()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        for timeout in [TimeInterval.infinity, .nan, -1] {
            workspace.advance(AgentFocusGuard.restoreWindow + 1)
            guard case .unavailable = guardian.restoreIfAgentFront(preferring: 10, timeout: timeout) else {
                return XCTFail("timeout \(timeout) must report unavailable")
            }
        }
    }

    func testRestoreHistoryForEveryProcessExpires() {
        let workspace = workspace()
        workspace.add(21, "Agent Two", agent: true)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        for pid in [pid_t(20), 21] {
            workspace.bringToFront(pid)
            guard case .restored = guardian.restoreIfAgentFront(preferring: 10) else {
                return XCTFail("restoration succeeds")
            }
        }
        XCTAssertEqual(guardian.restoreHistoryCount, 2)
        workspace.advance(AgentFocusGuard.restoreWindow + 1)
        workspace.bringToFront(20)
        _ = guardian.restoreIfAgentFront(preferring: 10)
        XCTAssertEqual(guardian.restoreHistoryCount, 1, "expired histories of other processes are dropped")
    }

    func testANotificationAheadOfTheFrontmostViewIsStillRestored() {
        let workspace = workspace()
        workspace.bringToFront(10)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guardian.noteActivation(.init(pid: 10, name: "Editor"))
        workspace.bringToFrontLagging(20, reads: 5)
        XCTAssertEqual(guardian.restoreAfterActivation(of: .init(pid: 20, name: "Google Chrome")),
                       .restored(app: "Editor", agentPID: 20, agentName: "Google Chrome", session: "session-20"))
    }

    func testNoKnownPersonalApplicationMeansNoActivation() {
        let workspace = workspace()
        workspace.bringToFront(20)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guard case .unavailable = guardian.restoreIfAgentFront() else {
            return XCTFail("with nothing to return to, report rather than guess")
        }
        XCTAssertEqual(workspace.activationCount, 0)
    }

    private func report(failing dimensions: [IsolationDimension]) -> IsolationReport {
        IsolationReport(checks: IsolationDimension.allCases.map { dimension in
            let failed = dimensions.contains(dimension)
            return IsolationCheckReport(dimension: dimension, coverage: .observed,
                status: failed ? .failed : .passed, evidence: "fixture",
                failures: failed ? ["\(dimension.rawValue) changed"] : [])
        })
    }

    func testOnlyAnActivationBreachIsRepairedByReturningActivation() {
        XCTAssertTrue(SessionManager.isActivationOnlyBreach(report(failing: [.menuBarOwner, .windowServerFrontProcess, .activeSpace])))
        XCTAssertTrue(SessionManager.isActivationOnlyBreach(report(failing: [.keyInputRoute, .textInputRoute])))
        XCTAssertFalse(SessionManager.isActivationOnlyBreach(report(failing: [])), "nothing to repair")
        XCTAssertFalse(SessionManager.isActivationOnlyBreach(report(failing: [.cursorLocation])),
                       "a moved pointer is never explained by activation")
        XCTAssertFalse(SessionManager.isActivationOnlyBreach(report(failing: [.menuBarOwner, .cursorLocation])))
    }

    func testOperatorControlFollowsTheSession() {
        AgentActivity.setOperatorControl(session: "guard-test", true)
        XCTAssertTrue(AgentActivity.isUnderOperatorControl("guard-test"))
        AgentActivity.setOperatorControl(session: "guard-test", false)
        XCTAssertFalse(AgentActivity.isUnderOperatorControl("guard-test"))
    }
}

/// With no action in flight, an activation SpaceO could not return is a breach to report now.
final class UnrestoredActivationTests: XCTestCase {
    private final class Backing: StageDisplayBacking, @unchecked Sendable {
        let displayID: CGDirectDisplayID = 92_053
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let pixelWidth: Int? = 1280
        let valid = true
        func invalidate() {}
    }

    func testAnUnrestoredBackgroundActivationPausesItsSession() async throws {
        let backing = Backing()
        let stage = Stage(testingBacking: backing, onlineDisplayIDs: { [backing.displayID] })
        let identity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        let app = LaunchedApp(pid: identity.pid, identity: identity, bundleIdentifier: "dev.spaceo.unrestored",
            name: "Agent", url: URL(fileURLWithPath: "/Applications/Agent.app"), startedByUs: false,
            devToolsPort: nil, temporaryProfile: nil)
        let manager = SessionManager(
            pool: DisplayPool(stageFactory: { _, _, _, _ in stage }), runJanitor: false,
            sessionFactory: { id, slot in
                try AgentSession(id: id, slot: slot,
                    teardownDriver: SessionAppTeardownDriver(isAlive: { _ in false }, quit: { _, _ in },
                        waitForExit: { _, _ in [] }, cleanupTemporaryProfile: { _ in }),
                    windowDriver: .windowlessForTesting, watcherFactory: { _, _ in throw CancellationError() },
                    initialApps: [app])
            })
        let created = await manager.handle(TestController.createRequest(session: "unrestored"))
        XCTAssertTrue(created.ok, created.error ?? "")

        // A session that does not own the process (a reused name) is never paused for it.
        await manager.pauseAfterUnrestoredActivation(session: "unrestored", agentPID: 4_242_424, reason: "fixture")
        var listing = await manager.handle(TestController.request("session.list"))
        var row = try XCTUnwrap(listing.sessions?.first { $0.id == "unrestored" })
        XCTAssertNotEqual(row.inputPaused, true)

        await manager.pauseAfterUnrestoredActivation(session: "unrestored", agentPID: getpid(), reason: "fixture")
        listing = await manager.handle(TestController.request("session.list"))
        row = try XCTUnwrap(listing.sessions?.first { $0.id == "unrestored" })
        XCTAssertEqual(row.inputPaused, true)
        XCTAssertNil(row.agentPauseReason, "an isolation pause, not one the agent asked for")

        var destroy = TestController.request("session.destroy", session: "unrestored")
        destroy.quitApps = false
        let cleaned = await manager.handle(destroy)
        XCTAssertTrue(cleaned.ok, cleaned.error ?? "")
    }
}
