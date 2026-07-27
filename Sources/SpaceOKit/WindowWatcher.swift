import Foundation
import ApplicationServices
import CoreGraphics

/// Catches windows an app opens *after* launch and pulls them into the session's tile.
///
/// One-shot placement at launch is not enough. Real apps open windows later — a restore-session
/// prompt, an update notice, a file dialog, a second document — and every one of those appears
/// on whichever display macOS feels like, which in practice means the user's. Measured with
/// Cursor: its "Reopen?" dialog landed in the middle of the user's screen a second after launch.
///
/// That is precisely the intrusion SpaceO exists to prevent, so we watch for new windows and
/// relocate them on the notification rather than on a poll.
public final class WindowWatcher {

    public typealias Placement = (WindowRef) -> Void

    /// What the AX callback's refcon actually points at.
    ///
    /// The observer outlives an in-flight callback dispatch, but the watcher may not: a session
    /// can be destroyed on the daemon actor while the main run loop is still inside the
    /// callback. A raw unretained watcher pointer there is a use-after-free. The box is retained
    /// by the refcon itself and holds the watcher only weakly, so a late callback resolves to
    /// nil instead of a dangling pointer.
    private final class CallbackTarget {
        weak var watcher: WindowWatcher?
        init(_ watcher: WindowWatcher) { self.watcher = watcher }
    }

    /// Registered in `init` and removed in `stop()` — one list so the two cannot drift.
    private static let observedNotifications = [kAXWindowCreatedNotification,
                                                kAXFocusedWindowChangedNotification,
                                                kAXApplicationShownNotification]

    private let pid: pid_t
    private let region: () -> CGRect
    private let onPlaced: Placement?
    private var observer: AXObserver?
    private var callbackTarget: Unmanaged<CallbackTarget>?
    private let element: AXUIElement

    /// Windows we have already dealt with, so a re-notification does not re-move a window the
    /// agent has since positioned deliberately.
    private var handled = Set<CGWindowID>()
    private var refused = Set<CGWindowID>()
    private let lock = NSLock()
    private let sweepLock = NSLock()

    private var placedTotal = 0
    public var placedCount: Int { lock.withLock { placedTotal } }
    public var refusedCount: Int { lock.withLock { refused.count } }

    /// - Parameter region: read lazily, because a session's tile can move if the display
    ///   arrangement changes.
    public init?(pid: pid_t, region: @escaping () -> CGRect, onPlaced: Placement? = nil) {
        self.pid = pid
        self.region = region
        self.onPlaced = onPlaced
        self.element = AXUIElementCreateApplication(pid)

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let target = Unmanaged<CallbackTarget>.fromOpaque(refcon).takeUnretainedValue()
            target.watcher?.sweep()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
            return nil
        }
        self.observer = observer

        let target = Unmanaged.passRetained(CallbackTarget(self))
        self.callbackTarget = target
        let context = target.toOpaque()
        for notification in Self.observedNotifications {
            AXObserverAddNotification(observer, element, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
    }

    /// Move any window of this app that is not already inside the region.
    ///
    /// Driven by the notification rather than a timer, but written as a full sweep because
    /// `kAXWindowCreated` does not reliably tell you *which* window appeared.
    public func sweep() {
        guard sweepLock.try() else { return }
        defer { sweepLock.unlock() }
        let target = region()
        guard target.width > 0 else { return }

        let currentWindows = WindowPlacement.windows(of: pid)
        let liveIDs = Set(currentWindows.map(\.windowID))
        lock.withLock {
            // Closed windows must not remain in the accounting forever. In particular, a
            // refused modal sheet that later closes should stop making every future audit fail.
            handled.formIntersection(liveIDs)
            refused.formIntersection(liveIDs)
        }

        for window in currentWindows {
            let alreadyHandled = lock.withLock { handled.contains(window.windowID) }
            if alreadyHandled { continue }
            if WindowPlacement.isInRegion(window, target) {
                lock.withLock { _ = handled.insert(window.windowID) }
                continue
            }

            // Sheets and some dialogs refuse AXPosition. Try, and count the refusals rather
            // than pretending they were contained.
            let frame = WindowPlacement.defaultFrame(in: target)
            let fitted = CGRect(origin: frame.origin,
                                size: CGSize(width: min(frame.width, max(320, window.frame.width)),
                                             height: min(frame.height, max(240, window.frame.height))))
            if let placed = try? WindowPlacement.move(window, to: fitted),
               target.contains(CGPoint(x: placed.midX, y: placed.midY)) {
                lock.withLock {
                    handled.insert(window.windowID)
                    refused.remove(window.windowID)
                    placedTotal += 1
                }
                onPlaced?(WindowRef(windowID: window.windowID, pid: pid,
                                    title: window.title, frame: placed))
            } else {
                _ = lock.withLock { refused.insert(window.windowID) }
            }
        }
    }

    /// Forget a window so a later sweep will reposition it again.
    public func release(_ windowID: CGWindowID) {
        lock.withLock {
            _ = handled.remove(windowID)
            _ = refused.remove(windowID)
        }
    }

    public func stop() {
        // Idempotent and thread-safe: destroy paths can race a deinit-driven stop.
        // `observer` and `callbackTarget` are set together in init, so take them together.
        let state: (observer: AXObserver, target: Unmanaged<CallbackTarget>)? = lock.withLock {
            guard let observer, let target = callbackTarget else { return nil }
            self.observer = nil
            callbackTarget = nil
            return (observer, target)
        }
        guard let state else { return }
        for notification in Self.observedNotifications {
            AXObserverRemoveNotification(state.observer, element, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(state.observer),
                              .defaultMode)
        // A callback may be mid-flight on the main run loop right now, still holding the
        // refcon. Callbacks and this block both run on the main loop, so releasing the box
        // there guarantees it happens strictly after any in-flight dispatch completes.
        let target = state.target
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            target.release()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    deinit { stop() }
}
