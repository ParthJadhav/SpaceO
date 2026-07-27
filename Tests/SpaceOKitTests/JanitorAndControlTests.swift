import XCTest
import CoreGraphics
import AppKit
import Darwin
@testable import SpaceOKit

/// Regressions for SPAO-127 (runtime janitor) and SPAO-134 (viewer control transitions).
///
/// Both tickets are about work that survives a state change it should not have survived: a
/// notification dropped during a sweep, an event delivered after Control was switched off. The
/// tests are deterministic — no timers, no WindowServer — because the failures they cover are
/// races, and a race reproduced by sleeping is a race not really covered.
final class JanitorAndControlTests: XCTestCase {

    // MARK: - SPAO-127: notification arriving during a sweep

    func testTheFirstCallerBecomesTheSweeper() {
        let coalescer = SweepCoalescer()
        XCTAssertTrue(coalescer.beginOrCoalesce())
        XCTAssertTrue(coalescer.isSweeping)
        XCTAssertFalse(coalescer.endOrRepeat())
        XCTAssertFalse(coalescer.isSweeping)
    }

    /// The exact dropped-notification bug: a request that lands while a sweep is running used to
    /// be discarded, so a window created a moment after the sweep started was in no sweep at all.
    func testANotificationDuringASweepIsHonouredNotDropped() {
        let coalescer = SweepCoalescer()
        XCTAssertTrue(coalescer.beginOrCoalesce())

        XCTAssertFalse(coalescer.beginOrCoalesce(),
                       "a second caller must not sweep concurrently")
        XCTAssertTrue(coalescer.endOrRepeat(),
                      "but its request must survive as a repeat")
        XCTAssertFalse(coalescer.endOrRepeat(),
                       "and the repeat clears it — one more sweep, not one per notification")
    }

    /// Coalescing, not queueing: a sweep is a full reconciliation, so N notifications during one
    /// sweep need exactly one more sweep.
    func testManyNotificationsDuringOneSweepCoalesceIntoOneRepeat() {
        let coalescer = SweepCoalescer()
        XCTAssertTrue(coalescer.beginOrCoalesce())
        for _ in 0..<50 { XCTAssertFalse(coalescer.beginOrCoalesce()) }
        XCTAssertTrue(coalescer.endOrRepeat())
        XCTAssertFalse(coalescer.endOrRepeat())
    }

    func testOwnershipIsHeldAcrossARepeatSoNoOneElseCanStartASweep() {
        let coalescer = SweepCoalescer()
        XCTAssertTrue(coalescer.beginOrCoalesce())
        XCTAssertFalse(coalescer.beginOrCoalesce())
        XCTAssertTrue(coalescer.endOrRepeat())
        // Mid-repeat: still owned, so a newcomer coalesces rather than sweeping in parallel.
        XCTAssertTrue(coalescer.isSweeping)
        XCTAssertFalse(coalescer.beginOrCoalesce())
    }

    func testCancelReleasesOwnershipWithoutPromisingAnotherSweep() {
        let coalescer = SweepCoalescer()
        XCTAssertTrue(coalescer.beginOrCoalesce())
        XCTAssertFalse(coalescer.beginOrCoalesce())
        coalescer.cancel()
        XCTAssertFalse(coalescer.isSweeping)
        XCTAssertFalse(coalescer.endOrRepeat(),
                       "shutdown must not leave a caller looping for a sweep that never comes")
    }

    func testConcurrentNotificationsNeverLoseTheLastRequest() {
        let coalescer = SweepCoalescer()
        let sweeps = NSCountedSet()
        let lock = NSLock()

        // One sweeper plus a storm of notifications; every notification must either be inside a
        // sweep that has not finished or cause another one.
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            guard coalescer.beginOrCoalesce() else { return }
            repeat {
                lock.withLock { sweeps.add("sweep") }
            } while coalescer.endOrRepeat()
        }
        XCTAssertFalse(coalescer.isSweeping)
        XCTAssertGreaterThan(sweeps.count(for: "sweep"), 0)
    }

    // MARK: - SPAO-127: containment must use full bounds

    func testAWindowInsideItsTileIsContained() {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 540)
        XCTAssertTrue(WindowPlacement.isFullyInside(
            CGRect(x: 10, y: 10, width: 400, height: 300), tile))
        XCTAssertTrue(WindowPlacement.isFullyInside(tile, tile),
                      "a window exactly filling its tile is contained")
    }

    /// The oversized-window case: midpoint containment called this handled while the window
    /// spilled across a neighbouring session's tile.
    func testAnOversizedWindowIsNotContainedEvenWithItsCentreInPlace() {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 540)
        let oversized = CGRect(x: -200, y: -100, width: 1400, height: 800)

        XCTAssertTrue(tile.contains(CGPoint(x: oversized.midX, y: oversized.midY)),
                      "its centre is in the tile — which is exactly why midpoint testing failed")
        XCTAssertFalse(WindowPlacement.isFullyInside(oversized, tile),
                       "but it crosses into the neighbour, so it is not contained")
    }

    /// The moved-after-placement case: a window we already placed drifts out later.
    func testAWindowThatDriftsOutAfterPlacementIsNoLongerContained() {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 540)
        let placed = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(WindowPlacement.isFullyInside(placed, tile))

        let drifted = placed.offsetBy(dx: 700, dy: 0)
        XCTAssertFalse(WindowPlacement.isFullyInside(drifted, tile),
                       "handled means we acted, not that it is still where we put it")
    }

    func testAWindowJustOverTheEdgeIsNotContained() {
        let tile = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(WindowPlacement.isFullyInside(
            CGRect(x: 100, y: 100, width: 800, height: 600), tile))
        for escape in [CGRect(x: 99, y: 100, width: 800, height: 600),
                       CGRect(x: 100, y: 99, width: 800, height: 600),
                       CGRect(x: 100, y: 100, width: 801, height: 600),
                       CGRect(x: 100, y: 100, width: 800, height: 601)] {
            XCTAssertFalse(WindowPlacement.isFullyInside(escape, tile),
                           "\(escape) escapes \(tile) by a pixel and must be caught")
        }
    }

    func testDegenerateGeometryIsNeverReportedAsContained() {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 540)
        XCTAssertFalse(WindowPlacement.isFullyInside(.infinite, tile))
        XCTAssertFalse(WindowPlacement.isFullyInside(.null, tile))
        XCTAssertFalse(WindowPlacement.isFullyInside(
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), tile))
        XCTAssertFalse(WindowPlacement.isFullyInside(
            CGRect(x: 0, y: 0, width: 10, height: 10), .zero),
            "a degenerate tile contains nothing")
    }

    func testThePeriodicSweepIntervalIsShortEnoughToMatter() {
        XCTAssertLessThanOrEqual(WindowWatcher.periodicSweepInterval, 5.0,
                                 "a stray dialog on the user's screen must be a blink, not a fixture")
        XCTAssertGreaterThan(WindowWatcher.periodicSweepInterval, 0)
    }

    // MARK: - SPAO-134: control epochs

    func testADisabledGateAdmitsNothing() {
        let gate = InputControlGate()
        XCTAssertNil(gate.admit(), "Control off means no event is admitted at all")
        XCTAssertFalse(gate.isEnabled)
    }

    func testAnAdmittedEventIsDeliverableWhileNothingChanges() throws {
        let gate = InputControlGate()
        gate.enable(displayID: 7)
        let ticket = try XCTUnwrap(gate.admit())
        XCTAssertTrue(gate.isCurrent(ticket))
        XCTAssertEqual(ticket.displayID, 7)
    }

    /// The core failure: an event validated at enqueue, delivered after Control was switched off.
    func testAQueuedEventIsDiscardedAfterControlIsDisabled() throws {
        let gate = InputControlGate()
        gate.enable(displayID: 7)
        let queued = try XCTUnwrap(gate.admit())

        gate.disable()
        XCTAssertFalse(gate.isCurrent(queued),
                       "a click must not execute after the user took control back")
        XCTAssertNil(gate.admit())
    }

    /// The other half: an event admitted for one display, delivered after the user selected
    /// another. The display id alone cannot catch a switch away and back.
    func testAQueuedEventIsDiscardedAfterTheDisplaySwitches() throws {
        let gate = InputControlGate()
        gate.enable(displayID: 7)
        let queued = try XCTUnwrap(gate.admit())

        gate.select(displayID: 9)
        XCTAssertFalse(gate.isCurrent(queued),
                       "an event bound for display 7 must not land on display 9")
    }

    func testSwitchingAwayAndBackDoesNotResurrectQueuedEvents() throws {
        let gate = InputControlGate()
        gate.enable(displayID: 7)
        let queued = try XCTUnwrap(gate.admit())

        gate.select(displayID: 9)
        gate.enable(displayID: 7)
        XCTAssertFalse(gate.isCurrent(queued),
                       "the display matches again, but the epoch says this event is from before "
                       + "a transition, which is what makes epochs necessary")
    }

    func testReEnablingTheSameDisplayStillInvalidatesOlderEvents() throws {
        let gate = InputControlGate()
        gate.enable(displayID: 7)
        let queued = try XCTUnwrap(gate.admit())
        gate.disable()
        gate.enable(displayID: 7)
        XCTAssertFalse(gate.isCurrent(queued))
        XCTAssertTrue(gate.isCurrent(try XCTUnwrap(gate.admit())))
    }

    func testSelectingNoDisplayTurnsControlOff() {
        let gate = InputControlGate()
        gate.enable(displayID: 7)
        gate.select(displayID: nil)
        XCTAssertFalse(gate.isEnabled, "there is nothing to drive, so nothing may be driven")
        XCTAssertNil(gate.admit())
    }

    func testEpochAdvancesOnEveryTransitionSoNoEventCanStraddleOne() {
        let gate = InputControlGate()
        var seen: Set<UInt64> = [gate.currentEpoch]
        for step in 0..<10 {
            if step.isMultiple(of: 2) { gate.enable(displayID: 1) } else { gate.disable() }
            XCTAssertFalse(seen.contains(gate.currentEpoch),
                           "every transition must produce a fresh epoch")
            seen.insert(gate.currentEpoch)
        }
    }

    /// A whole burst of events admitted before a disable must all be discarded, not just the
    /// last one — the backlog is exactly what used to execute after Control went off.
    func testAnEntireQueuedBurstIsInvalidatedByOneDisable() {
        let gate = InputControlGate()
        gate.enable(displayID: 3)
        let burst = (0..<64).compactMap { _ in gate.admit() }
        XCTAssertEqual(burst.count, 64)
        XCTAssertTrue(burst.allSatisfy { gate.isCurrent($0) })

        gate.disable()
        XCTAssertTrue(burst.allSatisfy { !gate.isCurrent($0) })
    }

    func testDisableIsSafeUnderConcurrentAdmission() {
        let gate = InputControlGate()
        gate.enable(displayID: 5)
        let survivors = NSCountedSet()
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 128) { index in
            if index == 64 {
                gate.disable()
                return
            }
            guard let ticket = gate.admit() else { return }
            // Delivery-time recheck, exactly as the input queue does it.
            if gate.isCurrent(ticket) {
                lock.withLock { survivors.add("delivered") }
            }
        }
        // No assertion on the count — the point is that the gate stays coherent under the race
        // and ends up disabled, refusing everything afterwards.
        XCTAssertFalse(gate.isEnabled)
        XCTAssertNil(gate.admit())
    }

    // MARK: - SPAO-134: the viewer must not target itself

    func testSelfExclusionCoversThisProcess() {
        XCTAssertTrue(MirrorInput.selfExcludedPIDs.contains(getpid()))
    }

    /// Viewing a physical display that contains the viewer's own window used to let a click
    /// select that window and be posted back into this process, feeding itself forever.
    func testHitTestingSkipsOurOwnWindowsAndPicksWhatIsBehind() {
        let ourWindow = MirrorInput.WindowCandidate(
            windowID: 1, pid: getpid(), layer: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            title: "SpaceO Viewer", appName: "SpaceOViewer")
        let realTarget = MirrorInput.WindowCandidate(
            windowID: 2, pid: getpid() + 1, layer: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            title: "TextEdit", appName: "TextEdit")

        let unfiltered = MirrorInput.selectTarget(from: [ourWindow, realTarget],
                                                  containing: CGPoint(x: 100, y: 100))
        XCTAssertEqual(unfiltered?.windowID, 1, "frontmost-first would pick us")

        let filtered = MirrorInput.selectTarget(from: [ourWindow, realTarget],
                                                containing: CGPoint(x: 100, y: 100),
                                                excluding: MirrorInput.selfExcludedPIDs)
        XCTAssertEqual(filtered?.windowID, 2, "self-exclusion must fall through to the app behind")
    }

    func testTheKeyboardFallbackAlsoSkipsOurOwnWindows() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ourWindow = MirrorInput.WindowCandidate(
            windowID: 1, pid: getpid(), layer: 0,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            title: "SpaceO Viewer", appName: "SpaceOViewer")
        let candidates = [ourWindow]

        XCTAssertNil(MirrorInput.selectTarget(from: candidates,
                                              containing: CGPoint(x: 200, y: 200),
                                              excluding: MirrorInput.selfExcludedPIDs),
                     "with only our own window present there is nothing legitimate to drive")
        XCTAssertTrue(display.contains(CGPoint(x: ourWindow.bounds.midX,
                                               y: ourWindow.bounds.midY)),
                      "and it is genuinely on the viewed display — exclusion is what saves us")
    }

    /// Defense in depth: even if a future caller forgets to filter, delivery itself refuses.
    func testDeliveryPrimitivesRefuseToPostToThisProcess() {
        let ourselves = WindowRef(windowID: 1, pid: getpid(), title: "self",
                                  frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertThrowsError(try MirrorInput.postPointer(.down, button: .left,
                                                          at: CGPoint(x: 10, y: 10),
                                                          to: ourselves)) { error in
            XCTAssertTrue(error.localizedDescription.contains("SpaceO itself"),
                          error.localizedDescription)
        }
        XCTAssertThrowsError(try MirrorInput.postScroll(dx: 0, dy: 10,
                                                        at: CGPoint(x: 10, y: 10),
                                                        to: ourselves))
        XCTAssertThrowsError(try MirrorInput.postKey(code: 0, flags: [], down: true,
                                                     characters: "a", to: getpid()))
    }
}
