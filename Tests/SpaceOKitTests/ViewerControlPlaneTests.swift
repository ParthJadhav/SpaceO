import CoreGraphics
import XCTest
@testable import SpaceOKit
@testable import SpaceOViewer

/// The Viewer's own controls: the ones that used to lead somewhere the user could not come back
/// from, and the one that reported nothing at all.
@MainActor
final class ViewerControlPlaneTests: XCTestCase {

    // MARK: - Scope switching

    func testScopeSwitchingSurvivesSelectingADisplay() async throws {
        let display = DisplayEntry(
            id: 7,
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isSpaceO: true,
            isActive: true,
            name: "SpaceO Display")
        let session = try Self.sessionInfo(
            id: "agent-1",
            displayID: display.id,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))

        var response = Response(ok: true)
        response.sessions = [session]
        let model = ViewerModel(
            automaticRefresh: false,
            initialDisplays: [display],
            initialSelectedID: display.id,
            initialPermissions: PermissionState(screenRecording: true, accessibility: true),
            daemonTransport: { _ in response },
            accessibilityAnnouncement: { _ in })

        model.refreshControlPlane()
        try await waitUntil { !model.sessions.isEmpty }

        model.selectSession(session.id)
        XCTAssertTrue(model.canSwitchCanvasMode)

        // Selecting a display clears the session selection. Gating the scope control on a
        // *selected* session therefore disabled the only control that could switch back, and
        // the "pick the first session on this display" fallback became unreachable.
        model.selectDisplay(display.id)
        XCTAssertNil(model.selectedSession)
        XCTAssertTrue(model.canSwitchCanvasMode,
                      "the display hosts a session, so Session scope is still reachable")

        model.setCanvasMode(.session)
        XCTAssertEqual(model.selectedSession?.id, session.id)
    }

    func testScopeSwitchingIsUnavailableWithoutASessionToSwitchTo() {
        let model = ViewerModel(automaticRefresh: false, accessibilityAnnouncement: { _ in })
        XCTAssertFalse(model.canSwitchCanvasMode,
                       "with nothing selected there is no scope to switch between")
    }

    // MARK: - Screenshot feedback

    func testScreenshotOutcomesCarryAUserVisibleMessage() {
        let url = URL(fileURLWithPath: "/tmp/spaceo-test.png")
        let saved = ViewerScreenshotResult.saved(url)
        XCTAssertFalse(saved.isFailure)
        XCTAssertTrue(saved.message.contains(url.path),
                      "a saved screenshot has to name the file the user is looking for")

        let failed = ViewerScreenshotResult.failed("display is not shareable")
        XCTAssertTrue(failed.isFailure)
        XCTAssertTrue(failed.message.contains("display is not shareable"))
    }

    func testScreenshotResultIsDismissible() {
        let model = ViewerModel(automaticRefresh: false, accessibilityAnnouncement: { _ in })
        XCTAssertNil(model.screenshotResult,
                     "nothing to report before a screenshot is taken")
        model.clearScreenshotResult()
        XCTAssertNil(model.screenshotResult)
    }

    // MARK: - Helpers

    /// `SessionInfo` only has initialisers from live runtime objects, so build one through the
    /// wire format the Viewer actually receives.
    private static func sessionInfo(
        id: String,
        displayID: CGDirectDisplayID,
        frame: CGRect
    ) throws -> SessionInfo {
        let json = """
        {
          "id": "\(id)",
          "displayID": \(displayID),
          "x": \(frame.minX), "y": \(frame.minY),
          "width": \(frame.width), "height": \(frame.height),
          "tileIndex": 0, "tileCapacity": 1,
          "exclusiveDisplay": true,
          "spaces": [], "hasOwnSpace": true,
          "apps": [], "windows": [],
          "createdAt": "2026-07-30T00:00:00Z",
          "teardownPending": false,
          "runtimeAttached": true
        }
        """
        return try Wire.decoder.decode(SessionInfo.self, from: Data(json.utf8))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition was not met within \(timeout)s")
    }
}
