import AppKit
import CoreGraphics
import SpaceOKit

/// AppKit drags in QuickDraw's ancient `WindowRef` typedef; in this module the name always
/// means SpaceOKit's window reference.
typealias WindowRef = SpaceOKit.WindowRef

struct InputNote: Equatable, Sendable {
    let text: String
    let isWarning: Bool
}

/// A transition has two restoration opportunities. The first promptly releases an established
/// pointer route; the second catches a route published by a mouse-down that was already running
/// when the input gate changed.
enum ViewerInputTransition {
    static func drainAndRestore(
        restore: () -> Void,
        drain: () -> Void
    ) {
        restore()
        drain()
        restore()
    }
}

/// The one keyboard chord the Viewer owns while remote Control is active.
///
/// An unmodified Escape must remain available to remote apps, and Control-Option is VoiceOver's
/// modifier. Control-Command-Escape is therefore reserved locally: it is uncommon in apps,
/// remains reachable with VoiceOver running, and is shown anywhere Control state is described.
enum ViewerControlPolicy {
    static let localExitDescription = "Control-Command-Escape"
    static let localExitKeyCode: UInt16 = 53

    enum KeyDisposition: Equatable {
        case local
        case forward
        case exitControl
    }

    enum ControlRequestDisposition: Equatable {
        case enable
        case disable
        case blocked(String)
    }

    static func keyDisposition(interactionEnabled: Bool,
                               keyCode: UInt16,
                               modifiers: NSEvent.ModifierFlags) -> KeyDisposition {
        guard interactionEnabled else { return .local }
        if isLocalExitChord(keyCode: keyCode, modifiers: modifiers) {
            return .exitControl
        }
        return .forward
    }

    static func isLocalExitChord(keyCode: UInt16,
                                 modifiers: NSEvent.ModifierFlags) -> Bool {
        let meaningful = modifiers.intersection([.command, .control, .option, .shift])
        return keyCode == localExitKeyCode && meaningful == [.command, .control]
    }

    static func controlRequest(enabling: Bool,
                               hasSelectedDisplay: Bool,
                               streamRunning: Bool,
                               screenRecordingGranted: Bool,
                               accessibilityGranted: Bool) -> ControlRequestDisposition {
        guard enabling else { return .disable }
        guard hasSelectedDisplay else {
            return .blocked("Control unavailable. Select a display first.")
        }
        guard streamRunning else {
            return .blocked(
                "Control unavailable. Wait for a live stream before sending input."
            )
        }
        guard screenRecordingGranted else {
            return .blocked(
                "Control unavailable. Screen Recording permission is required to see the "
                    + "display before sending input."
            )
        }
        guard accessibilityGranted else {
            return .blocked(
                "Control unavailable. Accessibility permission is required to send input "
                    + "to the selected display."
            )
        }
        return .enable
    }
}

enum ViewerAccessibility {
    static func surfaceLabel(displayName: String) -> String {
        "Remote display, \(displayName)"
    }

    static func surfaceValue(streamRunning: Bool, controlEnabled: Bool) -> String {
        let stream = streamRunning ? "Live stream" : "Stream unavailable"
        let control = controlEnabled
            ? "Control enabled"
            : "Viewing only"
        return "\(stream). \(control)."
    }

    static func surfaceHelp(streamRunning: Bool, controlEnabled: Bool) -> String {
        if controlEnabled {
            return "Keyboard and pointer input go to the remote display. Press "
                + "\(ViewerControlPolicy.localExitDescription) to exit Control."
        }
        if !streamRunning {
            return "The remote display stream is unavailable. Control cannot be enabled until "
                + "the stream is live."
        }
        return "A streamed remote display. Turn on Control to send keyboard and pointer input."
    }

    static func controlAnnouncement(enabled: Bool, displayName: String?) -> String {
        if enabled {
            let destination = displayName.map { " for \($0)" } ?? ""
            return "Control enabled\(destination). Keyboard and pointer input now go to the "
                + "remote display. Press \(ViewerControlPolicy.localExitDescription) to exit."
        }
        return "Control disabled. Keyboard and pointer input stay on this Mac."
    }
}

/// Turns NSEvents from the console surface into per-PID deliveries on a background queue.
///
/// VM semantics live here: a drag keeps going to the window it started on even when the pointer
/// crosses another window, and the keyboard follows the last window the user clicked. Nothing
/// in this path activates an app, raises a window, or moves the real cursor.
/// Mutable delivery state is either queue-confined or protected by `stateLock`/`routeLock`.
/// UI callbacks are always invoked on the main queue.
final class ViewerInputController: @unchecked Sendable {

    typealias KeyPoster = (_ code: CGKeyCode, _ flags: CGEventFlags, _ down: Bool,
                           _ characters: String?, _ pid: pid_t) throws -> Void
    typealias FrontWindowProvider = (_ displayBounds: CGRect) -> WindowRef?

    var onNote: ((InputNote?) -> Void)?

    private let queue = DispatchQueue(label: "spaceo.viewer.input", qos: .userInteractive)
    private let postKeyEvent: KeyPoster
    private let frontWindowProvider: FrontWindowProvider
    private let stateLock = NSLock()
    private var _display: DisplayEntry?
    private var _interactionEnabled = false

    /// The authority on whether a queued event may still be delivered. Bumped synchronously on
    /// every Control or display transition, so events already on the queue are invalid before
    /// the cleanup that follows them is even scheduled.
    private let gate = InputControlGate()

    // Queue-confined.
    private var dragTarget: WindowRef?
    private var keyTarget: WindowRef?
    private var accessibilityPressHandled = false
    private var pointerTransactionBlocked = false
    private var lastMoveUptime: UInt64 = 0
    private var candidateCache: (uptime: UInt64, list: [MirrorInput.WindowCandidate])?
    private var lastNote: InputNote?
    private struct HeldKey {
        let keyCode: UInt16
        let flags: CGEventFlags
        let characters: String?
        let pid: pid_t
    }
    private var heldKeys: [UInt16: HeldKey] = [:]

    /// Held input state that must be released *promptly* on a transition, so it is guarded by a
    /// lock rather than confined to the queue. Restoring the user's input route is the one piece
    /// of cleanup that cannot be allowed to wait behind a backlog of events it is cancelling.
    private let routeLock = NSLock()
    private var pointerRoute: InputRouter.UserInputRoute?

    /// `CGEvent` is an immutable copy by the time it crosses onto the delivery queue, but the
    /// CoreGraphics SDK does not annotate the reference type as Sendable.
    private struct EventTemplate: @unchecked Sendable {
        let value: CGEvent?
    }

    init(
        keyPoster: @escaping KeyPoster = { code, flags, down, characters, pid in
            try MirrorInput.postKey(code: code, flags: flags, down: down,
                                    characters: characters, to: pid)
        },
        frontWindowProvider: @escaping FrontWindowProvider = { displayBounds in
            MirrorInput.frontWindow(on: displayBounds,
                                    excluding: MirrorInput.selfExcludedPIDs)
        }
    ) {
        postKeyEvent = keyPoster
        self.frontWindowProvider = frontWindowProvider
    }

    var display: DisplayEntry? {
        get { stateLock.withLock { _display } }
        set {
            stateLock.withLock { _display = newValue }
            // Order matters. Invalidate first: every event already queued for the old display
            // becomes a no-op immediately, rather than executing against it. Then release held
            // state synchronously; invalid queued events drain as no-ops before cleanup runs.
            gate.select(displayID: newValue?.id)
            ViewerInputTransition.drainAndRestore(
                restore: { restorePointerRoute() },
                drain: {
                    // Synchronizing here lets any currently executing down finish and be
                    // recorded. The gate rejects queued/new work, then matching ups are
                    // delivered before targets clear.
                    queue.sync {
                        releaseHeldKeys()
                        dragTarget = nil
                        keyTarget = nil
                        accessibilityPressHandled = false
                        pointerTransactionBlocked = false
                        candidateCache = nil
                    }
                })
            stateLock.withLock { _interactionEnabled = false }
        }
    }

    var interactionEnabled: Bool {
        get { stateLock.withLock { _interactionEnabled } }
        set {
            if newValue {
                let display = stateLock.withLock { () -> DisplayEntry? in
                    _interactionEnabled = true
                    return _display
                }
                if let display {
                    gate.enable(displayID: display.id)
                    return
                }
            }
            gate.disable()
            ViewerInputTransition.drainAndRestore(
                restore: { restorePointerRoute() },
                drain: {
                    queue.sync {
                        releaseHeldKeys()
                        dragTarget = nil
                        keyTarget = nil
                        accessibilityPressHandled = false
                        pointerTransactionBlocked = false
                        lastNote = nil
                    }
                })
            stateLock.withLock { _interactionEnabled = false }
        }
    }

    // MARK: - Event entry points (called on the main thread)
    //
    // Each admits against the gate here and carries the resulting ticket across the queue hop.
    // Admission alone is not permission to deliver — the ticket is rechecked at the far end.

    func pointer(_ phase: MirrorInput.PointerPhase,
                 button: MouseButton,
                 viewPoint: CGPoint,
                 viewSize: CGSize,
                 clickCount: Int,
                 template: CGEvent?) {
        guard let display = permittedDisplay(), let ticket = gate.admit() else { return }
        let eventTemplate = EventTemplate(value: template)
        queue.async { [weak self] in
            guard let self, self.gate.isCurrent(ticket) else { return }
            self.deliverPointer(phase, button: button, on: display,
                                viewPoint: viewPoint, viewSize: viewSize,
                                clickCount: clickCount, template: eventTemplate.value)
        }
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat, viewPoint: CGPoint, viewSize: CGSize) {
        guard let display = permittedDisplay(), let ticket = gate.admit() else { return }
        queue.async { [weak self] in
            guard let self, self.gate.isCurrent(ticket) else { return }
            self.deliverScroll(deltaX: deltaX, deltaY: deltaY, on: display,
                               viewPoint: viewPoint, viewSize: viewSize)
        }
    }

    func key(down: Bool, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        guard let display = permittedDisplay(), let ticket = gate.admit() else { return }
        queue.async { [weak self] in
            guard let self, self.gate.isCurrent(ticket) else { return }
            self.deliverKey(down: down, keyCode: keyCode, modifiers: modifiers,
                            characters: characters, on: display)
        }
    }

    // MARK: - Delivery (queue-confined)

    private func deliverPointer(_ phase: MirrorInput.PointerPhase,
                                button: MouseButton,
                                on display: DisplayEntry,
                                viewPoint: CGPoint,
                                viewSize: CGSize,
                                clickCount: Int,
                                template: CGEvent?) {
        defer {
            if phase == .up {
                restorePointerRoute()
            }
        }
        if pointerTransactionBlocked {
            if phase == .down {
                pointerTransactionBlocked = false
            } else {
                if phase == .up { pointerTransactionBlocked = false }
                return
            }
        }
        let mapping = MirrorInput.ViewportMapping(displayBounds: display.bounds,
                                                  viewSize: viewSize)
        guard let global = mapping.globalPoint(fromViewPoint: viewPoint) else { return }

        if phase == .move || phase == .drag {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now &- lastMoveUptime >= 8_000_000 else { return }   // ~120 Hz ceiling
            lastMoveUptime = now
        }

        let target: WindowRef?
        switch phase {
        case .down:
            restorePointerRoute()
            accessibilityPressHandled = false
            target = hitTest(at: global)
            dragTarget = target
        case .drag:
            target = dragTarget ?? hitTest(at: global)
        case .up:
            target = dragTarget ?? hitTest(at: global)
            dragTarget = nil
        case .move:
            target = hitTest(at: global)
        }
        guard let target else {
            if phase == .down { note("nothing to click there — that part of the stage is empty") }
            return
        }

        if accessibilityPressHandled {
            if phase == .up { accessibilityPressHandled = false }
            return
        }

        do {
            if phase == .down {
                if button == .left, InputRouter.press(at: global, in: target.pid) {
                    accessibilityPressHandled = true
                    keyTarget = target
                    describeTarget(target)
                    return
                }
                // Keep the target's input route through mouse-up. AppKit controls can discard
                // per-PID pointer events if the route is restored between down and up.
                // A mutation-possible focus failure must restore successfully; otherwise checked
                // preparation throws here before any pointer event is delivered.
                let captured = try InputRouter.beginPointerInputChecked(target)
                routeLock.withLock { pointerRoute = captured }
                try MirrorInput.postPointer(.move, button: button, at: global, to: target,
                                            clickCount: 1, template: template)
                usleep(15_000)
            }
            try MirrorInput.postPointer(phase, button: button, at: global, to: target,
                                        clickCount: max(1, min(3, clickCount)),
                                        template: template)
            if phase == .down {
                keyTarget = target
                usleep(25_000)
            } else if phase == .up {
                usleep(40_000)
            }
            if phase == .down { describeTarget(target) }
        } catch {
            if phase == .down {
                // Do not let drag/up events continue a pointer transaction whose checked route
                // preparation or initial delivery failed.
                pointerTransactionBlocked = true
                dragTarget = nil
                restorePointerRoute()
            }
            note(error.localizedDescription, warning: true)
        }
    }

    private func deliverScroll(deltaX: CGFloat, deltaY: CGFloat,
                               on display: DisplayEntry,
                               viewPoint: CGPoint,
                               viewSize: CGSize) {
        let mapping = MirrorInput.ViewportMapping(displayBounds: display.bounds,
                                                  viewSize: viewSize)
        guard let global = mapping.globalPoint(fromViewPoint: viewPoint),
              let target = hitTest(at: global) else { return }
        let dx = Int32(max(-500, min(500, deltaX.rounded())))
        let dy = Int32(max(-500, min(500, deltaY.rounded())))
        guard dx != 0 || dy != 0 else { return }
        do {
            let userRoute = try InputRouter.beginPointerInputChecked(target)
            var recoveryVerified = false
            defer {
                if !recoveryVerified {
                    InputRouter.endPointerInput(userRoute)
                }
            }
            try MirrorInput.postScroll(dx: dx, dy: dy, at: global, to: target)
            try InputRouter.endPointerInputChecked(userRoute)
            recoveryVerified = true
        } catch {
            note(error.localizedDescription, warning: true)
        }
    }

    private func deliverKey(down: Bool, keyCode: UInt16,
                            modifiers: NSEvent.ModifierFlags,
                            characters: String?,
                            on display: DisplayEntry) {
        let flags = MirrorInput.flags(from: modifiers)
        if let held = heldKeys[keyCode] {
            do {
                try postKeyEvent(CGKeyCode(keyCode), flags, down, characters, held.pid)
                if !down { heldKeys.removeValue(forKey: keyCode) }
            } catch {
                note(error.localizedDescription, warning: true)
            }
            return
        }

        // The clicked window may have closed since; fall back to the stage's front window.
        if let current = keyTarget,
           (try? WindowPlacement.liveBounds(of: current.windowID)) == nil {
            keyTarget = nil
        }
        let target = keyTarget ?? frontWindowProvider(display.bounds)
        guard let target else {
            if down { note("no window on this stage to type into — click one first") }
            return
        }
        keyTarget = target
        do {
            try postKeyEvent(CGKeyCode(keyCode), flags, down, characters, target.pid)
            if down {
                heldKeys[keyCode] = HeldKey(keyCode: keyCode, flags: flags,
                                            characters: characters, pid: target.pid)
            }
        } catch {
            note(error.localizedDescription, warning: true)
        }
    }

    // MARK: - Hit-testing

    /// Window enumeration costs a WindowServer round trip, so pointer streams reuse a list for
    /// up to 100 ms. Clicks land on whatever the last few frames showed anyway.
    /// Excluded from every selection: viewing a physical display that contains the viewer's own
    /// window would otherwise let a click select that window and be posted straight back into
    /// this process, which drives the viewer's own controls and feeds itself forever.
    private func hitTest(at global: CGPoint) -> WindowRef? {
        let now = DispatchTime.now().uptimeNanoseconds
        let list: [MirrorInput.WindowCandidate]
        if let cache = candidateCache, now &- cache.uptime < 100_000_000 {
            list = cache.list
        } else {
            list = MirrorInput.onScreenCandidates()
            candidateCache = (now, list)
        }
        return MirrorInput.selectTarget(from: list, containing: global,
                                        excluding: MirrorInput.selfExcludedPIDs)?.ref
    }

    // MARK: - Support

    private func permittedDisplay() -> DisplayEntry? {
        let (display, enabled) = stateLock.withLock { (_display, _interactionEnabled) }
        guard enabled, let display else { return nil }
        return display
    }

    /// Queue-confined transition cleanup. Every down successfully sent to a target gets one final
    /// up sent to that same PID before the target and Control state are discarded.
    private func releaseHeldKeys() {
        let releases = Array(heldKeys.values)
        heldKeys.removeAll()
        for held in releases {
            do {
                try postKeyEvent(CGKeyCode(held.keyCode), held.flags, false,
                                 held.characters, held.pid)
            } catch {
                note("could not release remote key \(held.keyCode): "
                     + error.localizedDescription, warning: true)
            }
        }
    }

    /// Safe to call from any thread, and idempotent — a transition on the main thread and the
    /// mouse-up path on the input queue can both reach it.
    private func restorePointerRoute() {
        let route = routeLock.withLock { () -> InputRouter.UserInputRoute? in
            defer { pointerRoute = nil }
            return pointerRoute
        }
        guard let route else { return }
        do {
            try InputRouter.endPointerInputChecked(route)
        } catch {
            // One best-effort retry can still recover the user's route, but the failed verified
            // recovery remains a visible warning rather than being silently swallowed.
            InputRouter.endPointerInput(route)
            let warning = InputNote(
                text: "Pointer input stopped because the local input route could not be "
                    + "verified as restored: \(error.localizedDescription)",
                isWarning: true
            )
            DispatchQueue.main.async { [weak self] in self?.onNote?(warning) }
        }
    }

    private func describeTarget(_ target: WindowRef) {
        let app = NSRunningApplication(processIdentifier: target.pid)?.localizedName
            ?? "pid \(target.pid)"
        var text = "driving \(app)"
        if !target.title.isEmpty { text += " — \(target.title)" }
        note(text)
    }

    private func note(_ text: String?, warning: Bool = false) {
        let value = text.map { InputNote(text: $0, isWarning: warning) }
        guard value != lastNote else { return }
        lastNote = value
        DispatchQueue.main.async { [weak self] in self?.onNote?(value) }
    }
}
