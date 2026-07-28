import Foundation
import ApplicationServices
import CoreGraphics

/// One node of an application's accessibility tree.
public struct AXNode: Sendable {
    /// Assigned only to actionable nodes — this is the handle an agent clicks by.
    public let index: Int?
    public let role: String
    public let label: String
    public let frame: CGRect?
    public let actions: [String]
    public let depth: Int
    public let enabled: Bool

    public var isActionable: Bool { index != nil }
}

/// A walked accessibility tree with stable indices for its actionable elements.
///
/// Indexed AX addressing is SpaceO's primary interaction channel. `click --element 7` beats
/// pixel coordinates on every axis: no HiDPI maths, no occlusion sensitivity, no near-misses,
/// and it keeps working if the window moves between the screenshot and the click.
public struct AXSnapshot {
    public let pid: pid_t
    public let windowID: CGWindowID
    public let processIdentity: ProcessIdentity
    public let generation: UUID
    public let nodes: [AXNode]
    private let elements: [Int: AXUIElement]

    public var actionableCount: Int { elements.count }

    init(
        pid: pid_t,
        windowID: CGWindowID,
        processIdentity: ProcessIdentity,
        generation: UUID,
        nodes: [AXNode],
        elements: [Int: AXUIElement]
    ) {
        self.pid = pid
        self.windowID = windowID
        self.processIdentity = processIdentity
        self.generation = generation
        self.nodes = nodes
        self.elements = elements
    }

    public func element(at index: Int) -> AXUIElement? { elements[index] }

    public func node(at index: Int) -> AXNode? { nodes.first { $0.index == index } }

    /// Actionable nodes whose label contains `text`, case-insensitively.
    public func find(_ text: String) -> [AXNode] {
        let needle = text.lowercased()
        return nodes.filter { $0.isActionable && $0.label.lowercased().contains(needle) }
    }

    /// Markdown-ish outline. Actionable nodes carry their index in brackets.
    public func outline(includeNonActionable: Bool = false) -> String {
        var lines: [String] = []
        for node in nodes {
            guard node.isActionable || includeNonActionable else { continue }
            let indent = String(repeating: "  ", count: min(node.depth, 12))
            let tag = node.index.map { "[\($0)] " } ?? ""
            let role = node.role.replacingOccurrences(of: "AX", with: "")
            var line = "\(indent)\(tag)\(role)"
            if !node.label.isEmpty { line += " — \(node.label)" }
            if !node.enabled { line += "  (disabled)" }
            lines.append(line)
        }
        return lines.isEmpty ? "(no actionable elements found)" : lines.joined(separator: "\n")
    }
}

public enum AXTree {

    /// Roles that are worth handing an agent an index for.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider",
        "AXTabGroup", "AXRow", "AXCell", "AXDisclosureTriangle", "AXIncrementor", "AXStepper",
        "AXColorWell", "AXSegmentedControl", "AXToolbarButton",
    ]

    /// Walk an app's tree, or a single window's subtree.
    ///
    /// Bounded on purpose: a runaway tree (a big web page) would otherwise stall the agent.
    public static func snapshot(
        pid: pid_t,
        window: WindowRef? = nil,
        maxDepth: Int = 22,
        maxNodes: Int = 1500,
        generation: UUID = UUID()
    ) throws -> AXSnapshot {
        try snapshot(
            pid: pid,
            window: window,
            limits: AXTraversalLimits(maxDepth: maxDepth, maxNodes: maxNodes),
            generation: generation)
    }

    /// Walk with an explicit aggregate safety envelope.
    public static func snapshot(
        pid: pid_t,
        window: WindowRef? = nil,
        limits: AXTraversalLimits,
        generation: UUID = UUID()
    ) throws -> AXSnapshot {
        try limits.validate()
        guard AX.isTrusted else { throw SpaceOError.accessibilityDenied }
        guard let processIdentity = ProcessIdentity.current(of: pid) else {
            throw SpaceOError.windowNotFound("pid \(pid) exited before accessibility traversal")
        }

        let provider = SystemAXTraversalProvider()
        let budget = try AXTraversalBudget(
            limits: limits,
            now: { DispatchTime.now().uptimeNanoseconds },
            isCancelled: { Task.isCancelled })
        let root = try AXTraversal.root(
            pid: pid, window: window, provider: provider, budget: budget)
        let output = try AXTraversal.walk(root: root, provider: provider, budget: budget)
        guard ProcessIdentity.current(of: pid) == processIdentity else {
            throw SpaceOError.windowNotFound(
                "pid \(pid) changed identity during accessibility traversal")
        }
        return AXSnapshot(
            pid: pid,
            windowID: window?.windowID ?? 0,
            processIdentity: processIdentity,
            generation: generation,
            nodes: output.nodes,
            elements: output.elements)
    }

    /// The element that currently has keyboard focus inside an app, if any.
    public static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AX.application(pid)
        AX.setTimeout(app, seconds: 1.5)
        return AX.element(app, kAXFocusedUIElementAttribute as String)
    }

    /// Text content of the focused element — app-wide, so ambiguous when an app has several
    /// windows. Prefer `text(in:)` when you know which window you mean.
    public static func focusedValue(pid: pid_t) -> String? {
        guard let element = focusedElement(pid: pid) else { return nil }
        return AX.string(element, kAXValueAttribute as String)
    }

    /// Text content of the first text-bearing element inside a *specific* window.
    ///
    /// Scoped deliberately: `focusedValue` asks the application, which answers about whichever
    /// window it currently considers focused. If the user (or another session) already had that
    /// app open, that is not necessarily our window, and a test built on it reports nonsense.
    public static func text(in window: WindowRef, maxDepth: Int = 12) -> String? {
        guard (0...64).contains(maxDepth) else { return nil }
        return try? text(
            in: window,
            limits: AXTraversalLimits(
                maxDepth: maxDepth,
                maxNodes: 1_500,
                timeout: 2,
                maxAXCalls: 8_000,
                maxAllocatedBytes: 4 * 1_024 * 1_024,
                childPageSize: 32,
                maxCallDuration: 0.25))
    }

    /// Throwing text traversal for callers that need to distinguish "no text" from a provider
    /// that exceeded the safety envelope.
    public static func text(
        in window: WindowRef,
        limits: AXTraversalLimits
    ) throws -> String? {
        try limits.validate()
        guard AX.isTrusted else { throw SpaceOError.accessibilityDenied }

        let provider = SystemAXTraversalProvider()
        let budget = try AXTraversalBudget(
            limits: limits,
            now: { DispatchTime.now().uptimeNanoseconds },
            isCancelled: { Task.isCancelled })
        let root = try AXTraversal.root(
            pid: window.pid, window: window, provider: provider, budget: budget)
        return try AXTraversal.firstText(
            root: root,
            provider: provider,
            budget: budget,
            roles: ["AXTextArea", "AXTextField", "AXStaticText", "AXSearchField"])
    }
}
