import XCTest
import CoreGraphics
@testable import SpaceOKit
@testable import SpaceOMCP

/// The agent-facing pointer surface: which actions exist, what they refuse, and whether a
/// coordinate read off a screenshot is a coordinate a click accepts.
///
/// Pure logic only — nothing here touches the WindowServer.
final class PointerSurfaceTests: XCTestCase {

    // MARK: - Buttons and modifiers

    func testEveryMouseButtonMapsToItsOwnEventTypes() {
        // A middle click used to be unrepresentable, so an agent could not open a link in a new
        // tab or close one from a tab strip.
        XCTAssertEqual(MouseButton.middle.downType, .otherMouseDown)
        XCTAssertEqual(MouseButton.middle.upType, .otherMouseUp)
        XCTAssertEqual(MouseButton.middle.draggedType, .otherMouseDragged)
        XCTAssertEqual(MouseButton.middle.cgButton, .center)

        let downTypes = Set(MouseButton.allCases.map(\.downType))
        XCTAssertEqual(downTypes.count, MouseButton.allCases.count,
                       "two buttons sharing a down event would silently press the wrong one")
    }

    func testButtonParsingDefaultsToLeftAndRejectsUnknownNames() throws {
        XCTAssertEqual(try MouseButton.parse(nil), .left)
        XCTAssertEqual(try MouseButton.parse(""), .left)
        XCTAssertEqual(try MouseButton.parse("RIGHT"), .right)
        XCTAssertEqual(try MouseButton.parse("middle"), .middle)
        XCTAssertThrowsError(try MouseButton.parse("sideways"))
    }

    func testModifierParsingAcceptsAliasesAndRejectsUnknownNames() throws {
        XCTAssertEqual(try ModifierKeys.parse(nil), [])
        XCTAssertEqual(try ModifierKeys.parse([]), [])
        XCTAssertEqual(try ModifierKeys.parse(["cmd"]), .maskCommand)
        XCTAssertEqual(try ModifierKeys.parse(["command"]), .maskCommand)
        XCTAssertEqual(try ModifierKeys.parse(["opt"]), .maskAlternate)
        XCTAssertEqual(try ModifierKeys.parse(["shift", "ctrl"]),
                       [.maskShift, .maskControl])
        XCTAssertThrowsError(try ModifierKeys.parse(["hyper"]))
        XCTAssertThrowsError(
            try ModifierKeys.parse(["cmd", "shift", "alt", "ctrl", "fn", "cmd"]),
            "an unbounded modifier list is a free allocation from a caller-supplied array")
    }

    // MARK: - Coordinate space

    func testCaptureScaleIsOnePointPerPixelUnlessAsked() throws {
        // The default has to make an image pixel and a click coordinate the same number. While
        // window captures were hard-coded to 2x and tile captures to 1x, an agent reading a
        // coordinate off the default screenshot clicked at half the intended position, and no
        // field in the response let it discover the difference.
        XCTAssertEqual(Capture.defaultScale, 1)
        XCTAssertEqual(try Capture.validatedScale(nil), 1)
        XCTAssertEqual(try Capture.validatedScale(2), 2)
        XCTAssertThrowsError(try Capture.validatedScale(0))
        XCTAssertThrowsError(try Capture.validatedScale(5))
    }

    func testImageGeometryTellsTheAgentHowToConvertPixelsToClicks() {
        let oneToOne = ImageGeometry(
            origin: "window", scale: 1, pixelWidth: 800, pixelHeight: 600,
            pointWidth: 800, pointHeight: 600, originX: 100, originY: 40, windowID: 7)
        XCTAssertTrue(oneToOne.advice.contains("directly"),
                      "a 1x window capture needs no conversion and should say so")

        let retina = ImageGeometry(
            origin: "window", scale: 2, pixelWidth: 1_600, pixelHeight: 1_200,
            pointWidth: 800, pointHeight: 600, originX: 100, originY: 40, windowID: 7)
        XCTAssertTrue(retina.advice.contains("Divide"))
        XCTAssertTrue(retina.advice.contains("2"))

        // A tile capture is not window-relative, so its advice has to name the extra step
        // rather than implying the pixels are directly clickable.
        let tile = ImageGeometry(
            origin: "tile", scale: 1, pixelWidth: 1_440, pixelHeight: 900,
            pointWidth: 1_440, pointHeight: 900, originX: 1_920, originY: 0)
        XCTAssertTrue(tile.advice.contains("Subtract"))
        XCTAssertNil(tile.windowID)
    }

    func testImageGeometrySurvivesAWireRoundTrip() throws {
        let geometry = ImageGeometry(
            origin: "window", scale: 2, pixelWidth: 1_600, pixelHeight: 1_200,
            pointWidth: 800, pointHeight: 600, originX: 12, originY: 34, windowID: 99)
        var response = Response(ok: true)
        response.image = geometry

        let decoded = try Wire.decoder.decode(
            Response.self, from: Wire.encoder.encode(response))
        XCTAssertEqual(decoded.image, geometry,
                       "geometry that does not survive the socket cannot be acted on")
    }

    // MARK: - Point validation

    func testPointsOutsideTheWindowAreRefusedWithAScaleHint() {
        let window = WindowRef(windowID: 4, pid: 321, title: "t",
                               frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let bounds = CGRect(x: 100, y: 50, width: 400, height: 300)

        XCTAssertNoThrow(try InputRouter.globalPoint(
            CGPoint(x: 10, y: 20), in: window, bounds: bounds, what: "click"))

        // The out-of-bounds case is overwhelmingly a scale mistake, so the error says so rather
        // than leaving the agent to guess why a coordinate it just read was rejected.
        do {
            _ = try InputRouter.globalPoint(
                CGPoint(x: 780, y: 40), in: window, bounds: bounds, what: "click")
            XCTFail("a point beyond the window width must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("divide by 2"),
                          "unhelpful refusal: \(error)")
        }

        XCTAssertThrowsError(try InputRouter.globalPoint(
            CGPoint(x: Double.nan, y: 0), in: window, bounds: bounds, what: "click"))
    }

    func testGlobalPointTranslatesByTheWindowOrigin() throws {
        let window = WindowRef(windowID: 4, pid: 321, title: "t", frame: .zero)
        let point = try InputRouter.globalPoint(
            CGPoint(x: 10, y: 20),
            in: window,
            bounds: CGRect(x: 100, y: 50, width: 400, height: 300),
            what: "click")
        XCTAssertEqual(point, CGPoint(x: 110, y: 70))
    }

    // MARK: - MCP surface

    func testPointerToolsAreAdvertised() throws {
        let names = Set(MCPServer.toolSchemas.compactMap { $0["name"] as? String })
        // Without these an agent cannot reach below the fold, open a hover-only menu, or move a
        // slider — ordinary steps on ordinary UI, not edge cases.
        XCTAssertTrue(names.contains("spaceo_scroll"))
        XCTAssertTrue(names.contains("spaceo_move"))
        XCTAssertTrue(names.contains("spaceo_drag"))
    }

    func testElementClickRefusesPointerOnlyArguments() throws {
        // An element index performs an accessibility press, which has no button, count, or
        // modifier state. Accepting those and pressing anyway reported success for an action
        // that never happened: the agent believed it had opened a context menu.
        for arguments in [
            ["element": "3", "button": "right"] as [String: Any],
            ["element": "3", "count": 2],
            ["element": "3", "modifiers": ["shift"]],
        ] {
            XCTAssertThrowsError(
                try MCPServer.toolRequest(name: "spaceo_click", arguments: arguments),
                "pointer-only argument silently dropped: \(arguments)")
        }

        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_click", arguments: ["element": "3"]))
        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_click",
            arguments: ["x": 10, "y": 20, "button": "right", "modifiers": ["shift"]]))
    }

    func testScrollAndDragRequireTheArgumentsThatMakeThemMeaningful() throws {
        // An unpositioned scroll is a coin flip in any app with two scrollable regions.
        XCTAssertThrowsError(
            try MCPServer.toolRequest(name: "spaceo_scroll", arguments: ["dy": -600]))
        XCTAssertThrowsError(
            try MCPServer.toolRequest(name: "spaceo_scroll", arguments: ["x": 10, "y": 20]),
            "a scroll with no delta does nothing and should say so")
        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_scroll", arguments: ["x": 10, "y": 20, "dy": -600]))

        XCTAssertThrowsError(
            try MCPServer.toolRequest(name: "spaceo_drag", arguments: ["x": 1, "y": 2]))
        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_drag",
            arguments: ["x": 1, "y": 2, "to_x": 3, "to_y": 4]))
    }

    func testScreenshotRegionMustBeCompleteAndScaleBounded() throws {
        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_screenshot", arguments: ["x": 0, "y": 0, "width": 10]))
        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_screenshot",
            arguments: ["x": 0, "y": 0, "width": 10, "height": 10]))
        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_screenshot", arguments: ["scale": 9]))
        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_screenshot", arguments: ["scale": 2]))
    }

    func testEveryPointerCommandIsOwnerScopedSoMCPAttachesItsLease() throws {
        // The MCP client attaches the session's controller lease to owner-scoped mutations, and
        // leases are deliberately never returned in a session list — so a command missing from
        // this set is one an agent can never successfully call. It fails with "controller lease
        // is required" and has no way to obtain one. Found by driving the real MCP server after
        // scroll, move, and drag were added to the daemon but not to the client's list.
        for command in ["click", "scroll", "move", "drag", "type", "key"] {
            XCTAssertTrue(
                DaemonCommand.ownerScopedMutations.contains(command),
                "\(command) mutates a session but is not owner-scoped")
        }

        // Read-only commands must stay out, or an agent would need a lease just to look.
        for command in ["ax", "screenshot", "windows", "verify", "pool", "session.list"] {
            XCTAssertFalse(
                DaemonCommand.ownerScopedMutations.contains(command),
                "\(command) only reads and should not demand a lease")
        }
    }

    func testPointerToolsMapToTheirDaemonCommands() throws {
        let scroll = try MCPServer.toolRequest(
            name: "spaceo_scroll",
            arguments: ["x": 10, "y": 20, "dy": -600, "ticks": 3, "modifiers": ["shift"]])
        XCTAssertEqual(scroll.cmd, "scroll")
        XCTAssertEqual(scroll.dy, -600)
        XCTAssertEqual(scroll.ticks, 3)
        XCTAssertEqual(scroll.modifiers, ["shift"])

        let drag = try MCPServer.toolRequest(
            name: "spaceo_drag",
            arguments: ["x": 1, "y": 2, "to_x": 30, "to_y": 40, "button": "middle"])
        XCTAssertEqual(drag.cmd, "drag")
        XCTAssertEqual(drag.toX, 30)
        XCTAssertEqual(drag.toY, 40)
        XCTAssertEqual(drag.button, "middle")

        let move = try MCPServer.toolRequest(
            name: "spaceo_move", arguments: ["x": 5, "y": 6])
        XCTAssertEqual(move.cmd, "move")
        XCTAssertEqual(move.x, 5)
    }
}
