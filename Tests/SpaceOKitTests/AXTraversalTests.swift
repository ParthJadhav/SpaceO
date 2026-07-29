import XCTest
import ApplicationServices
import CoreGraphics
@testable import SpaceOKit

final class AXTraversalTests: XCTestCase {
    func testOversizedChildrenArePagedAndStopAtNodeBudget() throws {
        let provider = FakeAXProvider()
        provider.childCounts[0] = 10_000
        let clock = TestMonotonicClock()
        let limits = AXTraversalLimits(
            maxDepth: 8,
            maxNodes: 5,
            timeout: 1,
            maxAXCalls: 100,
            maxAllocatedBytes: 1_024 * 1_024,
            childPageSize: 3,
            maxCallDuration: 0.1)
        let budget = try AXTraversalBudget(
            limits: limits, now: { clock.value }, isCancelled: { false })

        XCTAssertThrowsError(
            try AXTraversal.walk(root: 0, provider: provider, budget: budget)
        ) { error in
            XCTAssertEqual((error as? AXTraversalStopped)?.reason, .nodes)
        }

        XCTAssertEqual(provider.pageRequests.map(\.maxValues), [3, 1])
        XCTAssertTrue(provider.pageRequests.allSatisfy { $0.maxValues <= limits.childPageSize })
        XCTAssertFalse(provider.pageRequests.contains { $0.maxValues == 10_000 })
        XCTAssertEqual(budget.nodes, limits.maxNodes)
    }

    func testDelayedProviderStopsAtMonotonicDeadline() throws {
        let provider = FakeAXProvider()
        let clock = TestMonotonicClock()
        provider.afterProviderCall = { clock.advance(by: 6_000_000) }
        let limits = AXTraversalLimits(
            maxDepth: 8,
            maxNodes: 100,
            timeout: 0.020,
            maxAXCalls: 100,
            maxAllocatedBytes: 1_024 * 1_024,
            childPageSize: 8,
            maxCallDuration: 0.010)
        let budget = try AXTraversalBudget(
            limits: limits, now: { clock.value }, isCancelled: { false })

        XCTAssertThrowsError(
            try AXTraversal.walk(root: 0, provider: provider, budget: budget)
        ) { error in
            XCTAssertEqual((error as? AXTraversalStopped)?.reason, .deadline)
        }

        XCTAssertLessThanOrEqual(provider.providerCallCount, 4)
        XCTAssertGreaterThanOrEqual(clock.value, 20_000_000)
    }

    func testAXCallBudgetStopsBeforeAnotherProviderCall() throws {
        let provider = FakeAXProvider()
        let clock = TestMonotonicClock()
        let limits = AXTraversalLimits(
            maxDepth: 8,
            maxNodes: 100,
            timeout: 1,
            maxAXCalls: 2,
            maxAllocatedBytes: 1_024 * 1_024,
            childPageSize: 8,
            maxCallDuration: 0.1)
        let budget = try AXTraversalBudget(
            limits: limits, now: { clock.value }, isCancelled: { false })

        XCTAssertThrowsError(
            try AXTraversal.walk(root: 0, provider: provider, budget: budget)
        ) { error in
            XCTAssertEqual((error as? AXTraversalStopped)?.reason, .axCalls)
        }
        XCTAssertEqual(provider.providerCallCount, limits.maxAXCalls)
    }

    func testAggregateAllocationBudgetStopsTraversal() throws {
        let provider = FakeAXProvider()
        let clock = TestMonotonicClock()
        let limits = AXTraversalLimits(
            maxDepth: 8,
            maxNodes: 100,
            timeout: 1,
            maxAXCalls: 100,
            maxAllocatedBytes: 1,
            childPageSize: 8,
            maxCallDuration: 0.1)
        let budget = try AXTraversalBudget(
            limits: limits, now: { clock.value }, isCancelled: { false })

        XCTAssertThrowsError(
            try AXTraversal.walk(root: 0, provider: provider, budget: budget)
        ) { error in
            XCTAssertEqual((error as? AXTraversalStopped)?.reason, .allocation)
        }
        XCTAssertEqual(budget.nodes, 1)
    }

    func testCancellationIsCheckedBetweenProviderCalls() throws {
        let provider = FakeAXProvider()
        let clock = TestMonotonicClock()
        let limits = AXTraversalLimits(
            maxDepth: 8,
            maxNodes: 100,
            timeout: 1,
            maxAXCalls: 100,
            maxAllocatedBytes: 1_024 * 1_024,
            childPageSize: 8,
            maxCallDuration: 0.1)
        let budget = try AXTraversalBudget(
            limits: limits,
            now: { clock.value },
            isCancelled: { provider.providerCallCount >= 2 })

        XCTAssertThrowsError(
            try AXTraversal.walk(root: 0, provider: provider, budget: budget)
        ) { error in
            XCTAssertEqual((error as? AXTraversalStopped)?.reason, .cancelled)
        }
        XCTAssertEqual(provider.providerCallCount, 2)
    }

    func testEveryDescendantCallReceivesABoundedTimeout() throws {
        let provider = FakeAXProvider()
        provider.childCounts[0] = 1
        let clock = TestMonotonicClock()
        let limits = AXTraversalLimits(
            maxDepth: 8,
            maxNodes: 2,
            timeout: 1,
            maxAXCalls: 100,
            maxAllocatedBytes: 1_024 * 1_024,
            childPageSize: 8,
            maxCallDuration: 0.075)
        let budget = try AXTraversalBudget(
            limits: limits, now: { clock.value }, isCancelled: { false })

        let output = try AXTraversal.walk(root: 0, provider: provider, budget: budget)

        XCTAssertEqual(output.nodes.count, 2)
        XCTAssertTrue(provider.timeoutElements.contains(0))
        XCTAssertTrue(provider.timeoutElements.contains(1))
        XCTAssertTrue(provider.timeouts.allSatisfy { $0 > 0 && $0 <= 0.0751 })
    }

    func testProviderThatRejectsTimeoutIsNeverCalledUnbounded() throws {
        let provider = FakeAXProvider()
        provider.acceptsMessagingTimeout = false
        let clock = TestMonotonicClock()
        let budget = try AXTraversalBudget(
            limits: AXTraversalLimits(),
            now: { clock.value },
            isCancelled: { false })

        XCTAssertThrowsError(
            try AXTraversal.walk(root: 0, provider: provider, budget: budget)
        ) { error in
            XCTAssertEqual((error as? AXTraversalStopped)?.reason, .provider)
        }
        XCTAssertEqual(provider.providerCallCount, 0)
        XCTAssertEqual(provider.timeoutElements, [0])
    }
}

private final class TestMonotonicClock {
    private(set) var value: UInt64 = 0

    func advance(by nanoseconds: UInt64) {
        value &+= nanoseconds
    }
}

private final class FakeAXProvider: AXTraversalProviding {
    struct PageRequest: Equatable {
        let element: Int
        let start: Int
        let maxValues: Int
    }

    var childCounts: [Int: Int] = [:]
    var acceptsMessagingTimeout = true
    var afterProviderCall: () -> Void = {}
    private(set) var providerCallCount = 0
    private(set) var pageRequests: [PageRequest] = []
    private(set) var timeoutElements: [Int] = []
    private(set) var timeouts: [Float] = []

    func setMessagingTimeout(_ element: Int, seconds: Float) -> Bool {
        timeoutElements.append(element)
        timeouts.append(seconds)
        return acceptsMessagingTimeout
    }

    func string(_ element: Int, attribute: String) -> String? {
        called()
        if attribute == kAXRoleAttribute as String {
            return "AXButton"
        }
        if attribute == kAXTitleAttribute as String {
            return "Node \(element)"
        }
        return nil
    }

    func bool(_ element: Int, attribute: String) -> Bool? {
        called()
        return true
    }

    func actions(_ element: Int) -> [String] {
        called()
        return [kAXPressAction as String]
    }

    func point(_ element: Int, attribute: String) -> CGPoint? {
        called()
        return CGPoint(x: element, y: element)
    }

    func size(_ element: Int, attribute: String) -> CGSize? {
        called()
        return CGSize(width: 10, height: 10)
    }

    func arrayCount(_ element: Int, attribute: String) -> Int {
        called()
        return childCounts[element, default: 0]
    }

    func elements(
        _ element: Int,
        attribute: String,
        start: Int,
        maxValues: Int
    ) -> [Int] {
        called()
        pageRequests.append(
            PageRequest(element: element, start: start, maxValues: maxValues))
        let count = childCounts[element, default: 0]
        let end = min(count, start + maxValues)
        guard start < end else { return [] }
        return (start..<end).map { $0 + 1 }
    }

    func windowID(_ element: Int) -> CGWindowID {
        called()
        return CGWindowID(element)
    }

    private func called() {
        providerCallCount += 1
        afterProviderCall()
    }
}
