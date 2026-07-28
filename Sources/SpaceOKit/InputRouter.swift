import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import SpaceOPrivate

public enum MouseButton: String, Sendable {
    case left, right

    var downType: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
    var upType: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
    var cgButton: CGMouseButton { self == .left ? .left : .right }
}

/// A parsed keystroke such as `cmd+s` or `return`.
public struct KeyCombo: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags

    /// Command-C and Command-X are the native routes that can replace the shared pasteboard.
    /// Extra modifiers do not make them safe: applications are free to bind variants such as
    /// Command-Shift-C to another kind of copy.
    var mutatesPasteboard: Bool {
        flags.contains(.maskCommand) && (keyCode == 8 || keyCode == 7)
    }

    func requireClipboardSafeRoute() throws {
        guard !mutatesPasteboard else {
            throw SpaceOError.unsupportedTarget(
                "clipboard-safe Command-C/Command-X delivery is unavailable: macOS provides "
                + "no atomic way to restore the shared pasteboard without risking a newer user "
                + "copy. Use a non-clipboard read/edit action; enabling this shortcut requires "
                + "an isolated clipboard broker or an acknowledged target route.")
        }
    }

    public static func parse(_ input: String) throws -> KeyCombo {
        guard !input.isEmpty, input.count <= 64, input.utf8.count <= 256 else {
            throw SpaceOError.badRequest(
                "key combo must be 1 through 64 characters and at most 256 UTF-8 bytes")
        }
        let parts = input.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last else { throw SpaceOError.badRequest("empty key combo") }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command":       flags.insert(.maskCommand)
            case "shift":                flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control":      flags.insert(.maskControl)
            case "fn":                   flags.insert(.maskSecondaryFn)
            default: throw SpaceOError.badRequest("unknown modifier '\(modifier)'")
            }
        }
        guard let code = Self.keyCodes[keyName] else {
            throw SpaceOError.badRequest("unknown key '\(keyName)' (try a letter, digit, or return/tab/esc/space/delete/arrow)")
        }
        return KeyCombo(keyCode: code, flags: flags)
    }

    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        ]
        for n in 1...12 { map["f\(n)"] = CGKeyCode([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][n - 1]) }
        return map
    }()
}

/// Delivers input to a specific process without touching the cursor or the frontmost app.
///
/// Order matters. `focus` flips input routing only; it never calls
/// `SLPSSetFrontProcessWithOptions`, which is the one API that would raise the window and drag
/// the user to the app's Space.
public enum InputRouter {

    public struct UserInputRoute {
        let app: NSRunningApplication
        let windowID: CGWindowID
    }

    /// Bundle identifier prefixes whose renderer needs a primer click before real mouse input.
    static let chromiumLike: [String] = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "app.zen-browser", "com.electron.",
    ]

    static func bundleID(of pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    static func isChromiumLike(_ pid: pid_t) -> Bool {
        let id = bundleID(of: pid)
        return chromiumLike.contains { id.hasPrefix($0) }
    }

    // MARK: - Focus

    /// Make `window` the input target of its app without raising it or switching Space.
    public static func focus(_ window: WindowRef) throws {
        guard SPOCapabilityAvailable(.focusWithoutRaise) else {
            throw SpaceOError.unavailable(capability: "focus-without-raise")
        }
        guard SPOFocusWithoutRaise(window.pid, window.windowID) else {
            throw SpaceOError.unsupportedTarget("pid \(window.pid) refused the focus record")
        }
        AgentActivity.recordFocusFlip()
        usleep(120_000)   // let AppKit process the activation record before events arrive
    }

    /// Prime an agent window for per-PID input, then immediately give the global input route
    /// back to the user's existing frontmost app.
    ///
    /// `SPOFocusWithoutRaise` does not raise the agent's window, but its first record still makes
    /// that process active for WindowServer input routing. Leaving that route in place can make
    /// the user's keyboard and pointer appear frozen even though their screen and applications
    /// are otherwise alive. Per-PID events only need the agent window to have been made key
    /// *within its own app*; they do not need the agent to remain the global input route.
    public static func prepareForInput(_ window: WindowRef) throws {
        // Priming improves compatibility but never gates direct per-PID delivery. If the focus
        // primitive or a restorable user route is unavailable, callers still post the event.
        guard SPOCapabilityAvailable(.focusWithoutRaise) else { return }
        let userRoute = try? captureUserInputRoute(excluding: [window.pid])
        try? focus(window)
        if let userRoute {
            _ = restoreUserInputRoute(userRoute)
        }
    }

    /// Hold the target's WindowServer input route for a pointer transaction.
    ///
    /// Some AppKit controls discard per-PID mouse events unless their window remains the
    /// process's input target through mouse-down and mouse-up. Capture the user's route first,
    /// then focus the target without raising it. Failure to capture or focus never blocks direct
    /// event delivery; callers receive `nil` and continue posting.
    public static func beginPointerInput(_ window: WindowRef) -> UserInputRoute? {
        guard SPOCapabilityAvailable(.focusWithoutRaise),
              let route = try? captureUserInputRoute(excluding: [window.pid])
        else { return nil }
        do {
            try focus(window)
            return route
        } catch {
            return nil
        }
    }

    /// Restore a route returned by `beginPointerInput`.
    public static func endPointerInput(_ route: UserInputRoute?) {
        guard let route else { return }
        _ = restoreUserInputRoute(route)
    }

    static func captureUserInputRoute(
        excluding agentPIDs: Set<pid_t> = []
    ) throws -> UserInputRoute {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !agentPIDs.contains(app.processIdentifier) else {
            throw SpaceOError.unsupportedTarget(
                "no safe user input route is available; refusing to focus the agent window")
        }

        let appElement = AX.application(app.processIdentifier)
        AX.setTimeout(appElement, seconds: 1.0)
        let focusedWindow = AX.element(appElement, kAXFocusedWindowAttribute as String)
        let windowID = focusedWindow.map(AX.windowID) ?? 0
        return UserInputRoute(app: app, windowID: windowID)
    }

    static func currentRouteTargets(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func userRouteIsCurrent(_ route: UserInputRoute) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == route.app.processIdentifier
    }

    @discardableResult
    static func restoreUserInputRoute(_ route: UserInputRoute) -> Bool {
        guard NSRunningApplication(processIdentifier: route.app.processIdentifier) != nil else {
            return false
        }

        var posted = false
        if SPOCapabilityAvailable(.focusWithoutRaise),
           route.windowID != 0,
           SPOFocusWithoutRaise(route.app.processIdentifier, route.windowID) {
            posted = true
        }
        if !posted {
            // Some applications do not expose AXFocusedWindow. Public activation is the
            // fallback; the target was already frontmost before the operation.
            posted = route.app.activate()
        }
        guard posted else { return false }

        // Private key/typing/front-process getters are not queried: resolving a private symbol
        // does not prove its ABI. Verify restoration through AppKit's public frontmost-app state.
        let deadline = Date().addingTimeInterval(1.0)
        repeat {
            if userRouteIsCurrent(route) {
                AgentActivity.recordFocusRestore()
                return true
            }
            usleep(20_000)
        } while Date() < deadline

        // One last public activation can recover an accepted-but-ineffective private record.
        if route.app.activate() {
            let fallbackDeadline = Date().addingTimeInterval(1.0)
            repeat {
                if userRouteIsCurrent(route) {
                    AgentActivity.recordFocusRestore()
                    return true
                }
                usleep(20_000)
            } while Date() < fallbackDeadline
        }
        return false
    }

    // MARK: - Keyboard

    /// One unit of typing work: a literal scalar carried in a unicode event, or a Return.
    enum Keystroke: Equatable {
        case scalar(Unicode.Scalar)
        case returnKey
    }

    /// The single definition of how text becomes keystrokes: newline scalars become Return
    /// keystrokes (many controls ignore \n in a unicode string) and "\r\n" is one line break,
    /// not two. Both the send loop and the pre-flight duration estimate consume this, so the
    /// estimate cannot drift from what is actually typed.
    static func keystrokes(for text: String) -> [Keystroke] {
        var out: [Keystroke] = []
        out.reserveCapacity(text.unicodeScalars.count)
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            if scalar == "\n" || scalar == "\r" {
                if scalar == "\n", previous == "\r" { continue }
                out.append(.returnKey)
                continue
            }
            out.append(.scalar(scalar))
        }
        return out
    }

    /// Type literal text into `pid`. Unicode-safe: characters are carried as a unicode string
    /// rather than synthesised from keycodes, so accents and emoji work.
    public static func type(_ text: String, to pid: pid_t, charactersPerSecond: Double = 90) throws {
        try validateTyping(text, charactersPerSecond: charactersPerSecond)
        let source = CGEventSource(stateID: .hidSystemState)
        let delay = UInt32(max(1_000, 1_000_000 / charactersPerSecond))

        for keystroke in Self.keystrokes(for: text) {
            switch keystroke {
            case .returnKey:
                try key(KeyCombo(keyCode: 36, flags: []), to: pid)
            case .scalar(let character):
                var utf16 = Array(String(character).utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { continue }
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.postToPid(pid)
                up.postToPid(pid)
                usleep(delay)
            }
        }
    }

    public static func validateTyping(
        _ text: String,
        charactersPerSecond: Double = 90
    ) throws {
        let scalars = text.unicodeScalars
        guard text.count <= 8_000, scalars.count <= 8_000,
              text.utf8.count <= 32_000 else {
            throw SpaceOError.badRequest(
                "text is too long (maximum 8000 characters/scalars "
                + "and 32000 UTF-8 bytes)")
        }
        guard charactersPerSecond.isFinite, (1...1_000).contains(charactersPerSecond) else {
            throw SpaceOError.badRequest(
                "typing speed must be a finite value from 1 through 1000 characters per second")
        }
        let estimatedSeconds = estimatedTypingSeconds(text, charactersPerSecond: charactersPerSecond)
        guard estimatedSeconds <= 110 else {
            throw SpaceOError.badRequest(
                "typing request would take about \(Int(estimatedSeconds.rounded())) seconds; "
                + "maximum is 110")
        }
    }

    /// Cost model over the same `keystrokes(for:)` stream `type(_:to:)` sends, so the duration
    /// gate and the actual typing agree by construction. Internal for regression tests.
    static func estimatedTypingSeconds(_ text: String, charactersPerSecond: Double) -> Double {
        var returnCount = 0
        var ordinaryCount = 0
        for keystroke in keystrokes(for: text) {
            if keystroke == .returnKey { returnCount += 1 } else { ordinaryCount += 1 }
        }
        return Double(ordinaryCount) / charactersPerSecond + Double(returnCount) * 0.045
    }

    public static func key(_ combo: KeyCombo, to pid: pid_t) throws {
        try deliverKey(combo, pasteboard: .general) {
            try postKey(combo, to: pid)
        }
    }

    /// Shared production/test seam so recognition and guarding cannot drift apart. The real
    /// route supplies `postKey`; tests supply a pasteboard-writing command.
    static func deliverKey(
        _ combo: KeyCombo,
        pasteboard: NSPasteboard,
        delivery: () throws -> Void
    ) throws {
        // Deliberately inspect no pasteboard state. There is no safe shared-pasteboard
        // transaction to start, so fail before synthesising either key event.
        _ = pasteboard
        try combo.requireClipboardSafeRoute()
        try delivery()
    }

    private static func postKey(_ combo: KeyCombo, to pid: pid_t) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        else { throw SpaceOError.badRequest("could not synthesise key event") }
        down.flags = combo.flags
        up.flags = combo.flags
        down.postToPid(pid)
        usleep(15_000)
        up.postToPid(pid)
        usleep(30_000)
    }

    // MARK: - Mouse

    /// Click inside a window. `localPoint` is relative to the window's top-left, which is what
    /// an agent reading a window screenshot naturally has.
    public static func click(
        _ window: WindowRef,
        at localPoint: CGPoint,
        button: MouseButton = .left,
        clickCount: Int = 1
    ) throws {
        guard (1...3).contains(clickCount) else {
            throw SpaceOError.badRequest("click count must be from 1 through 3")
        }
        guard localPoint.x.isFinite, localPoint.y.isFinite else {
            throw SpaceOError.badRequest("click coordinates must be finite")
        }

        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
        let global = CGPoint(x: bounds.origin.x + localPoint.x, y: bounds.origin.y + localPoint.y)
        guard bounds.insetBy(dx: -1, dy: -1).contains(global) else {
            throw SpaceOError.badRequest(String(format: "point (%.0f,%.0f) is outside the window (%.0fx%.0f)",
                                                localPoint.x, localPoint.y, bounds.width, bounds.height))
        }

        if button == .left, press(at: global, in: window.pid) {
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let userRoute = beginPointerInput(window)
        defer { endPointerInput(userRoute) }

        // Posting straight to a pid bypasses the WindowServer, which is normally the thing that
        // stamps "this event happened over window N" onto a mouse event. Without that stamp an
        // app has no window to route the click to — Chromium's browser process in particular
        // drops it rather than forwarding it to a renderer. So we stamp it ourselves.
        func addressToWindow(_ event: CGEvent) {
            event.setIntegerValueField(windowUnderPointer, value: Int64(window.windowID))
            event.setIntegerValueField(windowUnderPointerThatCanHandleEvent, value: Int64(window.windowID))
        }

        // A move first: apps that track hover state need to believe the pointer arrived, and
        // Chromium uses it to decide which frame is under the cursor.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                              mouseCursorPosition: global, mouseButton: button.cgButton) {
            addressToWindow(move)
            move.postToPid(window.pid)
            usleep(15_000)
        }

        for click in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: source, mouseType: button.downType,
                                     mouseCursorPosition: global, mouseButton: button.cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: button.upType,
                                   mouseCursorPosition: global, mouseButton: button.cgButton)
            else { continue }
            for event in [down, up] {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                addressToWindow(event)
            }
            down.postToPid(window.pid)
            usleep(25_000)
            up.postToPid(window.pid)
            usleep(40_000)
        }
    }

    /// `kCGMouseEventWindowUnderMousePointer`. Not exposed in the Swift overlay.
    static let windowUnderPointer = CGEventField(rawValue: 91)!
    /// `kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent`.
    static let windowUnderPointerThatCanHandleEvent = CGEventField(rawValue: 92)!

    public static func scroll(_ window: WindowRef, dx: Int32 = 0, dy: Int32, ticks: Int = 1) throws {
        guard (1...100).contains(ticks) else {
            throw SpaceOError.badRequest("scroll ticks must be from 1 through 100")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<ticks {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                      wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            else { continue }
            event.postToPid(window.pid)
            usleep(20_000)
        }
    }

    // MARK: - Accessibility actions (preferred)

    /// Press an element directly. Coordinate-free, focus-free, cannot miss, works occluded.
    /// This is the path an agent should use whenever the element is addressable.
    public static func press(_ element: AXUIElement) throws {
        let available = AX.actions(element)
        for candidate in [kAXPressAction, kAXConfirmAction, kAXPickAction, "AXOpen"] {
            if available.contains(candidate as String), AX.perform(element, candidate as String) {
                return
            }
        }
        throw SpaceOError.elementNotPressable(role: AX.role(element), actions: available)
    }

    /// Press the accessible control at a global screen point.
    ///
    /// AppKit accepts AXPress while it can discard coordinate mouse events posted straight to
    /// a background pid. A missing element/action is not a refusal: callers fall through to raw
    /// pointer delivery for canvases, games and custom surfaces.
    public static func press(at global: CGPoint, in pid: pid_t) -> Bool {
        guard let element = AX.element(at: global, in: pid),
              AX.actions(element).contains(kAXPressAction as String) else {
            return false
        }
        return AX.perform(element, kAXPressAction as String)
    }

    /// Set a text field's value outright — faster and more reliable than typing, and it never
    /// touches the keyboard focus at all.
    public static func setValue(_ element: AXUIElement, _ text: String) throws {
        guard text.count <= 8_000, text.unicodeScalars.count <= 8_000,
              text.utf8.count <= 32_000 else {
            throw SpaceOError.badRequest(
                "text is too long (maximum 8000 characters/scalars "
                + "and 32000 UTF-8 bytes)")
        }
        guard AX.setString(element, kAXValueAttribute as String, text) else {
            throw SpaceOError.unsupportedTarget("element rejected a value assignment")
        }
    }
}
