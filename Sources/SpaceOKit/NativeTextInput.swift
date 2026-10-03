import Foundation
import ApplicationServices

/// Selection edits use Accessibility so an inactive AppKit document cannot silently append
/// after an ignored synthetic Command-A. No shared pasteboard or global focus is used.
enum NativeTextInput {
    static let maximumDocumentBytes = 1_048_576

    struct Driver {
        let canSelect: Bool
        let canInsert: Bool
        var allowsMultiline = true
        let value: () throws -> String
        let selection: () throws -> CFRange
        let select: (CFRange) throws -> Void
        let insert: (String) throws -> Void
    }

    static func driver(for window: WindowRef) -> Driver? {
        guard AX.isTrusted,
              let identity = ProcessIdentity.current(of: window.pid),
              let element = AXTree.settableFocusedElement(pid: window.pid, inWindow: window.windowID),
              isNativeTextElement(element, inWindow: window.windowID, provider: SystemAXAncestryProvider()),
              AX.string(element, kAXSubroleAttribute as String) != "AXSecureTextField" else { return nil }
        AX.setTimeout(element, seconds: 0.25)
        func settable(_ attribute: String) -> Bool {
            var answer = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &answer) == .success && answer.boolValue
        }
        func requireTarget() throws {
            guard ProcessIdentity.current(of: window.pid) == identity,
                  AXTree.focusedWindowID(pid: window.pid) == window.windowID,
                  let focused = AXTree.focusedElement(pid: window.pid), CFEqual(focused, element) else {
                throw SpaceOError.unsupportedTarget("focused text target changed; edit refused")
            }
        }
        return Driver(canSelect: settable(kAXSelectedTextRangeAttribute as String),
                      canInsert: settable(kAXSelectedTextAttribute as String),
                      allowsMultiline: AX.role(element) == "AXTextArea", value: {
            try requireTarget()
            return try AXTree.completeText(of: element, attribute: kAXValueAttribute as String,
                maximumBytes: maximumDocumentBytes, requireValue: true)
        }, selection: {
            try requireTarget()
            guard let raw = AX.copyValue(element, kAXSelectedTextRangeAttribute as String),
                  CFGetTypeID(raw) == AXValueGetTypeID() else {
                throw SpaceOError.unsupportedTarget("focused field has no readable text selection")
            }
            var range = CFRange()
            guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else {
                throw SpaceOError.unsupportedTarget("focused field returned an invalid text selection")
            }
            return range
        }, select: { range in
            try requireTarget()
            var range = range
            guard let value = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                throw SpaceOError.unsupportedTarget("focused field rejected text selection; nothing typed")
            }
        }, insert: { text in
            try requireTarget()
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                throw SpaceOError.unsupportedTarget("focused field rejected selected-text replacement; delivery unconfirmed")
            }
        })
    }

    static func isNativeTextElement<P: AXAncestryProviding>(_ element: P.Element, inWindow windowID: CGWindowID, provider: P) -> Bool {
        var current = element
        var seen = Set<P.Element>()
        for _ in 0..<AX.maxAncestryDepth {
            guard seen.insert(current).inserted else { return false }
            let role = provider.role(current)
            if role == "AXWebArea" { return false }
            if role == "AXWindow" { return windowID != 0 && provider.windowID(current) == windowID }
            guard let parent = provider.parent(current) else { return false }
            current = parent
        }
        return false
    }

    static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func isSelectAll(_ combo: KeyCombo) -> Bool {
        combo.keyCode == 0 && combo.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]) == .maskCommand
    }

    static func expectedValue(_ value: String, selection: CFRange, text: String) throws -> String {
        guard value.utf8.count <= maximumDocumentBytes,
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location,
              let range = Range(NSRange(location: selection.location, length: selection.length), in: value) else {
            throw SpaceOError.unsupportedTarget("text selection is invalid or exceeds the edit budget; nothing typed")
        }
        let units = Array(value.utf16)
        for boundary in [selection.location, selection.location + selection.length] {
            if boundary < units.count, (0xDC00...0xDFFF).contains(units[boundary]) {
                throw SpaceOError.unsupportedTarget("text selection splits a Unicode scalar; nothing typed")
            }
        }
        let result = value.replacingCharacters(in: range, with: text)
        guard result.utf8.count <= maximumDocumentBytes else {
            throw SpaceOError.unsupportedTarget("resulting text exceeds the edit budget; nothing typed")
        }
        return result
    }

    @discardableResult
    static func selectAll(_ driver: Driver) throws -> Bool {
        guard driver.canSelect else { return false }
        // Pre-write read failures leave the existing key route available. Once selection is
        // attempted, failure must throw rather than deliver a second operation.
        guard let before = try? driver.value(), before.utf8.count <= maximumDocumentBytes else { return false }
        let range = CFRange(location: 0, length: before.utf16.count)
        try driver.select(range)
        let selected = try driver.selection()
        guard selected.location == range.location, selected.length == range.length,
              try driver.value() == before else {
            throw SpaceOError.unsupportedTarget("select-all was not confirmed; nothing typed")
        }
        return true
    }

    /// False means no semantic edit was attempted; a rejected/ignored write throws and must
    /// never fall through to synthetic delivery, which could insert the payload twice.
    static func type(_ text: String, replace: Bool, driver: Driver) throws -> Bool {
        guard driver.canInsert else {
            if replace { throw SpaceOError.unsupportedTarget("replace requires a focused field that supports Accessibility selected-text editing; nothing typed") }
            return false
        }
        let text = normalizedText(text)
        if !driver.allowsMultiline && text.contains("\n") {
            if replace { throw SpaceOError.unsupportedTarget("multiline replacement requires a multiline text field; nothing typed") }
            return false
        }
        if !replace {
            if text.isEmpty { return false }
            guard let selected = try? driver.selection() else { return false }
            guard selected.location >= 0, selected.length >= 0 else {
                throw SpaceOError.unsupportedTarget("focused text selection is invalid; nothing typed")
            }
            if selected.length == 0 { return false }
        }
        if replace, try !selectAll(driver) {
            throw SpaceOError.unsupportedTarget("replace requires a confirmable select-all; nothing typed")
        }
        let before: String
        do { before = try driver.value() }
        catch {
            if !replace { return false }
            throw error
        }
        if !replace, before.utf8.count > maximumDocumentBytes { return false }
        let selected = try driver.selection()
        let expected = try expectedValue(before, selection: selected, text: text)
        do {
            try driver.insert(text)
            guard try driver.value() == expected else {
                throw SpaceOError.unsupportedTarget("selected-text readback did not match")
            }
        } catch {
            throw SpaceOError.unsupportedTarget("selected-text edit could not be confirmed; delivery unconfirmed, do not retry blindly")
        }
        return true
    }
}
