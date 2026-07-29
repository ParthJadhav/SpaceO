import Foundation
import ApplicationServices
import CoreGraphics
import SpaceOPrivate

/// Hard limits for one accessibility-tree request.
///
/// Accessibility providers live in another process. A node limit alone is not enough: a
/// provider can be slow, expose an enormous child array, or return unusually large strings.
/// These limits therefore cover elapsed monotonic time, remote calls, retained nodes, and
/// aggregate data copied from the provider.
public struct AXTraversalLimits: Sendable, Equatable {
    public var maxDepth: Int
    public var maxNodes: Int
    public var timeout: TimeInterval
    public var maxAXCalls: Int
    public var maxAllocatedBytes: Int
    public var childPageSize: Int
    public var maxCallDuration: TimeInterval

    public init(
        maxDepth: Int = 22,
        maxNodes: Int = 1_500,
        timeout: TimeInterval = 3,
        maxAXCalls: Int = 20_000,
        maxAllocatedBytes: Int = 8 * 1_024 * 1_024,
        childPageSize: Int = 32,
        maxCallDuration: TimeInterval = 0.25
    ) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.timeout = timeout
        self.maxAXCalls = maxAXCalls
        self.maxAllocatedBytes = maxAllocatedBytes
        self.childPageSize = childPageSize
        self.maxCallDuration = maxCallDuration
    }

    func validate() throws {
        guard (0...64).contains(maxDepth) else {
            throw SpaceOError.badRequest("AX tree depth must be from 0 through 64")
        }
        guard (1...5_000).contains(maxNodes) else {
            throw SpaceOError.badRequest("AX tree node limit must be from 1 through 5000")
        }
        guard timeout.isFinite, (0.01...30).contains(timeout) else {
            throw SpaceOError.badRequest(
                "AX traversal timeout must be a finite value from 0.01 through 30 seconds")
        }
        guard (1...100_000).contains(maxAXCalls) else {
            throw SpaceOError.badRequest("AX call limit must be from 1 through 100000")
        }
        guard (1...64 * 1_024 * 1_024).contains(maxAllocatedBytes) else {
            throw SpaceOError.badRequest(
                "AX allocation limit must be from 1 byte through 64 MiB")
        }
        guard (1...256).contains(childPageSize) else {
            throw SpaceOError.badRequest("AX child page size must be from 1 through 256")
        }
        guard maxCallDuration.isFinite, (0.001...5).contains(maxCallDuration),
              maxCallDuration <= timeout else {
            throw SpaceOError.badRequest(
                "AX per-call timeout must be finite, from 0.001 through 5 seconds, "
                + "and no greater than the traversal timeout")
        }
    }
}

public enum AXTraversalStopReason: String, Sendable, Equatable {
    case deadline
    case axCalls
    case nodes
    case allocation
    case cancelled
    case provider
}

/// A truthful failure when a provider cannot be read inside the request's safety envelope.
public struct AXTraversalStopped: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public let reason: AXTraversalStopReason
    public let detail: String

    public init(reason: AXTraversalStopReason, detail: String) {
        self.reason = reason
        self.detail = detail
    }

    public var description: String {
        "accessibility traversal stopped (\(reason.rawValue)): \(detail)"
    }

    public var errorDescription: String? {
        description + ". Narrow the target window or retry after the application responds."
    }
}

/// One-call-at-a-time surface used by the bounded walker and its deterministic tests.
///
/// Each method below corresponds to at most one provider IPC. Keeping that boundary explicit
/// makes the AX-call budget meaningful instead of charging a multi-call convenience helper once.
protocol AXTraversalProviding {
    associatedtype Element

    func setMessagingTimeout(_ element: Element, seconds: Float) -> Bool
    func string(_ element: Element, attribute: String) -> String?
    func bool(_ element: Element, attribute: String) -> Bool?
    func actions(_ element: Element) -> [String]
    func point(_ element: Element, attribute: String) -> CGPoint?
    func size(_ element: Element, attribute: String) -> CGSize?
    func arrayCount(_ element: Element, attribute: String) -> Int
    func elements(
        _ element: Element,
        attribute: String,
        start: Int,
        maxValues: Int
    ) -> [Element]
    func windowID(_ element: Element) -> CGWindowID
}

struct SystemAXTraversalProvider: AXTraversalProviding {
    typealias Element = AXUIElement

    func setMessagingTimeout(_ element: AXUIElement, seconds: Float) -> Bool {
        AX.setTimeout(element, seconds: seconds)
    }

    func string(_ element: AXUIElement, attribute: String) -> String? {
        AX.string(element, attribute)
    }

    func bool(_ element: AXUIElement, attribute: String) -> Bool? {
        AX.bool(element, attribute)
    }

    func actions(_ element: AXUIElement) -> [String] {
        AX.actions(element)
    }

    func point(_ element: AXUIElement, attribute: String) -> CGPoint? {
        AX.point(element, attribute)
    }

    func size(_ element: AXUIElement, attribute: String) -> CGSize? {
        AX.size(element, attribute)
    }

    func arrayCount(_ element: AXUIElement, attribute: String) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(
            element, attribute as CFString, &count
        ) == .success, count > 0 else {
            return 0
        }
        return Int(count)
    }

    func elements(
        _ element: AXUIElement,
        attribute: String,
        start: Int,
        maxValues: Int
    ) -> [AXUIElement] {
        guard start >= 0, maxValues > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element,
            attribute as CFString,
            CFIndex(start),
            CFIndex(maxValues),
            &values
        ) == .success, let values else {
            return []
        }
        return values as? [AXUIElement] ?? []
    }

    func windowID(_ element: AXUIElement) -> CGWindowID {
        SPOWindowIDForAXElement(element)
    }
}

struct AXTraversalOutput<Element> {
    let nodes: [AXNode]
    let elements: [Int: Element]
}

/// Mutable request accounting. This object never escapes one synchronous traversal.
final class AXTraversalBudget {
    private static let nanosecondsPerSecond = 1_000_000_000.0

    let limits: AXTraversalLimits
    private let now: () -> UInt64
    private let isCancelled: () -> Bool
    private let deadline: UInt64

    private(set) var axCalls = 0
    private(set) var nodes = 0
    private(set) var allocatedBytes = 0

    init(
        limits: AXTraversalLimits,
        now: @escaping () -> UInt64,
        isCancelled: @escaping () -> Bool
    ) throws {
        try limits.validate()
        self.limits = limits
        self.now = now
        self.isCancelled = isCancelled

        let start = now()
        let duration = UInt64(limits.timeout * Self.nanosecondsPerSecond)
        let (candidate, overflow) = start.addingReportingOverflow(duration)
        self.deadline = overflow ? UInt64.max : candidate
    }

    var remainingNodes: Int {
        max(0, limits.maxNodes - nodes)
    }

    func check() throws {
        if isCancelled() {
            throw AXTraversalStopped(
                reason: .cancelled,
                detail: "the requesting task was cancelled")
        }
        if now() >= deadline {
            throw AXTraversalStopped(
                reason: .deadline,
                detail: "the \(limits.timeout)-second monotonic deadline expired")
        }
    }

    /// Reserve one provider call and return the timeout that must be applied to its element.
    func beginAXCall() throws -> Float {
        try check()
        guard axCalls < limits.maxAXCalls else {
            throw AXTraversalStopped(
                reason: .axCalls,
                detail: "the \(limits.maxAXCalls)-call budget was exhausted")
        }
        axCalls += 1

        let remainingNanoseconds = deadline > now() ? deadline - now() : 0
        let remainingSeconds = Double(remainingNanoseconds) / Self.nanosecondsPerSecond
        let bounded = min(limits.maxCallDuration, remainingSeconds)
        guard bounded > 0 else {
            throw AXTraversalStopped(
                reason: .deadline,
                detail: "the \(limits.timeout)-second monotonic deadline expired")
        }
        // AX requires a positive timeout. The preceding deadline check keeps this floor from
        // extending a request materially beyond its own deadline.
        return Float(max(0.001, bounded))
    }

    func finishAXCall() throws {
        try check()
    }

    func consumeNode() throws {
        try check()
        guard nodes < limits.maxNodes else {
            throw AXTraversalStopped(
                reason: .nodes,
                detail: "the \(limits.maxNodes)-node budget was exhausted")
        }
        nodes += 1
    }

    func consumeAllocation(_ bytes: Int) throws {
        try check()
        guard bytes >= 0,
              bytes <= limits.maxAllocatedBytes,
              allocatedBytes <= limits.maxAllocatedBytes - bytes
        else {
            throw AXTraversalStopped(
                reason: .allocation,
                detail: "the \(limits.maxAllocatedBytes)-byte aggregate allocation budget "
                    + "was exhausted")
        }
        allocatedBytes += bytes
    }
}

enum AXTraversal {
    private static let retainedNodeBytes = 192
    private static let retainedElementBytes = 64
    private static let copiedElementReferenceBytes = 16
    private static let maximumActionCount = 128
    private static let maximumActionBytes = 256
    private static let maximumRoleBytes = 256
    private static let maximumLabelBytes = 480

    static func boundedCall<P: AXTraversalProviding, T>(
        _ element: P.Element,
        provider: P,
        budget: AXTraversalBudget,
        _ operation: () -> T
    ) throws -> T {
        let timeout = try budget.beginAXCall()
        guard provider.setMessagingTimeout(element, seconds: timeout) else {
            throw AXTraversalStopped(
                reason: .provider,
                detail: "the descendant provider rejected its bounded messaging timeout")
        }
        let value = operation()
        try budget.finishAXCall()
        return value
    }

    static func root(
        pid: pid_t,
        window: WindowRef?,
        provider: SystemAXTraversalProvider,
        budget: AXTraversalBudget
    ) throws -> AXUIElement {
        let app = AX.application(pid)
        guard let window else { return app }

        let attribute = kAXWindowsAttribute as String
        let count = try boundedCall(app, provider: provider, budget: budget) {
            provider.arrayCount(app, attribute: attribute)
        }
        var start = 0
        while start < count {
            try budget.check()
            let requested = min(budget.limits.childPageSize, count - start)
            let page = try boundedCall(app, provider: provider, budget: budget) {
                provider.elements(
                    app, attribute: attribute, start: start, maxValues: requested)
            }
            try budget.consumeAllocation(
                multiplied(page.count, by: copiedElementReferenceBytes))
            guard !page.isEmpty else { break }

            for element in page {
                let foundID = try boundedCall(element, provider: provider, budget: budget) {
                    provider.windowID(element)
                }
                if foundID == window.windowID { return element }
            }
            start += page.count
            if page.count < requested { break }
        }
        throw SpaceOError.windowNotFound("window \(window.windowID)")
    }

    static func walk<P: AXTraversalProviding>(
        root: P.Element,
        provider: P,
        budget: AXTraversalBudget
    ) throws -> AXTraversalOutput<P.Element> {
        var nodes: [AXNode] = []
        var elements: [Int: P.Element] = [:]
        var nextIndex = 0

        func readString(_ element: P.Element, _ attribute: String) throws -> String? {
            try boundedCall(element, provider: provider, budget: budget) {
                provider.string(element, attribute: attribute)
            }
        }

        func walkElement(_ element: P.Element, depth: Int) throws {
            try budget.consumeNode()

            let rawRole = try readString(element, kAXRoleAttribute as String) ?? "AXUnknown"
            let role = utf8Prefix(rawRole, maximumBytes: maximumRoleBytes)

            let rawActions = try boundedCall(element, provider: provider, budget: budget) {
                provider.actions(element)
            }
            let actions = rawActions.prefix(maximumActionCount).map {
                utf8Prefix($0, maximumBytes: maximumActionBytes)
            }

            var label = ""
            for attribute in [
                kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                kAXHelpAttribute, kAXPlaceholderValueAttribute,
            ] {
                if let candidate = try readString(element, attribute as String),
                   !candidate.isEmpty {
                    label = utf8Prefix(candidate, maximumBytes: maximumLabelBytes)
                    break
                }
            }

            let enabled = try boundedCall(element, provider: provider, budget: budget) {
                provider.bool(element, attribute: kAXEnabledAttribute as String)
            } ?? true
            let origin = try boundedCall(element, provider: provider, budget: budget) {
                provider.point(element, attribute: kAXPositionAttribute as String)
            }
            let size = try boundedCall(element, provider: provider, budget: budget) {
                provider.size(element, attribute: kAXSizeAttribute as String)
            }
            let frame = origin.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } }

            let pressable = actions.contains(kAXPressAction as String)
                || actions.contains(kAXConfirmAction as String)
            let interesting = AXTree.actionableRoles.contains(role) || pressable

            var assigned: Int?
            if interesting && (!label.isEmpty || pressable) {
                assigned = nextIndex
                elements[nextIndex] = element
                nextIndex += 1
            }

            let actionBytes = actions.reduce(0) {
                adding($0, adding($1.utf8.count, 24))
            }
            var retainedBytes = retainedNodeBytes
            retainedBytes = adding(retainedBytes, role.utf8.count)
            retainedBytes = adding(retainedBytes, label.utf8.count)
            retainedBytes = adding(retainedBytes, actionBytes)
            if assigned != nil {
                retainedBytes = adding(retainedBytes, retainedElementBytes)
            }
            try budget.consumeAllocation(retainedBytes)

            nodes.append(AXNode(
                index: assigned,
                role: role,
                label: label,
                frame: frame,
                actions: actions,
                depth: depth,
                enabled: enabled))

            guard depth < budget.limits.maxDepth else { return }

            let attribute = kAXChildrenAttribute as String
            let childCount = try boundedCall(element, provider: provider, budget: budget) {
                provider.arrayCount(element, attribute: attribute)
            }
            var start = 0
            while start < childCount {
                try budget.check()
                guard budget.remainingNodes > 0 else {
                    throw AXTraversalStopped(
                        reason: .nodes,
                        detail: "the \(budget.limits.maxNodes)-node budget was exhausted")
                }

                let requested = min(
                    budget.limits.childPageSize,
                    childCount - start,
                    budget.remainingNodes)
                let page = try boundedCall(element, provider: provider, budget: budget) {
                    provider.elements(
                        element,
                        attribute: attribute,
                        start: start,
                        maxValues: requested)
                }
                try budget.consumeAllocation(
                    multiplied(page.count, by: copiedElementReferenceBytes))
                guard !page.isEmpty else { break }

                let boundedPage = page.prefix(requested)
                for child in boundedPage {
                    try walkElement(child, depth: depth + 1)
                }
                start += boundedPage.count
                if page.count < requested { break }
            }
        }

        try walkElement(root, depth: 0)
        return AXTraversalOutput(nodes: nodes, elements: elements)
    }

    /// A bounded text-only traversal used by integration checks that do not need a full
    /// actionable snapshot. It shares the exact same deadline, call, node, allocation, paging,
    /// descendant-timeout, and cancellation rules as `walk`.
    static func firstText<P: AXTraversalProviding>(
        root: P.Element,
        provider: P,
        budget: AXTraversalBudget,
        roles: Set<String>
    ) throws -> String? {
        func readString(_ element: P.Element, _ attribute: String) throws -> String? {
            try boundedCall(element, provider: provider, budget: budget) {
                provider.string(element, attribute: attribute)
            }
        }

        func visit(_ element: P.Element, depth: Int) throws -> String? {
            try budget.consumeNode()
            let rawRole = try readString(element, kAXRoleAttribute as String) ?? "AXUnknown"
            let role = utf8Prefix(rawRole, maximumBytes: maximumRoleBytes)
            try budget.consumeAllocation(adding(retainedNodeBytes, role.utf8.count))

            if roles.contains(role),
               let rawValue = try readString(element, kAXValueAttribute as String) {
                let value = utf8Prefix(rawValue, maximumBytes: 32_768)
                try budget.consumeAllocation(value.utf8.count)
                if !value.isEmpty { return value }
            }

            guard depth < budget.limits.maxDepth else { return nil }
            let attribute = kAXChildrenAttribute as String
            let childCount = try boundedCall(element, provider: provider, budget: budget) {
                provider.arrayCount(element, attribute: attribute)
            }
            var start = 0
            while start < childCount {
                try budget.check()
                guard budget.remainingNodes > 0 else {
                    throw AXTraversalStopped(
                        reason: .nodes,
                        detail: "the \(budget.limits.maxNodes)-node budget was exhausted")
                }
                let requested = min(
                    budget.limits.childPageSize,
                    childCount - start,
                    budget.remainingNodes)
                let page = try boundedCall(element, provider: provider, budget: budget) {
                    provider.elements(
                        element,
                        attribute: attribute,
                        start: start,
                        maxValues: requested)
                }
                try budget.consumeAllocation(
                    multiplied(page.count, by: copiedElementReferenceBytes))
                guard !page.isEmpty else { break }

                let boundedPage = page.prefix(requested)
                for child in boundedPage {
                    if let found = try visit(child, depth: depth + 1) { return found }
                }
                start += boundedPage.count
                if page.count < requested { break }
            }
            return nil
        }

        return try visit(root, depth: 0)
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        return String(decoding: value.utf8.prefix(maximumBytes), as: UTF8.self) + "…"
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private static func multiplied(_ lhs: Int, by rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }
}
