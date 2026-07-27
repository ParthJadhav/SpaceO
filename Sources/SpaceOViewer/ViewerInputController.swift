import AppKit
import CoreGraphics
import SpaceOKit

/// AppKit drags in QuickDraw's ancient `WindowRef` typedef; in this module the name always
/// means SpaceOKit's window reference.
typealias WindowRef = SpaceOKit.WindowRef

struct InputNote: Equatable {
    let text: String
    let isWarning: Bool
}

/// Turns NSEvents from the console surface into per-PID deliveries on a background queue.
///
/// VM semantics live here: a drag keeps going to the window it started on even when the pointer
/// crosses another window, and the keyboard follows the last window the user clicked. Nothing
/// in this path activates an app, raises a window, or moves the real cursor.
final class ViewerInputController {

    var onNote: ((InputNote?) -> Void)?

    private let queue = DispatchQueue(label: "spaceo.viewer.input", qos: .userInteractive)
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
    private var lastMoveUptime: UInt64 = 0
    private var candidateCache: (uptime: UInt64, list: [MirrorInput.WindowCandidate])?
    private var lastNote: InputNote?

    /// Held input state that must be released *promptly* on a transition, so it is guarded by a
    /// lock rather than confined to the queue. Restoring the user's input route is the one piece
    /// of cleanup that cannot be allowed to wait behind a backlog of events it is cancelling.
    private let routeLock = NSLock()
    private var pointerRoute: InputRouter.UserInputRoute?

    var display: DisplayEntry? {
        get { stateLock.withLock { _display } }
        set {
            stateLock.withLock { _display = newValue }
            // Order matters. Invalidate first: every event already queued for the old display
            // becomes a no-op immediately, rather than executing against it. Then release held
            // state, synchronously, without joining the queue behind that backlog.
            gate.select(displayID: newValue?.id)
            stateLock.withLock { _interactionEnabled = false }
            restorePointerRoute()
            queue.async { [weak self] in
                self?.dragTarget = nil
                self?.keyTarget = nil
                self?.accessibilityPressHandled = false
                self?.candidateCache = nil
            }
        }
    }

    var interactionEnabled: Bool {
        get { stateLock.withLock { _interactionEnabled } }
        set {
            let display = stateLock.withLock { () -> DisplayEntry? in
                _interactionEnabled = newValue
                return _display
            }
            if newValue, let display {
                gate.enable(displayID: display.id)
                return
            }
            gate.disable()
            restorePointerRoute()
            queue.async { [weak self] in
                self?.dragTarget = nil
                self?.keyTarget = nil
                self?.accessibilityPressHandled = false
                self?.lastNote = nil
            }
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
        queue.async { [weak self] in
            guard let self, self.gate.isCurrent(ticket) else { return }
            self.deliverPointer(phase, button: button, on: display,
                                viewPoint: viewPoint, viewSize: viewSize,
                                clickCount: clickCount, template: template)
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
            keyTarget = target ?? keyTarget
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
                    describeTarget(target)
                    return
                }
                // Keep the target's input route through mouse-up. AppKit controls can discard
                // per-PID pointer events if the route is restored between down and up.
                // Route capture/focus is best-effort and never gates direct delivery.
                let captured = InputRouter.beginPointerInput(target)
                routeLock.withLock { pointerRoute = captured }
                try MirrorInput.postPointer(.move, button: button, at: global, to: target,
                                            clickCount: 1, template: template)
                usleep(15_000)
            }
            try MirrorInput.postPointer(phase, button: button, at: global, to: target,
                                        clickCount: max(1, min(3, clickCount)),
                                        template: template)
            if phase == .down {
                usleep(25_000)
            } else if phase == .up {
                usleep(40_000)
            }
            if phase == .down { describeTarget(target) }
        } catch {
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
        let userRoute = InputRouter.beginPointerInput(target)
        defer { InputRouter.endPointerInput(userRoute) }
        do {
            try MirrorInput.postScroll(dx: dx, dy: dy, at: global, to: target)
        } catch {
            note(error.localizedDescription, warning: true)
        }
    }

    private func deliverKey(down: Bool, keyCode: UInt16,
                            modifiers: NSEvent.ModifierFlags,
                            characters: String?,
                            on display: DisplayEntry) {
        // The clicked window may have closed since; fall back to the stage's front window.
        if let current = keyTarget,
           (try? WindowPlacement.liveBounds(of: current.windowID)) == nil {
            keyTarget = nil
        }
        let target = keyTarget ?? MirrorInput.frontWindow(
            on: display.bounds, excluding: MirrorInput.selfExcludedPIDs)
        guard let target else {
            if down { note("no window on this stage to type into — click one first") }
            return
        }
        keyTarget = target
        do {
            try MirrorInput.postKey(code: CGKeyCode(keyCode),
                                    flags: MirrorInput.flags(from: modifiers),
                                    down: down,
                                    characters: characters,
                                    to: target.pid)
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

    /// Safe to call from any thread, and idempotent — a transition on the main thread and the
    /// mouse-up path on the input queue can both reach it.
    private func restorePointerRoute() {
        let route = routeLock.withLock { () -> InputRouter.UserInputRoute? in
            defer { pointerRoute = nil }
            return pointerRoute
        }
        guard let route else { return }
        InputRouter.endPointerInput(route)
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
