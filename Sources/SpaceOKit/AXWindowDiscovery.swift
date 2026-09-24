import Foundation
import ApplicationServices
import CoreGraphics

/// Unlike the best-effort AX helpers, discovery must distinguish an empty list from failure.
protocol AXWindowDiscoveryProviding: AXTraversalProviding {
    func windowCount(_ app: Element) throws -> Int
    func windowElements(_ app: Element, start: Int, count: Int) throws -> [Element]
}

extension SystemAXTraversalProvider: AXWindowDiscoveryProviding {
    func windowCount(_ app: AXUIElement) throws -> Int {
        var count: CFIndex = 0
        let status = AXWindowDiscovery.retryingBusy {
            AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count)
        }
        guard status == .success, count >= 0 else {
            throw AXWindowDiscovery.incomplete("window count is unavailable (AXError \(status.rawValue))")
        }
        return count
    }

    func windowElements(_ app: AXUIElement, start: Int, count: Int) throws -> [AXUIElement] {
        var values: CFArray?
        let status = AXWindowDiscovery.retryingBusy {
            AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, start, count, &values)
        }
        guard status == .success, let elements = values as? [AXUIElement] else {
            throw AXWindowDiscovery.incomplete("window page is unavailable (AXError \(status.rawValue))")
        }
        return elements
    }
}

enum AXWindowDiscovery {
    struct Result<Element> {
        let windows: [WindowRef]
        let elements: [CGWindowID: Element]
    }
    static func incomplete(_ detail: String) -> AXTraversalStopped {
        AXTraversalStopped(reason: .provider, detail: "incomplete window discovery: " + detail)
    }

    /// `kAXErrorCannotComplete` is how an application that is launching, or busy running a modal
    /// panel, answers a messaging request. It is a transient refusal, not an answer: retry a
    /// bounded number of times before reporting discovery as incomplete.
    static func retryingBusy(attempts: Int = 3, pauseMicroseconds: useconds_t = 40_000,
                             pause: (useconds_t) -> Void = { usleep($0) },
                             _ call: () -> AXError) -> AXError {
        var status = call()
        var remaining = attempts - 1
        while status == .cannotComplete, remaining > 0 {
            pause(pauseMicroseconds)
            status = call()
            remaining -= 1
        }
        return status
    }

    static func limits(remaining: TimeInterval?) throws -> AXTraversalLimits {
        var limits = try WaitPolicy.axTraversalLimits(remaining: remaining)
        limits.timeout = min(limits.timeout, 2)
        limits.maxDepth = 0
        limits.maxNodes = 256
        limits.maxAXCalls = 2_048
        limits.maxAllocatedBytes = 2 * 1_024 * 1_024
        return limits
    }

    /// Presence checks need a trustworthy count, not pages, titles, or geometry.
    static func hasWindows<P: AXWindowDiscoveryProviding>(
        app: P.Element, provider: P, budget: AXTraversalBudget
    ) throws -> Bool {
        try checkedCount(app: app, provider: provider, budget: budget) > 0
    }

    private static func checkedCount<P: AXWindowDiscoveryProviding>(
        app: P.Element, provider: P, budget: AXTraversalBudget
    ) throws -> Int {
        let count = try AXTraversal.boundedCall(app, provider: provider, budget: budget) {
            try provider.windowCount(app)
        }
        guard count >= 0 else { throw incomplete("negative window count") }
        return count
    }

    /// A positive count can precede resolvable window identities during application startup.
    /// Readiness needs one real ID, but no titles or geometry; placement verifies the full set.
    static func hasIdentifiedWindow<P: AXWindowDiscoveryProviding>(
        app: P.Element, provider: P, budget: AXTraversalBudget
    ) throws -> Bool {
        let count = try checkedCount(app: app, provider: provider, budget: budget)
        guard count <= budget.limits.maxNodes - budget.nodes else {
            throw AXTraversalStopped(reason: .nodes, detail: "window discovery exceeds its window limit")
        }
        var start = 0
        while start < count {
            let size = min(budget.limits.childPageSize, count - start)
            let page = try AXTraversal.boundedCall(app, provider: provider, budget: budget) {
                try provider.windowElements(app, start: start, count: size)
            }
            guard page.count == size else { throw incomplete("window list changed during paging") }
            try budget.consumeAllocation(page.count * MemoryLayout<P.Element>.stride)
            for element in page {
                try budget.consumeNode()
                let id = try AXTraversal.boundedCall(element, provider: provider, budget: budget) {
                    provider.windowID(element)
                }
                if id != 0 { return true }
            }
            start += page.count
        }
        return false
    }

    /// All apps in a discovery operation share this budget. Nothing partial escapes as an empty list.
    static func windows<P: AXWindowDiscoveryProviding>(
        of pid: pid_t, app: P.Element, provider: P, budget: AXTraversalBudget,
        liveBounds: (CGWindowID) -> CGRect?, includeTitles: Bool = true
    ) throws -> [WindowRef] {
        try discover(of: pid, app: app, provider: provider, budget: budget,
                     liveBounds: liveBounds, includeTitles: includeTitles).windows
    }

    /// Retain handles only for a caller that needs to act on the complete discovery result.
    /// A failed discovery returns neither its partial windows nor its partial handle map.
    static func discover<P: AXWindowDiscoveryProviding>(
        of pid: pid_t, app: P.Element, provider: P, budget: AXTraversalBudget,
        liveBounds: (CGWindowID) -> CGRect?, includeTitles: Bool = true,
        retainingElements: Bool = false
    ) throws -> Result<P.Element> {
        let count = try checkedCount(app: app, provider: provider, budget: budget)
        guard count <= budget.limits.maxNodes - budget.nodes else {
            throw AXTraversalStopped(reason: .nodes, detail: "window discovery exceeds its window limit")
        }
        var windows: [WindowRef] = []
        var elements: [CGWindowID: P.Element] = [:]
        var seen = Set<CGWindowID>()
        var start = 0
        while start < count {
            let size = min(budget.limits.childPageSize, count - start)
            let page = try AXTraversal.boundedCall(app, provider: provider, budget: budget) {
                try provider.windowElements(app, start: start, count: size)
            }
            guard page.count == size else { throw incomplete("window list changed during paging") }
            try budget.consumeAllocation(page.count * MemoryLayout<P.Element>.stride)
            for element in page {
                try budget.consumeNode()
                let id = try AXTraversal.boundedCall(element, provider: provider, budget: budget) {
                    provider.windowID(element)
                }
                guard id != 0, seen.insert(id).inserted else {
                    throw incomplete("window identity is unavailable or repeated")
                }
                var frame = liveBounds(id)
                try budget.check()
                if frame == nil {
                    let origin = try AXTraversal.boundedCall(element, provider: provider, budget: budget) {
                        provider.point(element, attribute: kAXPositionAttribute as String)
                    }
                    let size = try AXTraversal.boundedCall(element, provider: provider, budget: budget) {
                        provider.size(element, attribute: kAXSizeAttribute as String)
                    }
                    if let origin, let size { frame = CGRect(origin: origin, size: size) }
                }
                guard let frame, frame.origin.x.isFinite, frame.origin.y.isFinite,
                      frame.width.isFinite, frame.height.isFinite, frame.width >= 0, frame.height >= 0 else {
                    throw incomplete("window geometry is unavailable")
                }
                let title: String
                if includeTitles {
                    title = try AXTraversal.boundedCall(element, provider: provider, budget: budget) {
                        provider.text(element, attribute: kAXTitleAttribute as String)
                    } ?? ""
                } else { title = "" }
                try budget.consumeAllocation(title.utf8.count)
                try budget.consumeAllocation(256)
                windows.append(WindowRef(windowID: id, pid: pid,
                    title: BoundedDiagnosticText.prefix(title, maximumBytes: 32_768), frame: frame))
                if retainingElements {
                    try budget.consumeAllocation(MemoryLayout<P.Element>.stride + 32)
                    elements[id] = element
                }
            }
            start += page.count
        }
        return Result(windows: windows, elements: elements)
    }

    static func liveWindows(of pid: pid_t, budget: AXTraversalBudget, includeTitles: Bool = true) throws -> [WindowRef] {
        try windows(of: pid, app: AX.application(pid), provider: SystemAXTraversalProvider(),
                    budget: budget, liveBounds: { try? WindowPlacement.liveBounds(of: $0) },
                    includeTitles: includeTitles)
    }
}
