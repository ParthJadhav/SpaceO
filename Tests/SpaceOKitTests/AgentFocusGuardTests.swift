import XCTest
@testable import SpaceOKit

/// The activation guard against a scripted workspace: no real application is activated.
final class AgentFocusGuardTests: XCTestCase {
    private final class Workspace: @unchecked Sendable {
        private let lock = NSLock()
        private var front: AgentFocusGuard.Application?
        private var apps: [pid_t: String] = [:]
        private var agents: Set<pid_t> = []
        private var operatorControlled: Set<pid_t> = []
        private var activationTakes = true
        private var time: TimeInterval = 1_000
        private(set) var activations: [pid_t] = []

        func add(_ pid: pid_t, _ name: String, agent: Bool = false) {
            lock.withLock {
                apps[pid] = name
                if agent { agents.insert(pid) }
            }
        }
        func bringToFront(_ pid: pid_t) {
            lock.withLock { front = apps[pid].map { .init(pid: pid, name: $0) } }
        }
        func setOperatorControlled(_ pid: pid_t) { lock.withLock { _ = operatorControlled.insert(pid) } }
        func ignoreActivation() { lock.withLock { activationTakes = false } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
        var frontPID: pid_t? { lock.withLock { front?.pid } }
        var activationCount: Int { lock.withLock { activations.count } }

        var environment: AgentFocusGuard.Environment {
            .init(
                frontmost: { self.lock.withLock { self.front } },
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
                isOperatorControlled: { pid in self.lock.withLock { self.operatorControlled.contains(pid) } },
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
                       .restored(app: "Notes", agentPID: 20, agentName: "Google Chrome"))
        XCTAssertEqual(workspace.frontPID, 11)
    }

    func testWithoutAPreferenceTheMostRecentPersonalApplicationIsUsed() {
        let workspace = workspace()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guardian.noteActivation(.init(pid: 11, name: "Notes"))
        workspace.bringToFront(20)
        // An agent process named as the preference is never the destination.
        XCTAssertEqual(guardian.restoreIfAgentFront(preferring: 20),
                       .restored(app: "Notes", agentPID: 20, agentName: "Google Chrome"))
    }

    func testOperatorControlIsLeftAlone() {
        let workspace = workspace()
        workspace.bringToFront(20)
        workspace.setOperatorControlled(20)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guard case .unavailable = guardian.restoreIfAgentFront(preferring: 10) else {
            return XCTFail("a person working in the agent's application keeps it")
        }
        XCTAssertEqual(workspace.activationCount, 0)
        XCTAssertEqual(workspace.frontPID, 20)
    }

    func testUnconfirmedRestorationIsReportedAsUnavailable() {
        let workspace = workspace()
        workspace.bringToFront(20)
        workspace.ignoreActivation()
        let guardian = AgentFocusGuard(environment: workspace.environment)
        guard case let .unavailable(reason) = guardian.restoreIfAgentFront(preferring: 10, timeout: 0.2) else {
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
                       .restored(app: "Editor", agentPID: 20, agentName: "Google Chrome"))
    }

    func testBackgroundActivationIsReturnedAndReported() {
        let workspace = workspace()
        workspace.bringToFront(10)
        let guardian = AgentFocusGuard(environment: workspace.environment)
        let reported = expectation(description: "background restoration reported")
        guardian.start(observingWorkspace: false) { outcome in
            XCTAssertEqual(outcome, .restored(app: "Editor", agentPID: 20, agentName: "Google Chrome"))
            reported.fulfill()
        }
        workspace.bringToFront(20)
        guardian.noteActivation(.init(pid: 20, name: "Google Chrome"))
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(workspace.frontPID, 10)
        guardian.stop()
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
