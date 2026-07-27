import Foundation
import ApplicationServices
import CoreGraphics
import SpaceOPrivate

/// A window SpaceO knows about.
public struct WindowRef: Sendable, Equatable, Identifiable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let title: String
    public let frame: CGRect
    public var id: CGWindowID { windowID }

    public var isOffscreenPlaceholder: Bool { windowID == 0 }
}

/// Moves other apps' windows onto a stage — using accessibility, so no cursor moves and
/// no app is activated.
public enum WindowPlacement {

    /// Windows currently owned by `pid`, newest last.
    public static func windows(of pid: pid_t) -> [WindowRef] {
        let app = AX.application(pid)
        AX.setTimeout(app, seconds: 2.0)
        return AX.elements(app, kAXWindowsAttribute as String).compactMap { element in
            let wid = AX.windowID(element)
            guard wid != 0 else { return nil }
            var bounds = CGRect.zero
            let frame = SPOWindowBounds(wid, &bounds) ? bounds : (AX.frame(element) ?? .zero)
            return WindowRef(windowID: wid,
                             pid: pid,
                             title: AX.string(element, kAXTitleAttribute as String) ?? "",
                             frame: frame)
        }
    }

    /// The AX element for a specific window id, or nil if it has gone away.
    public static func element(for window: WindowRef) -> AXUIElement? {
        let app = AX.application(window.pid)
        AX.setTimeout(app, seconds: 2.0)
        return AX.elements(app, kAXWindowsAttribute as String).first { AX.windowID($0) == window.windowID }
    }

    /// Move and resize a window. Position is set twice: some apps clamp the first request to
    /// the display the window is currently on, and accept it once the size fits.
    @discardableResult
    public static func move(_ window: WindowRef, to frame: CGRect) throws -> CGRect {
        try validate(frame: frame)
        guard let element = element(for: window) else {
            throw SpaceOError.windowNotFound("window \(window.windowID) of pid \(window.pid)")
        }
        AX.setPoint(element, kAXPositionAttribute as String, frame.origin)
        AX.setSize(element, kAXSizeAttribute as String, frame.size)
        AX.setPoint(element, kAXPositionAttribute as String, frame.origin)

        // AX mutations are asynchronous. Reading WindowServer bounds immediately returns the
        // pre-move frame often enough to make a successful placement look like a refusal.
        // Wait briefly for the requested origin to publish; applications may still clamp size.
        let deadline = Date().addingTimeInterval(1.0)
        var lastBounds = CGRect.zero
        repeat {
            if SPOWindowBounds(window.windowID, &lastBounds) {
                let originSettled =
                    abs(lastBounds.origin.x - frame.origin.x) <= 2
                    && abs(lastBounds.origin.y - frame.origin.y) <= 2
                if originSettled { return lastBounds }
            } else if let axFrame = AX.frame(element) {
                lastBounds = axFrame
                let originSettled =
                    abs(axFrame.origin.x - frame.origin.x) <= 2
                    && abs(axFrame.origin.y - frame.origin.y) <= 2
                if originSettled { return axFrame }
            }
            usleep(20_000)
        } while Date() < deadline

        if lastBounds != .zero { return lastBounds }
        return AX.frame(element) ?? frame
    }

    /// A sensible default window frame inside a session's tile: inset, but never so inset
    /// that a small tile leaves no usable window.
    public static func defaultFrame(in region: CGRect) -> CGRect {
        let inset = min(40, min(region.width, region.height) * 0.04)
        return region.insetBy(dx: inset, dy: inset)
    }

    /// Relocate every window of `pid` into `region`. Returns the windows as placed.
    ///
    /// Windows are cascaded slightly so several windows from one app stay reachable, but the
    /// cascade is clamped to the region — a session must never spill into a neighbour's tile.
    @discardableResult
    public static func placeAll(of pid: pid_t, into region: CGRect) throws -> [WindowRef] {
        try validate(frame: region)
        let found = windows(of: pid)
        guard !found.isEmpty else {
            throw SpaceOError.windowNotFound("pid \(pid) has no accessibility windows")
        }
        var placed: [WindowRef] = []
        let base = defaultFrame(in: region)
        do {
            for (index, window) in found.enumerated() {
                let offset = CGFloat(index) * 28
                var target = base.offsetBy(dx: offset, dy: offset)
                if !region.contains(CGPoint(x: target.midX, y: target.midY)) { target = base }
                let actual = try move(window, to: target)
                guard region.contains(CGPoint(x: actual.midX, y: actual.midY)) else {
                    throw SpaceOError.unsupportedTarget(
                        "window \(window.windowID) refused to move into the session tile")
                }
                placed.append(WindowRef(windowID: window.windowID, pid: pid,
                                        title: window.title, frame: actual))
            }
        } catch {
            // The window that triggered the error may have moved asynchronously after its
            // verification read. Roll every original window back, not only those already
            // appended to `placed`.
            for original in found {
                _ = try? move(original, to: original.frame)
            }
            throw error
        }
        return placed
    }

    static func validate(frame: CGRect) throws {
        guard !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 1, frame.height >= 1 else {
            throw SpaceOError.badRequest("window region must be finite and positive")
        }
    }

    /// Wait for `pid` to produce at least one accessibility window.
    public static func waitForWindow(of pid: pid_t, timeout: TimeInterval = 12) async throws -> [WindowRef] {
        guard timeout.isFinite, (0.1...120).contains(timeout) else {
            throw SpaceOError.badRequest(
                "window timeout must be a finite value from 0.1 through 120 seconds")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = windows(of: pid)
            if !found.isEmpty { return found }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw SpaceOError.launchFailed("pid \(pid) produced no window within \(Int(timeout))s")
    }

    /// Is this window actually sitting inside `region` right now?
    ///
    /// Judged by the window's centre: an agent window slightly larger than its tile is still
    /// "in" that tile, and demanding full containment would make every audit noisy.
    public static func isInRegion(_ window: WindowRef, _ region: CGRect) -> Bool {
        var bounds = CGRect.zero
        guard SPOWindowBounds(window.windowID, &bounds) else { return false }
        return region.contains(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Space ids this window is associated with.
    public static func spaces(of window: WindowRef) -> [UInt64] {
        (SPOSpacesForWindow(window.windowID) ?? []).map { $0.uint64Value }
    }

    /// Authoritative live bounds from the WindowServer, or a refusal when it no longer knows
    /// the window. The one place the lookup-or-refuse decision lives, so every input path
    /// reports a vanished window the same way.
    public static func liveBounds(of windowID: CGWindowID) throws -> CGRect {
        var bounds = CGRect.zero
        guard SPOWindowBounds(windowID, &bounds) else {
            throw SpaceOError.windowNotFound("no bounds for window \(windowID)")
        }
        return bounds
    }
}
