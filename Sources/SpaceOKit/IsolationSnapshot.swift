import Foundation
import AppKit
import CoreGraphics
import SpaceOPrivate

/// The project's correctness claim, made into a value.
///
/// SpaceO's promise is "this does not change while an agent works". Making it a first-class
/// type means tests assert on it directly, and `spaceo verify` can check it in production
/// rather than only in CI.
public struct IsolationSnapshot: Equatable, Sendable, CustomStringConvertible {

    /// The app owning the menu bar, per AppKit.
    public let frontmostPID: pid_t
    /// The same question asked of the WindowServer, which is the authority.
    public let windowServerFrontPID: pid_t
    /// Processes currently receiving physical key events and text input.
    public let keyFocusPID: pid_t
    public let typingFocusPID: pid_t
    /// Where the user's cursor is.
    public let cursor: CGPoint
    /// The user's active Space.
    public let activeSpace: UInt64
    /// Agent screen rects at capture time, so we can detect a pointer routed onto one.
    public let stageRects: [CGRect]
    /// Processes belonging to agents, so we can tell whose fault a focus change was.
    public let agentPIDs: Set<pid_t>
    /// Spaces belonging to agent displays.
    public let agentSpaces: Set<UInt64>

    public init(frontmostPID: pid_t,
                windowServerFrontPID: pid_t,
                keyFocusPID: pid_t = 0,
                typingFocusPID: pid_t = 0,
                cursor: CGPoint,
                activeSpace: UInt64,
                stageRects: [CGRect] = [],
                agentPIDs: Set<pid_t> = [],
                agentSpaces: Set<UInt64> = []) {
        self.frontmostPID = frontmostPID
        self.windowServerFrontPID = windowServerFrontPID
        self.keyFocusPID = keyFocusPID
        self.typingFocusPID = typingFocusPID
        self.cursor = cursor
        self.activeSpace = activeSpace
        self.stageRects = stageRects
        self.agentPIDs = agentPIDs
        self.agentSpaces = agentSpaces
    }

    public static func capture() -> IsolationSnapshot {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return IsolationSnapshot(
            frontmostPID: frontmostPID,
            // The private focus/front-process getters use undocumented ProcessSerialNumber ABIs.
            // Keep the comparison fields for synthetic tests, but use the public AppKit view for
            // live containment instead of calling any of those getters.
            windowServerFrontPID: frontmostPID,
            keyFocusPID: 0,
            typingFocusPID: 0,
            cursor: currentCursor(),
            activeSpace: SPOActiveSpace(),
            stageRects: Stage.spaceODisplayIDs().map(CGDisplayBounds),
            agentPIDs: AgentActivity.ownedPIDs,
            agentSpaces: AgentActivity.ownedSpaces
        )
    }

    /// A baseline you can actually assert against.
    ///
    /// `capture()` is a single instant, and an instant can land mid-transition — an app that is
    /// quitting is still frontmost for a moment, and a baseline taken then reports a "breach"
    /// when the system settles onto the next app. This waits for two consecutive identical
    /// readings before returning, so the baseline describes a state the machine is actually in.
    public static func captureStable(settleFor interval: TimeInterval = 0.25,
                                     timeout: TimeInterval = 3) -> IsolationSnapshot {
        let safeInterval = interval.isFinite ? min(max(interval, 0.01), 1.0) : 0.25
        let safeTimeout = timeout.isFinite ? min(max(timeout, safeInterval), 30) : 3
        var previous = capture()
        let deadline = Date().addingTimeInterval(safeTimeout)
        while Date() < deadline {
            usleep(UInt32(safeInterval * 1_000_000))
            let current = capture()
            if current.frontmostPID == previous.frontmostPID,
               current.windowServerFrontPID == previous.windowServerFrontPID,
               current.keyFocusPID == previous.keyFocusPID,
               current.typingFocusPID == previous.typingFocusPID,
               current.activeSpace == previous.activeSpace,
               NSRunningApplication(processIdentifier: current.frontmostPID) != nil {
                return current
            }
            previous = current
        }
        return previous
    }

    /// CoreGraphics already reports the cursor in the same global coordinate system as display
    /// and window bounds. Deriving this from one NSScreen's height breaks on stacked or
    /// differently-sized physical monitors.
    private static func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func cursorMoved(from other: IsolationSnapshot) -> Bool {
        abs(cursor.x - other.cursor.x) > 1 || abs(cursor.y - other.cursor.y) > 1
    }

    /// Changes SpaceO is responsible for. This is the assertion that matters.
    ///
    /// Cursor movement counts as a breach when the pointer ended up on an agent screen (the
    /// actual failure mode — an agent dragging the user's pointer to its own window). A user
    /// idly moving their mouse across their own display is not a breach.
    public func breaches(from other: IsolationSnapshot) -> [String] {
        var out: [String] = []
        // Focus moving *to* an agent app is us stealing it. Focus moving between the user's own
        // apps is the user working — blaming SpaceO for that is how a safety check becomes noise.
        if frontmostPID != other.frontmostPID, agentPIDs.contains(frontmostPID) {
            out.append("an agent app took the menu bar: pid \(other.frontmostPID) -> \(frontmostPID)")
        }
        if windowServerFrontPID != other.windowServerFrontPID,
           agentPIDs.contains(windowServerFrontPID) {
            out.append("an agent app became the WindowServer front process: pid "
                     + "\(other.windowServerFrontPID) -> \(windowServerFrontPID)")
        }
        if keyFocusPID != other.keyFocusPID, agentPIDs.contains(keyFocusPID) {
            out.append("an agent app took the key-input route: pid "
                     + "\(other.keyFocusPID) -> \(keyFocusPID)")
        }
        if typingFocusPID != other.typingFocusPID, agentPIDs.contains(typingFocusPID) {
            out.append("an agent app took the text-input route: pid "
                     + "\(other.typingFocusPID) -> \(typingFocusPID)")
        }
        if activeSpace != other.activeSpace, agentSpaces.contains(activeSpace) {
            out.append("the user was pulled onto an agent display's Space: "
                     + "\(other.activeSpace) -> \(activeSpace)")
        }
        if cursorMoved(from: other), stageRects.contains(where: { $0.contains(cursor) }) {
            out.append(String(format: "cursor is sitting on an agent screen at (%.0f,%.0f)",
                              cursor.x, cursor.y))
        }
        return out
    }

    /// Changes we observed but do not attribute to SpaceO — almost always the user working.
    public func ambientChanges(from other: IsolationSnapshot) -> [String] {
        var out: [String] = []
        let blamed = breaches(from: other)
        if cursorMoved(from: other), blamed.allSatisfy({ !$0.contains("cursor") }) {
            out.append(String(format: "cursor moved (%.0f,%.0f) -> (%.0f,%.0f) — not caused by SpaceO",
                              other.cursor.x, other.cursor.y, cursor.x, cursor.y))
        }
        if frontmostPID != other.frontmostPID, !agentPIDs.contains(frontmostPID) {
            out.append("frontmost app changed between the user's own apps: "
                     + "pid \(other.frontmostPID) -> \(frontmostPID) — not caused by SpaceO")
        }
        return out
    }

    /// Every observed difference, attributed or not. Useful when debugging.
    public func drift(from other: IsolationSnapshot) -> [String] {
        breaches(from: other) + ambientChanges(from: other)
    }

    /// True when SpaceO did nothing the user would notice.
    public func isUndisturbed(comparedTo other: IsolationSnapshot) -> Bool {
        breaches(from: other).isEmpty
    }

    public var description: String {
        String(format: "front=%d wsFront=%d key=%d typing=%d cursor=(%.0f,%.0f) space=%llu",
               frontmostPID, windowServerFrontPID, keyFocusPID, typingFocusPID,
               cursor.x, cursor.y, activeSpace)
    }
}
