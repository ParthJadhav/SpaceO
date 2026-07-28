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
