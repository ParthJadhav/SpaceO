import AppKit
import XCTest
@testable import SpaceOKit
@testable import SpaceOViewer

/// Keyboard and VoiceOver regressions for SPAO-123.
///
/// These exercise the policy and the actual surface event seam. They do not post synthetic input
/// to another process, so a failure cannot escape the test runner.
@MainActor
final class ViewerAccessibilityTests: XCTestCase {

    func testLocalExitRemainsConsumedThroughKeyUpAfterControlDisables() throws {
        let view = VMSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        view.interactionEnabled = true
        var exitCount = 0
        var forwarded: [(down: Bool, keyCode: UInt16)] = []
        view.onExitControl = {
            exitCount += 1
            view.interactionEnabled = false
        }
        view.onKey = { down, keyCode, _, _ in
            forwarded.append((down, keyCode))
        }

        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command]
        ), down: true))
        XCTAssertFalse(view.interactionEnabled,
                       "the real exit callback disables Control during key-down")
        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command]
        ), down: true), "an exact repeat remains part of the local exit sequence")
        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyUp,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: []
        ), down: false))

        XCTAssertEqual(exitCount, 1, "only key-down performs the local exit")
        XCTAssertTrue(forwarded.isEmpty,
                      "neither half of the reserved chord may reach the remote input path")
    }

    func testOrdinaryEscapeRecoversFromALostLocalExitKeyUp() throws {
        let view = VMSurfaceView(frame: .zero)
        view.interactionEnabled = true
        var forwarded: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)] = []
        view.onExitControl = { view.interactionEnabled = false }
        view.onKey = { _, keyCode, modifiers, _ in
            forwarded.append((keyCode, modifiers))
        }

        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command]
        ), down: true))
        // Simulate focus loss swallowing the matching key-up, followed by a later Control session.
        view.interactionEnabled = true

        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: []
        ), down: true))
        XCTAssertEqual(forwarded.count, 1,
                       "a fresh ordinary Escape must clear stale exit tracking and forward")
        XCTAssertEqual(forwarded.first?.keyCode, ViewerControlPolicy.localExitKeyCode)
        XCTAssertTrue(forwarded.first?.modifiers.isEmpty == true)
    }

    func testExactLocalExitStartsANewSequenceAfterReenablingControl() throws {
        let view = VMSurfaceView(frame: .zero)
        view.interactionEnabled = true
        var exitCount = 0
        view.onExitControl = {
            exitCount += 1
            view.interactionEnabled = false
        }
        view.onKey = { _, _, _, _ in XCTFail("the local exit was forwarded") }

        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command]
        ), down: true))
        XCTAssertEqual(exitCount, 1)

        // Lose key-up, then begin a genuinely new Control session.
        view.interactionEnabled = true
        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command]
        ), down: true))
        XCTAssertEqual(exitCount, 2,
                       "re-enabling Control must end stale exit-key tracking")
        XCTAssertFalse(view.interactionEnabled)
    }

    func testNearMissesStillReachTheRemoteInputPath() throws {
        let view = VMSurfaceView(frame: .zero)
        view.interactionEnabled = true
        var forwarded: [UInt16] = []
        view.onKey = { _, keyCode, _, _ in forwarded.append(keyCode) }

        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: []
        ), down: true))
        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.command]
        ), down: true))
        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command, .option]
        ), down: true))
        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: 0,
            modifiers: [.control, .command]
        ), down: true))

        XCTAssertEqual(forwarded, [ViewerControlPolicy.localExitKeyCode,
                                   ViewerControlPolicy.localExitKeyCode,
                                   ViewerControlPolicy.localExitKeyCode, 0],
                       "ordinary Escape and near misses must still reach the remote display")
    }

    func testCapsLockDoesNotMakeTheExitChordUndiscoverable() throws {
        let view = VMSurfaceView(frame: .zero)
        view.interactionEnabled = true
        var exited = false
        view.onExitControl = { exited = true }
        view.onKey = { _, _, _, _ in XCTFail("the local exit was forwarded") }

        XCTAssertTrue(view.handleKeyEvent(try keyEvent(
            type: .keyDown,
            keyCode: ViewerControlPolicy.localExitKeyCode,
            modifiers: [.control, .command, .capsLock]
        ), down: true))
        XCTAssertTrue(exited)
    }

    func testSurfaceExposesRemoteDisplayRoleAndControlState() {
        let view = VMSurfaceView(frame: .zero)
        view.displayName = "Stage — Studio"
        view.streamRunning = true
        view.interactionEnabled = true

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.accessibilityLabel(), "Remote display, Stage — Studio")
        XCTAssertEqual(view.accessibilityValue() as? String,
                       "Live stream. Control enabled.")
        XCTAssertEqual(
            view.accessibilityHelp(),
            "Keyboard and pointer input go to the remote display. Press "
                + "Control-Command-Escape to exit Control."
        )

        view.interactionEnabled = false
        view.streamRunning = false
        XCTAssertEqual(view.accessibilityValue() as? String,
                       "Stream unavailable. Viewing only.")
        XCTAssertEqual(
            view.accessibilityHelp(),
            "The remote display stream is unavailable. Control cannot be enabled until "
                + "the stream is live."
        )
    }

    func testControlAdmissionExplainsEveryBlockedPermissionStateInWords() {
        XCTAssertEqual(
            ViewerControlPolicy.controlRequest(
                enabling: true,
                hasSelectedDisplay: false,
                streamRunning: true,
                screenRecordingGranted: true,
                accessibilityGranted: true
            ),
            .blocked("Control unavailable. Select a display first.")
        )

        let noStream = ViewerControlPolicy.controlRequest(
            enabling: true,
            hasSelectedDisplay: true,
            streamRunning: false,
            screenRecordingGranted: true,
            accessibilityGranted: true
        )
        let noCapture = ViewerControlPolicy.controlRequest(
            enabling: true,
            hasSelectedDisplay: true,
            streamRunning: true,
            screenRecordingGranted: false,
            accessibilityGranted: true
        )
        let noAccessibility = ViewerControlPolicy.controlRequest(
            enabling: true,
            hasSelectedDisplay: true,
            streamRunning: true,
            screenRecordingGranted: true,
            accessibilityGranted: false
        )
        guard case let .blocked(streamMessage) = noStream,
              case let .blocked(captureMessage) = noCapture,
              case let .blocked(accessibilityMessage) = noAccessibility else {
            return XCTFail("a missing stream or permission must block Control")
        }
        XCTAssertTrue(streamMessage.contains("live stream"))
        XCTAssertTrue(captureMessage.contains("Screen Recording permission"))
        XCTAssertTrue(accessibilityMessage.contains("Accessibility permission"))
    }

    func testModelRequiresLiveStreamAndDisablesControlWhenItStops() {
        let display = DisplayEntry(
            id: 7,
            bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            isSpaceO: true,
            isActive: true,
            name: "Stage — Test"
        )
        var blockedAnnouncements: [String] = []
        let blocked = ViewerModel(
            automaticRefresh: false,
            initialDisplays: [display],
            initialSelectedID: display.id,
            initialPermissions: PermissionState(
                screenRecording: true,
                accessibility: true
            ),
            initialStreamRunning: false,
            accessibilityAnnouncement: { blockedAnnouncements.append($0) }
        )

        blocked.setInteractionEnabled(true)
        XCTAssertFalse(blocked.interactionEnabled)
        XCTAssertTrue(blocked.note?.isWarning == true)
        XCTAssertTrue(blocked.note?.text.contains("live stream") == true)
        XCTAssertTrue(blockedAnnouncements.last?.contains("live stream") == true)

        var liveAnnouncements: [String] = []
        let live = ViewerModel(
            automaticRefresh: false,
            initialDisplays: [display],
            initialSelectedID: display.id,
            initialPermissions: PermissionState(
                screenRecording: true,
                accessibility: true
            ),
            initialStreamRunning: true,
            accessibilityAnnouncement: { liveAnnouncements.append($0) }
        )
        live.setInteractionEnabled(true)
        XCTAssertTrue(live.interactionEnabled)
        XCTAssertTrue(live.input.interactionEnabled)

        live.handleUnexpectedStreamStop(TestStreamError())

        XCTAssertFalse(live.streamRunning)
        XCTAssertFalse(live.interactionEnabled)
        XCTAssertFalse(live.input.interactionEnabled)
        XCTAssertTrue(live.note?.isWarning == true)
        XCTAssertTrue(live.note?.text.contains("Control disabled") == true)
        XCTAssertTrue(live.note?.text.contains("capture connection lost") == true)
        XCTAssertTrue(liveAnnouncements.last?.contains("Control disabled") == true)

        var failureAnnouncements: [String] = []
        let failed = ViewerModel(
            automaticRefresh: false,
            initialDisplays: [display],
            initialSelectedID: display.id,
            initialPermissions: PermissionState(
                screenRecording: true,
                accessibility: true
            ),
            initialStreamRunning: false,
            accessibilityAnnouncement: { failureAnnouncements.append($0) }
        )
        failed.handleStreamStartFailure(TestStreamError())
        XCTAssertFalse(failed.interactionEnabled)
        XCTAssertTrue(failed.note?.isWarning == true)
        XCTAssertTrue(failed.note?.text.contains("failed to start") == true)
        XCTAssertTrue(failureAnnouncements.last?.contains("Control unavailable") == true)
    }

    func testDisablingControlReleasesEveryDeliveredRemoteKey() {
        let target = SpaceOKit.WindowRef(
            windowID: 41,
            pid: getpid() + 1,
            title: "Target",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let display = inputTestDisplay(id: 7)
        let delivered = expectation(description: "remote key-downs delivered")
        delivered.expectedFulfillmentCount = 2
        let recorder = PostedKeyRecorder(onDown: { delivered.fulfill() })
        let controller = ViewerInputController(
            keyPoster: recorder.record,
            frontWindowProvider: { _ in target }
        )
        controller.display = display
        controller.interactionEnabled = true

        controller.key(down: true, keyCode: 0, modifiers: [], characters: "a")
        controller.key(down: true, keyCode: 11, modifiers: [], characters: "b")
        wait(for: [delivered], timeout: 1)
        controller.interactionEnabled = false

        XCTAssertEqual(recorder.events.count, 4)
        for keyCode: UInt16 in [0, 11] {
            let events = recorder.events.filter { $0.keyCode == keyCode }
            XCTAssertEqual(events.map(\.down), [true, false],
                           "each delivered down needs one matching up")
            XCTAssertTrue(events.allSatisfy { $0.pid == target.pid })
        }
    }

    func testDisplayTransitionReleasesDeliveredRemoteKeyBeforeClearingTarget() {
        let target = SpaceOKit.WindowRef(
            windowID: 42,
            pid: getpid() + 2,
            title: "Target",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let delivered = expectation(description: "remote key-down delivered")
        let recorder = PostedKeyRecorder(onDown: { delivered.fulfill() })
        let controller = ViewerInputController(
            keyPoster: recorder.record,
            frontWindowProvider: { _ in target }
        )
        controller.display = inputTestDisplay(id: 7)
        controller.interactionEnabled = true
        controller.key(down: true, keyCode: 0,
                       modifiers: NSEvent.ModifierFlags.command, characters: "a")
        wait(for: [delivered], timeout: 1)

        controller.display = inputTestDisplay(id: 8)

        XCTAssertEqual(recorder.events.map(\.down), [true, false])
        XCTAssertEqual(recorder.events.map(\.pid), [target.pid, target.pid])
        XCTAssertFalse(controller.interactionEnabled)
    }

    func testEntryAndExitAnnouncementsIncludeStateAndEscapeRoute() {
        let entered = ViewerAccessibility.controlAnnouncement(
            enabled: true,
            displayName: "Stage — Studio"
        )
        XCTAssertTrue(entered.contains("Control enabled"))
        XCTAssertTrue(entered.contains("Stage — Studio"))
        XCTAssertTrue(entered.contains(ViewerControlPolicy.localExitDescription))

        let exited = ViewerAccessibility.controlAnnouncement(
            enabled: false,
            displayName: "Stage — Studio"
        )
        XCTAssertTrue(exited.contains("Control disabled"))
        XCTAssertTrue(exited.contains("stay on this Mac"))
    }

    private func keyEvent(type: NSEvent.EventType,
                          keyCode: UInt16,
                          modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func inputTestDisplay(id: CGDirectDisplayID) -> DisplayEntry {
        DisplayEntry(
            id: id,
            bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            isSpaceO: true,
            isActive: true,
            name: "Stage \(id)"
        )
    }
}

private struct TestStreamError: LocalizedError {
    var errorDescription: String? { "capture connection lost" }
}

private struct PostedKey {
    let keyCode: UInt16
    let down: Bool
    let pid: pid_t
}

private final class PostedKeyRecorder {
    private let lock = NSLock()
    private var stored: [PostedKey] = []
    private let onDown: () -> Void

    init(onDown: @escaping () -> Void) {
        self.onDown = onDown
    }

    var events: [PostedKey] {
        lock.withLock { stored }
    }

    func record(_ code: CGKeyCode, _ flags: CGEventFlags, _ down: Bool,
                _ characters: String?, _ pid: pid_t) throws {
        lock.withLock {
            stored.append(PostedKey(keyCode: UInt16(code), down: down, pid: pid))
        }
        if down { onDown() }
    }
}
