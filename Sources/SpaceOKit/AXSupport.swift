import Foundation
import ApplicationServices
import CoreGraphics
import SpaceOPrivate

/// Thin, typed helpers over the C accessibility API.
///
/// AX is SpaceO's preferred channel for everything: it is coordinate-free, needs no focus,
/// and keeps working when a window is occluded. Synthetic events are the fallback.
public enum AX {

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    // MARK: - Attribute access

    public static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyValue(element, attribute) else { return nil }
        if let string = raw as? String {
            guard string.utf8.count > 32_768 else { return string }
            return String(decoding: string.utf8.prefix(32_768), as: UTF8.self) + "…"
        }
        if CFGetTypeID(raw) == AXValueGetTypeID() { return nil }
        return (raw as? NSNumber)?.stringValue
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyValue(element, attribute) as? Bool
    }

    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = copyValue(element, attribute) else { return [] }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as! CFArray) as? [AXUIElement] ?? []
    }

    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    public static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = copyValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue((raw as! AXValue), .cgPoint, &out) else { return nil }
        return out
    }

    public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = copyValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue((raw as! AXValue), .cgSize, &out) else { return nil }
        return out
    }

    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute as String),
              let size = size(element, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The application's accessibility element under a global screen point.
    public static func element(at point: CGPoint, in pid: pid_t) -> AXUIElement? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let app = application(pid)
        setTimeout(app, seconds: 1.0)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            app, Float(point.x), Float(point.y), &found
        ) == .success else {
            return nil
        }
        return found
    }

    // MARK: - Mutation

    @discardableResult
    public static func setPoint(_ element: AXUIElement, _ attribute: String, _ value: CGPoint) -> Bool {
        guard value.x.isFinite, value.y.isFinite else { return false }
        var v = value
        guard let boxed = AXValueCreate(.cgPoint, &v) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, boxed) == .success
    }

    @discardableResult
    public static func setSize(_ element: AXUIElement, _ attribute: String, _ value: CGSize) -> Bool {
        guard value.width.isFinite, value.height.isFinite,
              value.width > 0, value.height > 0 else { return false }
        var v = value
        guard let boxed = AXValueCreate(.cgSize, &v) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, boxed) == .success
    }

    @discardableResult
    public static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        guard value.count <= 8_000, value.unicodeScalars.count <= 8_000,
              value.utf8.count <= 32_000 else { return false }
        return AXUIElementSetAttributeValue(
            element, attribute as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    public static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    // MARK: - Scrolling

    /// The scroll area at a global point **inside a specific window**.
    ///
    /// The window id is not optional decoration. `AXUIElementCopyElementAtPosition` hit-tests the
    /// whole application and answers with the frontmost window, so an app with two stacked
    /// windows — TextEdit with a document and an empty Untitled, which occupy identical frames —
    /// returns the wrong one. Scrolling it succeeds, reports success, and moves nothing the
    /// caller asked about. Resolving within the requested window makes that impossible.
    public static func scrollArea(
        at point: CGPoint,
        in pid: pid_t,
        windowID: CGWindowID
    ) -> AXUIElement? {
        let app = application(pid)
        setTimeout(app, seconds: 1.0)
        guard let windows = copyValue(app, kAXWindowsAttribute as String) as? [AXUIElement],
              let window = windows.first(where: { self.windowID($0) == windowID })
        else { return nil }
        return deepestScrollArea(in: window, containing: point)
    }

    /// Deepest scroll area whose frame contains the point, so nested scrollers resolve to the
    /// inner one — which is what the wheel would have hit.
    private static func deepestScrollArea(
        in element: AXUIElement,
        containing point: CGPoint,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < 16 else { return nil }
        guard let children = copyValue(element, kAXChildrenAttribute as String)
                as? [AXUIElement] else {
            return nil
        }
        var match: AXUIElement?
        for child in children.prefix(64) {
            if let childFrame = frame(child), !childFrame.contains(point) { continue }
            if let deeper = deepestScrollArea(
                in: child, containing: point, depth: depth + 1) {
                return deeper
            }
            if role(child) == kAXScrollAreaRole as String { match = child }
        }
        return match
    }

    /// Move a scroll area by a pixel delta, expressed through its scroll bar's documented
    /// 0...1 `AXValue`.
    ///
    /// This is the *primary* scroll path, not a fallback. Synthetic scroll wheel events posted
    /// with `CGEventPostToPid` do not reach AppKit on a host without the private
    /// focus-without-raise record: measured against TextEdit on macOS 27, pixel and line units,
    /// stamped and unstamped, with and without an explicit location, all reported success and
    /// moved nothing. A scroll bar's value is public API, is settable, and can be read back to
    /// confirm the scroll actually happened.
    ///
    /// Returns the achieved value when the position changed, or nil when this element cannot be
    /// scrolled — never a silent success.
    @discardableResult
    public static func scroll(
        _ scrollArea: AXUIElement,
        byPixels delta: CGFloat,
        horizontal: Bool = false
    ) -> Double? {
        let barAttribute = horizontal
            ? kAXHorizontalScrollBarAttribute
            : kAXVerticalScrollBarAttribute
        guard let raw = copyValue(scrollArea, barAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let bar = (raw as! AXUIElement)

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue,
              let current = number(bar, kAXValueAttribute as String) else { return nil }

        // AXValue is a fraction of the scrollable range, so a pixel delta needs the range to
        // convert. The scrollable extent is the content's overflow beyond the viewport.
        guard let viewport = size(scrollArea, kAXSizeAttribute as String) else { return nil }
        let extent = horizontal ? viewport.width : viewport.height
        guard extent > 0 else { return nil }
        let contentExtent = contentSize(of: scrollArea, horizontal: horizontal) ?? (extent * 2)
        let scrollable = max(1, contentExtent - extent)

        let target = min(1, max(0, current + Double(delta / scrollable)))
        guard AXUIElementSetAttributeValue(
            bar, kAXValueAttribute as CFString, target as NSNumber) == .success else {
            return nil
        }
        // Compare the read-back against where we started, not merely against nil. A scroll area
        // pinned at its limit accepts the assignment and does not move, and an element that
        // ignores the write reports success too — returning the new value without checking it
        // changed is how a scroll that did nothing still reported that it scrolled.
        guard let achieved = number(bar, kAXValueAttribute as String),
              abs(achieved - current) > 0.0001 else { return nil }
        return achieved
    }

    /// The scrolled content's extent, taken from the largest child a scroll area contains.
    private static func contentSize(
        of scrollArea: AXUIElement,
        horizontal: Bool
    ) -> CGFloat? {
        guard let children = copyValue(scrollArea, kAXChildrenAttribute as String)
                as? [AXUIElement] else { return nil }
        var largest: CGFloat = 0
        for child in children.prefix(16) {
            guard let childSize = size(child, kAXSizeAttribute as String) else { continue }
            largest = max(largest, horizontal ? childSize.width : childSize.height)
        }
        return largest > 0 ? largest : nil
    }

    public static func number(_ element: AXUIElement, _ attribute: String) -> Double? {
        guard let raw = copyValue(element, attribute) else { return nil }
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    // MARK: - Identity

    /// The CGWindowID behind an AX window element.
    public static func windowID(_ element: AXUIElement) -> CGWindowID {
        SPOWindowIDForAXElement(element)
    }

    public static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? "AXUnknown"
    }

    /// Best available human label for an element, in the order a person would look for one.
    public static func label(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                     kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let s = string(element, attr as String), !s.isEmpty {
                return s.utf8.count > 480
                    ? String(decoding: s.utf8.prefix(480), as: UTF8.self) + "…"
                    : s
            }
        }
        return ""
    }

    /// Set the per-application timeout so a wedged app cannot stall the agent.
    @discardableResult
    public static func setTimeout(_ element: AXUIElement, seconds: Float) -> Bool {
        AXUIElementSetMessagingTimeout(element, seconds) == .success
    }
}
