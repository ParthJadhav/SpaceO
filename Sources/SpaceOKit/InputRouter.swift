import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import SpaceOPrivate

public enum MouseButton: String, Sendable, CaseIterable {
    case left, right, middle

    var downType: CGEventType {
        switch self {
        case .left:   return .leftMouseDown
        case .right:  return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left:   return .leftMouseUp
        case .right:  return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var draggedType: CGEventType {
        switch self {
        case .left:   return .leftMouseDragged
        case .right:  return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    var cgButton: CGMouseButton {
        switch self {
        case .left:   return .left
        case .right:  return .right
        case .middle: return .center
        }
    }

    public static func parse(_ raw: String?) throws -> MouseButton {
        guard let raw, !raw.isEmpty else { return .left }
        guard let button = MouseButton(rawValue: raw.lowercased()) else {
            throw SpaceOError.badRequest(
                "button must be one of "
                + MouseButton.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return button
    }
}

/// Modifier keys held down for the duration of a pointer action.
///
/// Parsed separately from `KeyCombo` because a modifier-held click has no key of its own —
/// `shift`, `cmd`, `alt`, `ctrl` and `fn` are the whole request.
public enum ModifierKeys {
    public static func parse(_ names: [String]?) throws -> CGEventFlags {
        guard let names, !names.isEmpty else { return [] }
        guard names.count <= 5 else {
            throw SpaceOError.badRequest("at most 5 modifiers may be held")
        }
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command":       flags.insert(.maskCommand)
            case "shift":                flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control":      flags.insert(.maskControl)
            case "fn":                   flags.insert(.maskSecondaryFn)
            default:
                throw SpaceOError.badRequest(
                    "unknown modifier '\(name)' (use cmd, shift, alt, ctrl, or fn)")
            }
        }
        return flags
    }
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

    enum FocusRecord: Int, CaseIterable, Sendable {
        case activation = 1
        case keyDown = 2
        case keyUp = 3

        var description: String {
            switch self {
            case .activation: return "activation"
            case .keyDown: return "key-window down"
            case .keyUp: return "key-window up"
            }
        }
    }

    /// A failed private record is not evidence of no mutation. Once a record was attempted the
    /// only safe response is to restore and verify the route captured before the transaction.
    enum FocusAttempt: Equatable, Sendable {
        case notAttempted
        case failed(after: FocusRecord)
        case succeeded
    }

    typealias FocusPrimitive = (pid_t, CGWindowID) -> FocusAttempt
    typealias RouteRestorer = (UserInputRoute) -> Bool

    static func privateFocusAttempt(pid: pid_t, windowID: CGWindowID) -> FocusAttempt {
        switch SPOFocusWithoutRaiseResult(pid, windowID) {
        case .notAttempted:
            return .notAttempted
        case .failedAfterActivationRecord:
            return .failed(after: .activation)
        case .failedAfterKeyDownRecord:
            return .failed(after: .keyDown)
        case .failedAfterKeyUpRecord:
            return .failed(after: .keyUp)
        case .succeeded:
            return .succeeded
        @unknown default:
            // An unknown result came back from a private mutation boundary. Treat it as
            // mutation-possible rather than inventing a safe "not attempted" state.
            return .failed(after: .activation)
        }
    }

    private static func unverifiedRecoveryError(_ context: String) -> SpaceOError {
        .unsupportedTarget(
            "\(context) may have changed the system input route, and SpaceO could not verify "
            + "restoration. Input was not sent. Click or activate the app you were using to "
            + "recover keyboard input, then retry after running `spaceo doctor`.")
    }

    /// Execute the three-record private transaction. Every mutation-possible failure restores
    /// the exact route captured before record one; an unverifiable restore is a hard input error.
    @discardableResult
    static func applyFocus(
        _ window: WindowRef,
        recoveringTo originalRoute: UserInputRoute,
        attempt: FocusPrimitive = privateFocusAttempt,
        restore: RouteRestorer = restoreUserInputRoute,
        settle: () -> Void = { usleep(120_000) }
    ) throws -> Bool {
        switch attempt(window.pid, window.windowID) {
        case .notAttempted:
            // No private record was posted, so there is no partial mutation to repair. Optional
            // input priming may safely fall back to direct per-PID delivery.
            return false
        case .failed(let record):
            guard restore(originalRoute) else {
                throw unverifiedRecoveryError(
                    "focus failed at the \(record.description) record for pid \(window.pid)")
            }
            throw SpaceOError.unsupportedTarget(
                "pid \(window.pid) refused the \(record.description) focus record; "
                + "the original user input route was restored and input was not sent")
        case .succeeded:
            AgentActivity.recordFocusFlip()
            settle()
            return true
        }
    }

    /// Make `window` the input target of its app without raising it or switching Space.
    ///
    /// The original route is captured first so a partial private failure can always be repaired.
    public static func focus(_ window: WindowRef) throws {
        guard SPOCapabilityAvailable(.focusWithoutRaise) else {
            let name = SPOCapabilityName(.focusWithoutRaise)
            let reason = SPOCapabilityUnavailableReason(.focusWithoutRaise)
            throw SpaceOError.unavailable(
                capability: reason.map { "\(name): \($0)" } ?? name
            )
        }
        let originalRoute = try captureUserInputRoute(excluding: [window.pid])
        guard try applyFocus(window, recoveringTo: originalRoute) else {
            throw SpaceOError.unsupportedTarget(
                "pid \(window.pid) could not begin the focus transaction; input was not sent")
        }
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
        // Priming improves compatibility but never justifies an un-restorable mutation. If no
        // route can be captured, skip priming and retain direct per-PID delivery.
        guard SPOCapabilityAvailable(.focusWithoutRaise) else { return }
        try prepareForInput(
            window,
            capturedRoute: { try? captureUserInputRoute(excluding: [window.pid]) },
            attempt: privateFocusAttempt,
            restore: restoreUserInputRoute,
            settle: { usleep(120_000) })
    }

    /// Injectable transaction used by focused recovery tests. A throwing result guarantees the
    /// caller will not proceed to its per-PID key, text, or pointer delivery.
    static func prepareForInput(
        _ window: WindowRef,
        capturedRoute: () -> UserInputRoute?,
        attempt: FocusPrimitive,
        restore: RouteRestorer,
        settle: () -> Void = {}
    ) throws {
        guard let userRoute = capturedRoute() else { return }
        guard try applyFocus(
            window,
            recoveringTo: userRoute,
            attempt: attempt,
            restore: restore,
            settle: settle)
        else {
            return
        }
        guard restore(userRoute) else {
            throw unverifiedRecoveryError(
                "focus priming for pid \(window.pid) succeeded, but route recovery")
        }
    }

    /// Hold the target's WindowServer input route for a pointer transaction.
    ///
    /// Some AppKit controls discard per-PID mouse events unless their window remains the
    /// process's input target through mouse-down and mouse-up. This compatibility wrapper is
    /// retained for interactive viewer input. Agent input uses `beginPointerInputChecked(_:)`,
    /// which fails closed when focus recovery cannot be verified.
    public static func beginPointerInput(_ window: WindowRef) -> UserInputRoute? {
        try? beginPointerInputChecked(window)
    }

    /// Agent-input form of `beginPointerInput`: partial failures are restored, and unverifiable
    /// restoration is surfaced so the caller cannot continue posting pointer events.
    public static func beginPointerInputChecked(_ window: WindowRef) throws -> UserInputRoute? {
        guard SPOCapabilityAvailable(.focusWithoutRaise),
              let route = try? captureUserInputRoute(excluding: [window.pid])
        else { return nil }
        guard try applyFocus(window, recoveringTo: route) else { return nil }
        return route
    }

    /// Restore a route returned by `beginPointerInput`.
    public static func endPointerInput(_ route: UserInputRoute?) {
        guard let route else { return }
        _ = restoreUserInputRoute(route)
    }

    public static func endPointerInputChecked(_ route: UserInputRoute?) throws {
        guard let route else { return }
        guard restoreUserInputRoute(route) else {
            throw unverifiedRecoveryError("pointer transaction route recovery")
        }
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
        let pid = route.app.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == pid else {
            return false
        }
        // When capture identified a concrete focused window, restoring only the application is
        // insufficient: another window in that application can be key and receive the user's
        // next keystroke. An unreadable or mismatched focused window therefore fails closed.
        guard route.windowID != 0 else {
            return routeIdentityMatches(
                expectedPID: pid,
                expectedWindowID: 0,
                frontmostPID: frontmostPID,
                focusedWindowID: nil)
        }
        let appElement = AX.application(pid)
        guard AX.setTimeout(appElement, seconds: 0.25),
              let focused = AX.element(appElement, kAXFocusedWindowAttribute as String)
        else {
            return false
        }
        return routeIdentityMatches(
            expectedPID: pid,
            expectedWindowID: route.windowID,
            frontmostPID: frontmostPID,
            focusedWindowID: AX.windowID(focused))
    }

    /// Pure identity check kept separate from the AX query so same-process/wrong-window
    /// recovery has deterministic regression coverage.
    static func routeIdentityMatches(
        expectedPID: pid_t,
        expectedWindowID: CGWindowID,
        frontmostPID: pid_t?,
        focusedWindowID: CGWindowID?
    ) -> Bool {
        guard frontmostPID == expectedPID else { return false }
        return expectedWindowID == 0 || focusedWindowID == expectedWindowID
    }

    @discardableResult
    static func restoreUserInputRoute(_ route: UserInputRoute) -> Bool {
        guard NSRunningApplication(processIdentifier: route.app.processIdentifier) != nil else {
            return false
        }

        var posted = false
        if SPOCapabilityAvailable(.focusWithoutRaise),
           route.windowID != 0,
           privateFocusAttempt(
               pid: route.app.processIdentifier,
               windowID: route.windowID) == .succeeded {
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
                try postEventToPID(down, pid: pid)
                try postEventToPID(up, pid: pid)
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
        try postEventToPID(down, pid: pid)
        usleep(15_000)
        try postEventToPID(up, pid: pid)
        usleep(30_000)
    }

    // MARK: - Mouse

    /// `kCGMouseEventWindowUnderMousePointer`. Not exposed in the Swift overlay.
    static let windowUnderPointer = CGEventField(rawValue: 91)!
    /// `kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent`.
    static let windowUnderPointerThatCanHandleEvent = CGEventField(rawValue: 92)!

    /// Convert a window-local point to global coordinates, refusing points outside the window.
    ///
    /// Agent-facing pointer coordinates are window-local **points**, which is what a screenshot
    /// taken at scale 1 hands back directly. The 1 pt tolerance covers a border click landing
    /// exactly on the edge after the WindowServer's own rounding.
    static func globalPoint(
        _ localPoint: CGPoint,
        in window: WindowRef,
        bounds: CGRect,
        what: String
    ) throws -> CGPoint {
        guard localPoint.x.isFinite, localPoint.y.isFinite else {
            throw SpaceOError.badRequest("\(what) coordinates must be finite")
        }
        let global = CGPoint(x: bounds.origin.x + localPoint.x, y: bounds.origin.y + localPoint.y)
        guard bounds.insetBy(dx: -1, dy: -1).contains(global) else {
            throw SpaceOError.badRequest(
                String(format: "%@ point (%.0f,%.0f) is outside the window (%.0fx%.0f). "
                       + "Coordinates are window-local points; if you read them from a screenshot "
                       + "taken at scale 2, divide by 2.",
                       what, localPoint.x, localPoint.y, bounds.width, bounds.height))
        }
        return global
    }

    /// One pointer transaction against a single window.
    ///
    /// Click, hover, drag and scroll all need the same three things — the target's input route
    /// held for the duration, every event stamped with the window it happened over, and a
    /// verified route restore afterwards. Sharing one body is what keeps a new action from
    /// quietly skipping the stamp: posting straight to a pid bypasses the WindowServer, which is
    /// normally what tells the app which window an event belongs to, and an unstamped event is
    /// dropped rather than delivered.
    private static func withPointerTransaction(
        _ window: WindowRef,
        _ body: (CGEventSource?, (CGEvent) throws -> Void) throws -> Void
    ) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let userRoute = try beginPointerInputChecked(window)
        var routeRecoveryVerified = false
        defer {
            if !routeRecoveryVerified {
                // Best effort after an event-construction error or a failed verification. The
                // throwing checked restore below remains the caller-visible source of truth.
                endPointerInput(userRoute)
            }
        }

        func post(_ event: CGEvent) throws {
            event.setIntegerValueField(windowUnderPointer, value: Int64(window.windowID))
            event.setIntegerValueField(
                windowUnderPointerThatCanHandleEvent, value: Int64(window.windowID))
            try postEventToPID(event, pid: window.pid)
        }

        try body(source, post)
        try endPointerInputChecked(userRoute)
        routeRecoveryVerified = true
    }

    /// Click inside a window. `localPoint` is relative to the window's top-left, which is what
    /// an agent reading a window screenshot naturally has.
    ///
    /// The accessibility shortcut is taken only for a plain single left click. A modifier-held,
    /// multi-, or non-left click means something different from `AXPress` — shift-click extends a
    /// selection, double-click selects a word, right-click opens a context menu — so silently
    /// substituting a press would report success for an action that never happened.
    /// How a pointer action actually reached the target, so a caller can tell a confirmed action
    /// from one that was merely posted.
    public enum PointerDelivery: String, Sendable {
        /// An accessibility action the target acknowledged. Confirmed.
        case accessibility
        /// Synthetic events posted per-PID. On a host without the focus-without-raise record
        /// these are **not known to reach AppKit** — measured on macOS 27, a coordinate click
        /// into a TextEdit document did not move the insertion point, and scroll wheel events
        /// moved nothing, while both reported success.
        case syntheticUnverified

        public var isConfirmed: Bool { self == .accessibility }
    }

    @discardableResult
    public static func click(
        _ window: WindowRef,
        at localPoint: CGPoint,
        button: MouseButton = .left,
        clickCount: Int = 1,
        modifiers: CGEventFlags = []
    ) throws -> PointerDelivery {
        guard (1...3).contains(clickCount) else {
            throw SpaceOError.badRequest("click count must be from 1 through 3")
        }
        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
        let global = try globalPoint(localPoint, in: window, bounds: bounds, what: "click")

        if button == .left, clickCount == 1, modifiers.isEmpty,
           press(at: global, in: window.pid) {
            return .accessibility
        }

        try withPointerTransaction(window) { source, post in
            // A move first: apps that track hover state need to believe the pointer arrived, and
            // Chromium uses it to decide which frame is under the cursor.
            if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: global, mouseButton: button.cgButton) {
                move.flags = modifiers
                try post(move)
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
                    event.flags = modifiers
                }
                try post(down)
                usleep(25_000)
                try post(up)
                usleep(40_000)
            }
        }
        return .syntheticUnverified
    }

    /// The sentence a caller should show when a pointer action could only be posted, not
    /// confirmed. Kept in one place so click, drag, and hover word it identically.
    public static func unverifiedDeliveryNote(_ action: String) -> String {
        "the \(action) was posted as synthetic per-PID events but could not be confirmed: no "
        + "accessibility element accepted it, and this host has no focus-without-raise record, "
        + "where synthetic pointer events are not known to reach AppKit. Verify with a "
        + "screenshot, or address the control by element index from read_screen."
    }

    /// Move the pointer over a window-local point without pressing anything.
    ///
    /// Hover-only affordances — menus that open on hover, tooltips, drag handles that fade in —
    /// are invisible to an agent that can only click, because the control it needs to press does
    /// not exist in the accessibility tree until something hovers it.
    public static func move(
        _ window: WindowRef,
        to localPoint: CGPoint,
        modifiers: CGEventFlags = []
    ) throws {
        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
        let global = try globalPoint(localPoint, in: window, bounds: bounds, what: "move")

        try withPointerTransaction(window) { source, post in
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                     mouseCursorPosition: global, mouseButton: .left)
            else { throw SpaceOError.badRequest("could not synthesise a pointer move") }
            move.flags = modifiers
            try post(move)
            usleep(15_000)
        }
    }

    /// Press at one window-local point, drag to another, and release.
    ///
    /// The intermediate moves are not cosmetic. A down followed immediately by an up at a
    /// different point reads as a click at the destination to most controls; sliders, selection,
    /// and reordering all need to see the pointer travel.
    public static func drag(
        _ window: WindowRef,
        from startLocal: CGPoint,
        to endLocal: CGPoint,
        button: MouseButton = .left,
        modifiers: CGEventFlags = [],
        steps: Int = 12
    ) throws {
        guard (1...200).contains(steps) else {
            throw SpaceOError.badRequest("drag steps must be from 1 through 200")
        }
        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
        let start = try globalPoint(startLocal, in: window, bounds: bounds, what: "drag start")
        let end = try globalPoint(endLocal, in: window, bounds: bounds, what: "drag end")

        try withPointerTransaction(window) { source, post in
            func mouse(_ type: CGEventType, _ at: CGPoint) throws {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                          mouseCursorPosition: at, mouseButton: button.cgButton)
                else { throw SpaceOError.badRequest("could not synthesise a drag event") }
                event.flags = modifiers
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                try post(event)
            }

            try mouse(.mouseMoved, start)
            usleep(15_000)
            try mouse(button.downType, start)
            usleep(25_000)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                try mouse(button.draggedType,
                          CGPoint(x: start.x + (end.x - start.x) * t,
                                  y: start.y + (end.y - start.y) * t))
                usleep(12_000)
            }
            try mouse(button.upType, end)
            usleep(40_000)
        }
    }

    /// Scroll over a window-local point. Positive `dy` scrolls content up (finger-down gesture).
    ///
    /// A point is required rather than optional: an app with two scrollable regions routes the
    /// wheel by what is under the pointer, so an unpositioned scroll is a coin flip.
    public static func scroll(
        _ window: WindowRef,
        at localPoint: CGPoint,
        dx: Int32 = 0,
        dy: Int32,
        ticks: Int = 1,
        modifiers: CGEventFlags = []
    ) throws {
        guard (1...100).contains(ticks) else {
            throw SpaceOError.badRequest("scroll ticks must be from 1 through 100")
        }
        guard (-10_000...10_000).contains(dx), (-10_000...10_000).contains(dy) else {
            throw SpaceOError.badRequest("scroll deltas must be from -10000 through 10000 pixels")
        }
        guard dx != 0 || dy != 0 else {
            throw SpaceOError.badRequest("scroll needs a non-zero dx or dy")
        }
        let bounds = try WindowPlacement.liveBounds(of: window.windowID)
        let global = try globalPoint(localPoint, in: window, bounds: bounds, what: "scroll")

        // Accessibility first, and it is not a nicety. Synthetic scroll wheel events posted with
        // `CGEventPostToPid` do not reach AppKit on a host without the private
        // focus-without-raise record — measured against TextEdit on macOS 27 across pixel and
        // line units, stamped and unstamped, with and without an explicit location: every
        // variant reported success and moved nothing. A scroll bar's AXValue is public, settable,
        // and readable back, so this path can prove it worked.
        if let area = AX.scrollArea(
            at: global, in: window.pid, windowID: window.windowID) {
            var moved = false
            for _ in 0..<ticks {
                // Positive dy scrolls content up, which means moving *back* towards the top.
                if dy != 0,
                   AX.scroll(area, byPixels: CGFloat(-dy)) != nil { moved = true }
                if dx != 0,
                   AX.scroll(area, byPixels: CGFloat(-dx), horizontal: true) != nil { moved = true }
                usleep(20_000)
            }
            if moved { return }
        }

        // No scroll area, or one that refused: fall back to the synthetic wheel rather than
        // refusing outright, because a canvas or custom surface may consume wheel events without
        // exposing a scroll bar. The caller is told which path ran.
        try withPointerTransaction(window) { source, post in
            // Position the pointer first so the app routes the wheel to the region the agent
            // aimed at rather than wherever it last believed the pointer was.
            if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: global, mouseButton: .left) {
                move.flags = modifiers
                try post(move)
                usleep(15_000)
            }
            for _ in 0..<ticks {
                guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                          wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
                else { throw SpaceOError.badRequest("could not synthesise a scroll event") }
                event.flags = modifiers
                event.location = global
                try post(event)
                usleep(20_000)
            }
        }
        throw SpaceOError.unsupportedTarget(
            "no scrollable accessibility element was found at (\(Int(localPoint.x)),"
            + "\(Int(localPoint.y))), so the scroll fell back to synthetic wheel events. "
            + "This host has no focus-without-raise record, where per-PID wheel events are not "
            + "known to reach AppKit — treat this scroll as unconfirmed and verify with a "
            + "screenshot rather than assuming the view moved.")
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
