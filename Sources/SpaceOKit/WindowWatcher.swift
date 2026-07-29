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

    /// How often the safety-net sweep runs when no notification has arrived.
    ///
    /// Notifications remain the primary mechanism — this is the backstop for the case the whole
    /// ticket is about: a notification that never arrives, because registration silently failed,
    /// because the app suppressed it, or because it landed in a window the observer does not
    /// cover. Two seconds is short enough that a stray dialog is a blink rather than a fixture,
    /// and long enough that the WindowServer round trip is not a background CPU cost.
    public static let periodicSweepInterval: TimeInterval = 2.0

    private let pid: pid_t
    private let region: () -> CGRect
    private let onPlaced: Placement?
    private var observer: AXObserver?
    private var callbackTarget: Unmanaged<CallbackTarget>?
    private let element: AXUIElement
    private var timer: DispatchSourceTimer?

    /// Windows we have already dealt with, so a re-notification does not re-move a window the
    /// agent has since positioned deliberately.
    private var handled = Set<CGWindowID>()
    private var refused = Set<CGWindowID>()
    private let lock = NSLock()
    private let coalescer = SweepCoalescer()

    /// Notifications the observer refused to register, with the AX error. Empty is the healthy
    /// case; anything here means notification-driven containment is degraded for this app and
    /// only the periodic sweep is holding the line, which the session audit must say out loud.
    public private(set) var registrationFailures: [String] = []

    private var placedTotal = 0
    public var placedCount: Int { lock.withLock { placedTotal } }
    public var refusedCount: Int { lock.withLock { refused.count } }
    /// Completed sweeps. Lets a test prove the periodic sweep really runs without reaching into
    /// the WindowServer for evidence.
    private var sweepTotal = 0
    public var sweepCount: Int { lock.withLock { sweepTotal } }

    /// - Parameter region: read lazily, because a session's tile can move if the display
    ///   arrangement changes.
    /// - Parameter periodicSweep: set false only in tests that drive `sweep()` by hand.
    public init?(pid: pid_t,
                 region: @escaping () -> CGRect,
                 onPlaced: Placement? = nil,
                 periodicSweep: Bool = true) {
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
        var failures: [String] = []
        for notification in Self.observedNotifications {
            let result = AXObserverAddNotification(observer, element,
                                                   notification as CFString, context)
            // kAXErrorNotificationAlreadyRegistered is benign — the notification is live either
            // way, which is all this list is claiming.
            if result != .success && result != .notificationAlreadyRegistered {
                failures.append("\(notification) (AX error \(result.rawValue))")
            }
        }
        self.registrationFailures = failures
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)

        if periodicSweep { startPeriodicSweep() }
    }

    /// The backstop sweep. Bounded (one WindowServer enumeration per tick, coalesced against
    /// notification-driven sweeps) and cancellable, so `stop()` really does end all activity.
    private func startPeriodicSweep() {
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + Self.periodicSweepInterval,
                        repeating: Self.periodicSweepInterval,
                        leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.sweep() }
        timer = source
        source.resume()
    }

    /// Move any window of this app that is not already inside the region.
    ///
    /// Driven by the notification rather than a timer, but written as a full sweep because
    /// `kAXWindowCreated` does not reliably tell you *which* window appeared.
    public func sweep() {
        guard coalescer.beginOrCoalesce() else { return }
        repeat {
            sweepOnce()
            lock.withLock { sweepTotal += 1 }
        } while coalescer.endOrRepeat()
    }

    private func sweepOnce() {
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
            // Containment is re-derived from the WindowServer every sweep, for *every* window
            // including ones already marked handled. `handled` records that we acted, not that
            // the window is still where we put it — an app that repositions itself after
            // placement, or grows past its tile, must be caught rather than trusted.
            guard let contained = WindowPlacement.isFullyInRegion(window.windowID, target) else {
                continue  // the WindowServer forgot it mid-sweep; the next pass will drop it
            }
            if contained {
                lock.withLock {
                    handled.insert(window.windowID)
                    refused.remove(window.windowID)
                }
                continue
            }

            // Sheets and some dialogs refuse AXPosition. Try, and count the refusals rather
            // than pretending they were contained.
            let frame = WindowPlacement.defaultFrame(in: target)
            let fitted = CGRect(origin: frame.origin,
                                size: CGSize(width: min(frame.width, max(320, window.frame.width)),
                                             height: min(frame.height, max(240, window.frame.height))))
            // Accept only on full containment, and re-read the live bounds rather than trusting
            // the value `move` echoed back: an app is free to resize itself the instant it is
            // repositioned, and the echo would not show it.
            let placed = try? WindowPlacement.move(window, to: fitted)
            let landed = WindowPlacement.isFullyInRegion(window.windowID, target) ?? false
            if let placed, landed {
                lock.withLock {
                    handled.insert(window.windowID)
                    refused.remove(window.windowID)
                    placedTotal += 1
                }
                onPlaced?(WindowRef(windowID: window.windowID, pid: pid,
                                    title: window.title, frame: placed))
            } else {
                lock.withLock {
                    handled.remove(window.windowID)
                    refused.insert(window.windowID)
                }
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
        // The timer goes first, so no new sweep can start while the observer is being torn down.
        // Cancelling the coalescer releases any repeat loop that is mid-flight; without it a
        // final burst of notifications could keep the loop sweeping a dead app.
        let source = lock.withLock { () -> DispatchSourceTimer? in
            defer { timer = nil }
            return timer
        }
        source?.cancel()
        coalescer.cancel()

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
