import XCTest
import CoreGraphics
import AppKit
import Darwin
import SpaceOPrivate
@testable import SpaceOKit
@testable import SpaceOMCP

/// Pure-logic tests. No WindowServer state, no permissions, must pass anywhere.
final class UnitTests: XCTestCase {

    func testDisplayRetirementRequiresRemovalFromTheOnlineInventory() {
        XCTAssertFalse(Stage.displayIsRetired(291, onlineDisplayIDs: [1, 4, 291]),
                       "an inactive-but-online virtual display is still attached")
        XCTAssertTrue(Stage.displayIsRetired(291, onlineDisplayIDs: [1, 4]))
        XCTAssertTrue(Stage.displayIsRetired(0, onlineDisplayIDs: [1, 4]))
    }

    // MARK: - Key parsing

    func testKeyComboParsesPlainKeys() throws {
        XCTAssertEqual(try KeyCombo.parse("a").keyCode, 0)
        XCTAssertEqual(try KeyCombo.parse("return").keyCode, 36)
        XCTAssertEqual(try KeyCombo.parse("esc").keyCode, 53)
        XCTAssertTrue(try KeyCombo.parse("a").flags.isEmpty)
    }

    func testKeyComboParsesModifiers() throws {
        let combo = try KeyCombo.parse("cmd+shift+s")
        XCTAssertEqual(combo.keyCode, 1)
        XCTAssertTrue(combo.flags.contains(.maskCommand))
        XCTAssertTrue(combo.flags.contains(.maskShift))
        XCTAssertFalse(combo.flags.contains(.maskAlternate))
    }

    func testKeyComboRejectsGarbage() {
        XCTAssertThrowsError(try KeyCombo.parse("hyper+s"))
        XCTAssertThrowsError(try KeyCombo.parse("cmd+notakey"))
        XCTAssertThrowsError(try KeyCombo.parse(""))
        XCTAssertThrowsError(
            try KeyCombo.parse("a" + String(repeating: "\u{0301}", count: 128)),
            "one pathological grapheme must not bypass the byte limit")
    }

    func testFunctionKeys() throws {
        XCTAssertEqual(try KeyCombo.parse("f1").keyCode, 122)
        XCTAssertEqual(try KeyCombo.parse("f12").keyCode, 111)
    }

    func testTypingDurationIsBoundedBeforeInputRoutingChanges() {
        XCTAssertNoThrow(try InputRouter.validateTyping("ordinary text"))
        XCTAssertThrowsError(
            try InputRouter.validateTyping(
                String(repeating: "\n", count: 8_000)))
        XCTAssertThrowsError(
            try InputRouter.validateTyping(
                String(repeating: "x", count: 200),
                charactersPerSecond: 1))
    }

    /// Windows line endings are one line break. Sending two Returns for "\r\n" doubles every
    /// blank line an agent types into a form or an editor.
    func testTypingEstimateCollapsesCRLFToOneReturn() {
        XCTAssertEqual(
            InputRouter.estimatedTypingSeconds("a\r\nb", charactersPerSecond: 90),
            InputRouter.estimatedTypingSeconds("a\nb", charactersPerSecond: 90))
        XCTAssertEqual(
            InputRouter.estimatedTypingSeconds("\r\r\n\n", charactersPerSecond: 90),
            3 * 0.045,
            accuracy: 0.0001,
            "\\r + \\r\\n + \\n is three line breaks, not four")
    }

    // MARK: - Isolation snapshot

    func testSnapshotDriftDetectsFrontmostChange() {
        let a = IsolationSnapshot(frontmostPID: 100, windowServerFrontPID: 100,
                                  cursor: .zero, activeSpace: 1, agentPIDs: [200])
        let b = IsolationSnapshot(frontmostPID: 200, windowServerFrontPID: 100,
                                  cursor: .zero, activeSpace: 1, agentPIDs: [200])
        XCTAssertFalse(b.isUndisturbed(comparedTo: a))
        XCTAssertTrue(b.drift(from: a).contains { $0.contains("took the menu bar") })
    }

    func testSnapshotDriftDetectsSpaceSwitch() {
        let a = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1, cursor: .zero,
                                  activeSpace: 1, agentSpaces: [7])
        let b = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1, cursor: .zero,
                                  activeSpace: 7, agentSpaces: [7])
        XCTAssertTrue(b.drift(from: a).contains { $0.contains("pulled onto an agent") })
    }

    func testSnapshotDetectsAgentInputRouteTheft() {
        let before = IsolationSnapshot(
            frontmostPID: 10, windowServerFrontPID: 10,
            keyFocusPID: 10, typingFocusPID: 10,
            cursor: .zero, activeSpace: 1, agentPIDs: [777])
        let after = IsolationSnapshot(
            frontmostPID: 10, windowServerFrontPID: 10,
            keyFocusPID: 777, typingFocusPID: 777,
            cursor: .zero, activeSpace: 1, agentPIDs: [777])

        XCTAssertFalse(after.isUndisturbed(comparedTo: before))
        XCTAssertTrue(after.breaches(from: before).contains { $0.contains("key-input") })
        XCTAssertTrue(after.breaches(from: before).contains { $0.contains("text-input") })
    }

    func testSnapshotToleratesSubPixelCursorNoise() {
        let a = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                  cursor: CGPoint(x: 100, y: 100), activeSpace: 1)
        let b = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                  cursor: CGPoint(x: 100.4, y: 100.4), activeSpace: 1)
        XCTAssertTrue(b.isUndisturbed(comparedTo: a), "sub-pixel jitter is not a disturbance")
    }

    /// Bare cursor movement, with no agent screen involved and no warp by us, is the user —
    /// see the blame-attribution tests below. It must show up as observable drift but not as
    /// a breach.
    func testSnapshotReportsCursorMovementAsDriftButNotBreach() {
        let a = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                  cursor: CGPoint(x: 100, y: 100), activeSpace: 1)
        let b = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                  cursor: CGPoint(x: 400, y: 100), activeSpace: 1)
        XCTAssertTrue(b.isUndisturbed(comparedTo: a))
        XCTAssertFalse(b.drift(from: a).isEmpty, "the movement should still be visible in drift")
    }

    func testChromiumDetectionCoversCommonBundles() {
        XCTAssertTrue(InputRouter.chromiumLike.contains { "com.google.Chrome".hasPrefix($0) })
        XCTAssertTrue(InputRouter.chromiumLike.contains { "com.brave.Browser".hasPrefix($0) })
    }

    // MARK: - Errors

    func testErrorsCarryRemedies() {
        XCTAssertTrue(SpaceOError.accessibilityDenied.description.contains("System Settings"))
        XCTAssertTrue(SpaceOError.screenRecordingDenied.description.contains("System Settings"))
        XCTAssertTrue(SpaceOError.unavailable(capability: "x").description.contains("spaceo doctor"))
    }

    func testFocusCapabilityMatchesRuntimeSymbolInventory() {
        let missing = Set(SPOMissingSymbols())
        let available = Capabilities().items.first {
            $0.name == "focus-without-raise"
        }?.available
        XCTAssertEqual(available, !missing.contains("SLPSPostEventRecordTo"))
    }

    func testVirtualDisplayCapabilityMatchesRuntimeClassInventory() {
        let classes = [
            "CGVirtualDisplay",
            "CGVirtualDisplayDescriptor",
            "CGVirtualDisplayMode",
            "CGVirtualDisplaySettings",
        ]
        let expected = classes.allSatisfy { NSClassFromString($0) != nil }
        let available = Capabilities().items.first {
            $0.name == "virtual-display"
        }?.available
        XCTAssertEqual(available, expected)
    }

    // MARK: - Pasteboard guard

    func testPasteboardGuardRestoresPriorContents() {
        let pasteboard = NSPasteboard(name: .init("spaceo.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let sentinel = "user-copied-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)

        PasteboardGuard.preserving(pasteboard: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("agent scribble", forType: .string)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), sentinel)
    }

    func testPasteboardGuardHandlesEmptyClipboard() {
        let pasteboard = NSPasteboard(name: .init("spaceo.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let snapshot = PasteboardGuard.snapshot(from: pasteboard)
        pasteboard.setString("agent", forType: .string)
        PasteboardGuard.restore(snapshot, to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    // MARK: - Capture heuristics

    func testVisualEntropyIsZeroForFlatImage() throws {
        let image = try makeImage(width: 64, height: 64) { context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertLessThan(Capture.visualEntropy(image), 0.02)
        XCTAssertFalse(Capture.looksRendered(image), "a flat surface must not read as rendered UI")
    }

    func testVisualEntropyIsHighForVariedImage() throws {
        let image = try makeImage(width: 64, height: 64) { context in
            for i in 0..<64 {
                context.setFillColor(CGColor(gray: Double(i) / 64.0, alpha: 1))
                context.fill(CGRect(x: i, y: 0, width: 1, height: 64))
            }
        }
        XCTAssertGreaterThan(Capture.visualEntropy(image), 0.02)
        XCTAssertTrue(Capture.looksRendered(image))
    }

    func testCaptureDimensionsRejectInvalidGeometryWithoutProductCaps() throws {
        let ordinary = try Capture.validatedDimensions(width: 1_920, height: 1_080, scale: 2)
        XCTAssertEqual(ordinary.width, 3_840)
        XCTAssertEqual(ordinary.height, 2_160)
        let large = try Capture.validatedDimensions(width: 16_384, height: 16_384)
        XCTAssertEqual(large.width, 16_384)
        XCTAssertEqual(large.height, 16_384)

        for dimensions in [
            (Double.nan, 100.0, 1.0),
            (100.0, Double.infinity, 1.0),
            (0.0, 100.0, 1.0),
        ] {
            XCTAssertThrowsError(
                try Capture.validatedDimensions(
                    width: dimensions.0, height: dimensions.1, scale: dimensions.2))
        }
    }

    func testWindowPlacementRejectsInvalidGeometryBeforeTouchingAccessibility() {
        for frame in [
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 0, height: 100),
        ] {
            XCTAssertThrowsError(try WindowPlacement.validate(frame: frame))
        }
        XCTAssertNoThrow(
            try WindowPlacement.validate(
                frame: CGRect(x: 0, y: 0, width: 16_384, height: 16_384)))
    }

    func testAXTreeRejectsPathologicalWalkLimitsBeforeTouchingAccessibility() {
        XCTAssertThrowsError(
            try AXTree.snapshot(pid: getpid(), maxDepth: Int.max, maxNodes: 1))
        XCTAssertThrowsError(
            try AXTree.snapshot(pid: getpid(), maxDepth: 1, maxNodes: Int.max))
        XCTAssertThrowsError(
            try AXTree.snapshot(pid: getpid(), maxDepth: -1, maxNodes: 1))
    }

    private func makeImage(width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - App resolution

    func testResolveFindsSystemApp() {
        XCTAssertNotNil(AppLauncher.resolve("TextEdit"))
        XCTAssertNotNil(AppLauncher.resolve("com.apple.TextEdit"))
    }

    func testResolveRejectsNonsense() {
        XCTAssertNil(AppLauncher.resolve("DefinitelyNotAnApp-\(UUID().uuidString)"))
    }

    // MARK: - Wire protocol

    func testRequestResponseRoundTrip() throws {
        var request = Request(cmd: "type")
        request.session = "agent-1"
        request.text = "hello"
        let data = try Wire.encoder.encode(request)
        let decoded = try Wire.decoder.decode(Request.self, from: data)
        XCTAssertEqual(decoded.cmd, "type")
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertEqual(decoded.session, "agent-1")
    }

    func testResponseFailureCarriesDescription() throws {
        let response = Response.failure(SpaceOError.unknownSession("nope"))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("nope") == true)
    }

    func testMCPNegotiatesCurrentStableProtocol() {
        XCTAssertEqual(MCPServer.protocolVersion, "2025-11-25")
        XCTAssertTrue(MCPServer.supportedVersions.contains("2025-11-25"))
        XCTAssertTrue(MCPServer.supportedVersions.contains("2024-11-05"),
                      "older installed clients still need an overlap version")
    }

    func testMCPRejectsWindowIDsThatWouldTrapNumericConversion() {
        for value: Any in [-1, 0, Double.greatestFiniteMagnitude, 1.5, true, "42"] {
            XCTAssertThrowsError(
                try MCPServer.toolRequest(
                    name: "spaceo_screenshot",
                    arguments: ["window": value]),
                "unsafe window id \(value) should be a tool error, never a process crash")
        }

        XCTAssertEqual(
            try MCPServer.toolRequest(
                name: "spaceo_screenshot",
                arguments: ["window": 42]).window,
            42)
    }

    func testMCPValidatesClickShapeAndBounds() {
        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_click",
            arguments: ["x": 10]))
        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_click",
            arguments: ["element": "3", "x": 10, "y": 20]))
        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_click",
            arguments: ["element": "3", "count": 1_000_000]))
        XCTAssertNoThrow(try MCPServer.toolRequest(
            name: "spaceo_click",
            arguments: ["x": 10.5, "y": 20, "button": "right", "count": 2]))
    }

    func testMCPBoundsUTF8AndFileCollectionsNotOnlyGraphemes() {
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 16_000)
        XCTAssertEqual(oversizedGrapheme.count, 1)
        XCTAssertGreaterThan(oversizedGrapheme.utf8.count, 32_000)
        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_type",
            arguments: ["text": oversizedGrapheme]))

        XCTAssertThrowsError(try MCPServer.toolRequest(
            name: "spaceo_open_app",
            arguments: [
                "app": "TextEdit",
                "files": Array(repeating: "/tmp/file", count: 257),
            ]))

        XCTAssertEqual(
            try? MCPServer.toolRequest(
                name: "spaceo_press_key",
                arguments: ["key": "return", "web": true]).web,
            true)
    }

    func testMCPScreenshotReaderCannotReadUnexpectedOrUnsafeFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-mcp-shot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = directory.appendingPathComponent("expected.png")
        let other = directory.appendingPathComponent("other.png")
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try pngHeader.write(to: expected)
        try pngHeader.write(to: other)

        XCTAssertEqual(
            try MCPServer.screenshotData(
                responsePath: expected.path, expectedPath: expected.path),
            pngHeader)
        XCTAssertThrowsError(
            try MCPServer.screenshotData(
                responsePath: other.path, expectedPath: expected.path))

        let symlink = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: expected)
        XCTAssertThrowsError(
            try MCPServer.screenshotData(
                responsePath: symlink.path, expectedPath: symlink.path))
    }

    func testMCPLineReaderBoundsInputWithoutLosingTheNextMessage() throws {
        let pipe = Pipe()
        let reader = BoundedLineReader(handle: pipe.fileHandleForReading, maximumBytes: 16)
        pipe.fileHandleForWriting.write(Data((String(repeating: "x", count: 20)
                                              + "\n{\"ok\":true}\n").utf8))
        try pipe.fileHandleForWriting.close()

        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertTrue("\(error)".contains("16 bytes"))
        }
        XCTAssertEqual(try reader.next(), "{\"ok\":true}")
        XCTAssertNil(try reader.next())
    }

    func testMCPLineReaderReturnsBeforeAClientClosesItsPipe() throws {
        let pipe = Pipe()
        let reader = BoundedLineReader(handle: pipe.fileHandleForReading)
        pipe.fileHandleForWriting.write(Data("{\"jsonrpc\":\"2.0\"}\n".utf8))

        // Close after a delay only as a deadlock escape hatch. A streaming reader must return
        // the complete line immediately while the MCP client's stdin pipe remains open.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            try? pipe.fileHandleForWriting.close()
        }
        let started = Date()
        XCTAssertEqual(try reader.next(), "{\"jsonrpc\":\"2.0\"}")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        try? pipe.fileHandleForWriting.close()
    }

    func testMCPLineReaderKeepsRegularFileReadsBounded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-mcp-input-\(UUID().uuidString)")
        var contents = Data(repeating: 0x78, count: 2_000_000)
        contents.append(Data("\n{\"ok\":true}\n".utf8))
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = BoundedLineReader(handle: handle, maximumBytes: 1_048_576)
        XCTAssertThrowsError(try reader.next())
        XCTAssertEqual(try reader.next(), "{\"ok\":true}")
    }

    func testDaemonRejectsUnboundedInputBeforeResolvingASession() async {
        var tooManyClicks = Request(cmd: "click")
        tooManyClicks.count = Int.max
        let clickResponse = await SessionManager().handle(tooManyClicks)
        XCTAssertFalse(clickResponse.ok)
        XCTAssertTrue(clickResponse.error?.contains("1 through 3") == true)

        var tooMuchText = Request(cmd: "type")
        tooMuchText.text = String(repeating: "x", count: 8_001)
        let typeResponse = await SessionManager().handle(tooMuchText)
        XCTAssertFalse(typeResponse.ok)
        XCTAssertTrue(typeResponse.error?.contains("maximum 8000") == true)

        var pathologicalText = Request(cmd: "type")
        pathologicalText.text = "a" + String(repeating: "\u{0301}", count: 16_000)
        let byteResponse = await SessionManager().handle(pathologicalText)
        XCTAssertFalse(byteResponse.ok)
        XCTAssertTrue(byteResponse.error?.contains("32000 UTF-8 bytes") == true)

        var tooManyFiles = Request(cmd: "run")
        tooManyFiles.app = "TextEdit"
        tooManyFiles.files = Array(repeating: "/tmp/file", count: 257)
        let filesResponse = await SessionManager().handle(tooManyFiles)
        XCTAssertFalse(filesResponse.ok)
        XCTAssertTrue(filesResponse.error?.contains("at most 256") == true)
    }

    func testTransportReadLineFramesChunkedInput() throws {
        // Framing must be identical whether the line arrives byte-by-byte or in one chunk.
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("{\"cmd\":\"ping\"}\ntrailing-noise".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(
            Transport.readLine(from: pipe.fileHandleForReading.fileDescriptor),
            "{\"cmd\":\"ping\"}")

        let empty = Pipe()
        empty.fileHandleForWriting.write(Data("\n".utf8))
        try empty.fileHandleForWriting.close()
        XCTAssertNil(Transport.readLine(from: empty.fileHandleForReading.fileDescriptor),
                     "an empty line is not a message")

        let unterminated = Pipe()
        unterminated.fileHandleForWriting.write(Data("tail-without-newline".utf8))
        try unterminated.fileHandleForWriting.close()
        XCTAssertEqual(
            Transport.readLine(from: unterminated.fileHandleForReading.fileDescriptor),
            "tail-without-newline",
            "EOF still delivers the partial line, as before")

        let oversized = Pipe()
        oversized.fileHandleForWriting.write(Data((String(repeating: "x", count: 64) + "\n").utf8))
        try oversized.fileHandleForWriting.close()
        XCTAssertNil(
            Transport.readLine(from: oversized.fileHandleForReading.fileDescriptor,
                               maximumBytes: 16),
            "a line over the limit must be rejected even when it fits in one chunk")
    }

    func testTransportRejectsOverlongSocketPathWithoutCopyingIt() {
        let path = "/" + String(repeating: "x", count: 512)
        XCTAssertThrowsError(try Transport.send(Request(cmd: "ping"), to: path)) { error in
            XCTAssertTrue("\(error)".contains("too long"))
        }
        XCTAssertThrowsError(
            try Transport.send(
                Request(cmd: "ping"), to: "/tmp/spaceo\u{0}truncated.sock")) { error in
            XCTAssertTrue("\(error)".contains("too long")
                          || "\(error)".contains("NUL"))
        }
    }

    func testTransportRejectsInvalidTimeouts() {
        for timeout in [0, -1, .infinity, .nan] {
            XCTAssertThrowsError(
                try Transport.send(Request(cmd: "ping"),
                                   to: "/tmp/does-not-matter.sock",
                                   timeout: timeout))
        }
    }

    func testTransportRejectsOversizedRequestsBeforeOpeningASocket() {
        var request = Request(cmd: "type")
        request.text = String(repeating: "x", count: 1_100_000)
        XCTAssertThrowsError(
            try Transport.send(
                request, to: "/tmp/does-not-exist.sock", timeout: 1)) { error in
            XCTAssertTrue("\(error)".contains("1 MiB"))
        }
    }

    func testServerStopIsSafeWhenCalledConcurrently() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/so-stop-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("daemon.sock").path
        let server = Transport.Server(path: path) { _ in .success() }
        try server.start()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in server.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testSameServerCannotStartTwiceOrDisruptItsFirstListener() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/so-repeat-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("daemon.sock").path

        let server = Transport.Server(path: path) { _ in .success("first") }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue("\(error)".contains("already"), "unexpected error: \(error)")
        }
        XCTAssertTrue(Transport.ping(path),
                      "a rejected second start must leave the first listener healthy")
    }

    func testSecondServerCannotUnlinkAHealthyDaemonSocket() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/so-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("daemon.sock").path

        let first = Transport.Server(path: path) { _ in .success("first") }
        try first.start()
        defer { first.stop() }

        let second = Transport.Server(path: path) { _ in .success("second") }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertTrue("\(error)".contains("already"))
        }
        XCTAssertTrue(Transport.ping(path),
                      "the rejected duplicate must not unlink the first daemon")
    }

    func testServerRefusesToReplaceANonSocketFile() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/so-file-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("keep.txt")
        try "sentinel".write(to: target, atomically: true, encoding: .utf8)

        let server = Transport.Server(path: target.path) { _ in .success() }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue("\(error)".contains("non-socket"))
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")
    }

    func testServerRefusesToUnlinkAnotherProtocolsLiveSocket() throws {
        // sockaddr_un paths are only 104 bytes on Darwin. Keep this fixture deliberately short.
        let path = "/tmp/spaceo-foreign-\(UUID().uuidString.prefix(12)).sock"
        defer { unlink(path) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                _ = strcpy($0, path)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 2), 0)

        let acceptor = Thread {
            for _ in 0..<2 {
                let client = accept(listener, nil, nil)
                if client >= 0 { close(client) }
            }
        }
        acceptor.start()

        let server = Transport.Server(path: path) { _ in .success() }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue("\(error)".contains("not SpaceO"), "unexpected error: \(error)")
        }
        acceptor.cancel()

        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0,
                       "a live foreign socket must remain at its original pathname")
    }

    func testTemporaryBrowserProfileCleanupIsScopedAndEffective() throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-browser-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: profile,
                                                withIntermediateDirectories: false)
        try "cache".write(to: profile.appendingPathComponent("data"),
                          atomically: true, encoding: .utf8)

        let app = LaunchedApp(pid: 999_999,
                              identity: ProcessIdentity(pid: 999_999,
                                                        startedAtMicroseconds: 1),
                              bundleIdentifier: "test",
                              name: "test",
                              url: URL(fileURLWithPath: "/Applications/Test.app"),
                              startedByUs: true,
                              devToolsPort: 9_222,
                              temporaryProfile: profile)
        XCTAssertTrue(AppLauncher.cleanupTemporaryProfile(for: app))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }

    // MARK: - Blame attribution
    //
    // An isolation check that flags the user's own mouse movement as an agent breach cries wolf,
    // and a check that cries wolf gets ignored. These pin down who gets blamed for what.

    func testUserMovingTheirOwnMouseIsNotABreach() {
        let stage = CGRect(x: 2000, y: 0, width: 1000, height: 1000)
        let before = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                       cursor: CGPoint(x: 100, y: 100), activeSpace: 1,
                                       stageRects: [stage])
        let after = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                      cursor: CGPoint(x: 700, y: 400), activeSpace: 1,
                                      stageRects: [stage])
        XCTAssertTrue(after.isUndisturbed(comparedTo: before),
                      "the user moving their mouse on their own display is not our doing")
        XCTAssertEqual(after.ambientChanges(from: before).count, 1)
    }

    func testUserSwitchingTheirOwnAppsIsNotABreach() {
        let before = IsolationSnapshot(frontmostPID: 10, windowServerFrontPID: 10,
                                       cursor: .zero, activeSpace: 1, agentPIDs: [777])
        let after = IsolationSnapshot(frontmostPID: 20, windowServerFrontPID: 20,
                                      cursor: .zero, activeSpace: 1, agentPIDs: [777])
        XCTAssertTrue(after.isUndisturbed(comparedTo: before),
                      "the user switching between their own apps is not our doing")
        XCTAssertTrue(after.ambientChanges(from: before).contains { $0.contains("own apps") })
    }

    func testAgentAppTakingFocusIsABreach() {
        let before = IsolationSnapshot(frontmostPID: 10, windowServerFrontPID: 10,
                                       cursor: .zero, activeSpace: 1, agentPIDs: [777])
        let after = IsolationSnapshot(frontmostPID: 777, windowServerFrontPID: 777,
                                      cursor: .zero, activeSpace: 1, agentPIDs: [777])
        XCTAssertFalse(after.isUndisturbed(comparedTo: before))
        XCTAssertTrue(after.breaches(from: before).contains { $0.contains("took the menu bar") })
    }

    func testBeingPulledOntoAnAgentSpaceIsABreach() {
        let before = IsolationSnapshot(frontmostPID: 10, windowServerFrontPID: 10,
                                       cursor: .zero, activeSpace: 1, agentSpaces: [637])
        let after = IsolationSnapshot(frontmostPID: 10, windowServerFrontPID: 10,
                                      cursor: .zero, activeSpace: 637, agentSpaces: [637])
        XCTAssertFalse(after.isUndisturbed(comparedTo: before))
        XCTAssertTrue(after.breaches(from: before).contains { $0.contains("pulled onto an agent") })
    }

    func testCursorPulledOntoAnAgentScreenIsABreach() {
        let stage = CGRect(x: 2000, y: 0, width: 1000, height: 1000)
        let before = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                       cursor: CGPoint(x: 100, y: 100), activeSpace: 1,
                                       stageRects: [stage])
        let after = IsolationSnapshot(frontmostPID: 1, windowServerFrontPID: 1,
                                      cursor: CGPoint(x: 2500, y: 500), activeSpace: 1,
                                      stageRects: [stage])
        XCTAssertFalse(after.isUndisturbed(comparedTo: before))
        XCTAssertTrue(after.breaches(from: before).contains { $0.contains("agent screen") })
    }

    func testUnpressableElementErrorDoesNotBlameTheApp() {
        let error = SpaceOError.elementNotPressable(role: "AXTextArea", actions: ["AXShowMenu"])
        XCTAssertTrue(error.description.contains("not pressable"))
        XCTAssertFalse(error.description.contains("canvas"),
                       "picking a non-button element is a caller mistake, not an app limitation")
        XCTAssertTrue(error.description.contains("--x"), "the error should point at the way out")
    }

    // MARK: - Tiling
    //
    // Displays are expensive to composite, so sessions share one. These pin down the packing.

    func testSingleSessionGetsTheWholeDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tiles = TileLayout.rects(in: bounds, capacity: 1)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0], bounds)
    }

    func testTwoSessionsSplitSideBySide() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tiles = TileLayout.rects(in: bounds, capacity: 2)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0], CGRect(x: 0, y: 0, width: 960, height: 1080))
        XCTAssertEqual(tiles[1], CGRect(x: 960, y: 0, width: 960, height: 1080))
    }

    func testFourSessionsMakeQuadrants() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tiles = TileLayout.rects(in: bounds, capacity: 4)
        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles[3], CGRect(x: 960, y: 540, width: 960, height: 540))
    }

    /// Overlapping tiles would let one agent's window land in another agent's screenshot,
    /// which is a context-leak between agents, not just a cosmetic bug.
    func testTilesNeverOverlap() {
        let bounds = CGRect(x: -3000, y: 500, width: 2560, height: 1440)
        for capacity in 1...12 {
            let tiles = TileLayout.rects(in: bounds, capacity: capacity)
            XCTAssertEqual(tiles.count, capacity)
            for i in tiles.indices {
                for j in tiles.indices where j > i {
                    XCTAssertFalse(tiles[i].intersects(tiles[j]),
                                   "capacity \(capacity): tile \(i) overlaps tile \(j)")
                }
                XCTAssertTrue(bounds.contains(tiles[i]),
                              "capacity \(capacity): tile \(i) escapes the display")
            }
        }
    }

    func testTilesRespectDisplayOrigin() {
        let bounds = CGRect(x: -1600, y: 900, width: 1600, height: 1000)
        let tiles = TileLayout.rects(in: bounds, capacity: 2)
        XCTAssertEqual(tiles[0].origin.x, -1600)
        XCTAssertEqual(tiles[0].origin.y, 900)
    }

    /// Capacity is bounded now (SPAO-128). The former "any positive integer" policy let a caller
    /// choose how much the layout allocates, and produced tiles no window could use.
    func testTilingIsBoundedByAUsableCapacity() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let tiles = TileLayout.rects(in: bounds, capacity: 4_097)
        XCTAssertEqual(tiles.count, TileLayout.maximumCapacity)
        XCTAssertEqual(tiles.first?.origin, bounds.origin)
    }

    func testSingleTileLookupIsConstantTimeAndBounded() {
        let bounds = CGRect(x: 40, y: 60, width: 8_000, height: 8_000)

        // Inside the bound: an O(1) lookup with no full layout materialised.
        let last = TileLayout.maximumCapacity - 1
        let tile = TileLayout.rect(in: bounds,
                                   capacity: TileLayout.maximumCapacity, index: last)
        XCTAssertNotNil(tile)
        XCTAssertGreaterThan(tile?.width ?? 0, 0)
        XCTAssertNil(TileLayout.rect(in: bounds,
                                     capacity: TileLayout.maximumCapacity,
                                     index: TileLayout.maximumCapacity))

        // Past the bound: refused rather than silently producing zero-area tiles.
        XCTAssertNil(TileLayout.rect(in: bounds, capacity: 1_000_000_000, index: 0))
    }

    func testTilingStillRequiresPositiveCapacity() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(TileLayout.rects(in: bounds, capacity: 0).isEmpty)
        XCTAssertTrue(TileLayout.rects(in: bounds, capacity: -1).isEmpty)
    }

    /// Density is admitted against the tile it would actually produce (SPAO-128), so a request
    /// that "succeeds" into an unusable workspace is refused instead.
    func testPoolRefusesDensityThatWouldProduceUnusableTiles() {
        let pool = DisplayPool(sessionsPerDisplay: 1,
                               displaySize: CGSize(width: 1280, height: 800))
        XCTAssertNoThrow(try pool.setSessionsPerDisplay(4))
        XCTAssertEqual(pool.sessionsPerDisplay, 4)
        XCTAssertThrowsError(try pool.setSessionsPerDisplay(10_000))
        XCTAssertThrowsError(try pool.setSessionsPerDisplay(0))
        XCTAssertEqual(pool.sessionsPerDisplay, 4, "a refused density must not be applied")
    }

    func testPoolAcceptsSaneDisplaysButRejectsInvalidOrOversizedGeometry() {
        // Large is still fine — a virtual display is not a panel anyone has to buy.
        let large = DisplayPool(displaySize: CGSize(width: 5_120, height: 2_880))
        XCTAssertNoThrow(try large.setSessionsPerDisplay(1))

        for invalidSize in [
            CGSize(width: 0, height: 600),
            CGSize(width: -1, height: 600),
            CGSize(width: 1_280.5, height: 800),
            CGSize(width: CGFloat.infinity, height: 800),
            CGSize(width: CGFloat(UInt32.max) + 1, height: 800),
            // Representable by UInt32 but far past what a login session can composite.
            CGSize(width: 16_384, height: 16_384),
        ] {
            let pool = DisplayPool(displaySize: invalidSize)
            XCTAssertThrowsError(try pool.setSessionsPerDisplay(1),
                                 "unsafe display geometry \(invalidSize) must be rejected")
        }
    }

    func testSessionNamesRejectEmptyAndControlCharacters() async {
        let manager = SessionManager()
        for invalid in [" \n", "../escape", #"folder\escape"#] {
            do {
                _ = try await manager.create(name: invalid)
                XCTFail("unsafe session id should fail")
            } catch {
                XCTAssertTrue("\(error)".contains("session id"))
            }
        }
    }

    func testSessionNamesAreStoredInCanonicalTrimmedForm() throws {
        XCTAssertEqual(
            try SessionManager.canonicalSessionID("  canonical  "),
            "canonical")
    }

    // MARK: - Browser detection and bridge validation

    func testChromiumFamilyDetectedFromTheBundle() {
        if let chrome = AppLauncher.resolve("Google Chrome") {
            XCTAssertTrue(AppLauncher.isChromiumFamily(chrome))
        }
        let textEdit = AppLauncher.resolve("TextEdit")!
        XCTAssertFalse(AppLauncher.isChromiumFamily(textEdit),
                       "TextEdit is not a browser and must not be launched with browser flags")
    }

    func testDevToolsEndpointMustStayOnTheExactLoopbackPort() {
        XCTAssertNotNil(
            ChromiumBridge.validatedWebSocketURL(
                "ws://127.0.0.1:43123/devtools/page/abc",
                port: 43_123))
        XCTAssertNotNil(
            ChromiumBridge.validatedWebSocketURL(
                "ws://localhost:43123/devtools/page/abc",
                port: 43_123))
        XCTAssertNil(
            ChromiumBridge.validatedWebSocketURL(
                "ws://example.com:43123/devtools/page/abc",
                port: 43_123))
        XCTAssertNil(
            ChromiumBridge.validatedWebSocketURL(
                "ws://127.0.0.1:43124/devtools/page/abc",
                port: 43_123))
        XCTAssertNil(
            ChromiumBridge.validatedWebSocketURL(
                "wss://127.0.0.1:43123/devtools/page/abc",
                port: 43_123))
    }

    func testDevToolsPortComesFromThePrivateProfileMarker() throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceo-browser-port-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: profile,
                                                withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: profile) }
        let marker = profile.appendingPathComponent("DevToolsActivePort")

        try "43123\n/devtools/browser/example\n".write(
            to: marker, atomically: true, encoding: .utf8)
        XCTAssertEqual(AppLauncher.devToolsPort(in: profile), 43_123)
        try "not-a-port\n".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertNil(AppLauncher.devToolsPort(in: profile))
    }

    // MARK: - CLI output contracts

    func testVersionJSONIsOneMachineReadableDocument() throws {
        let result = try runSpaceO(["version", "--json"])
        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardError.isEmpty)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, "1.0.0")
        XCTAssertEqual(object.count, 1, "version JSON should stay small and stable")
    }

    func testDoctorJSONIsStructuredEvenWhenTheHostIsUnhealthy() throws {
        // Isolate the probe from a daemon the developer may already be running. `doctor` is
        // allowed to exit 1 when TCC or private capabilities are missing; its JSON contract must
        // remain parseable in that case so an agent can explain the failed health check.
        let socketPath = "/tmp/so-doctor-\(UUID().uuidString.prefix(12)).sock"
        let result = try runSpaceO(["doctor", "--json", "--socket", socketPath])
        XCTAssertTrue(result.status == 0 || result.status == 1,
                      "doctor exited \(result.status): \(result.standardError)")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
            "doctor did not emit one JSON object: \(result.standardOutputText)")
        XCTAssertNotNil(object["ok"] as? Bool)
        XCTAssertNotNil(object["macOS"] as? String)
        XCTAssertNotNil(object["canDrive"] as? Bool)
        XCTAssertNotNil(object["canCapture"] as? Bool)
        XCTAssertNotNil(object["builtWithARC"] as? Bool)
        XCTAssertNotNil(object["missingSymbols"] as? [Any])

        let capabilities = try XCTUnwrap(object["capabilities"] as? [[String: Any]])
        XCTAssertFalse(capabilities.isEmpty)
        for capability in capabilities {
            XCTAssertNotNil(capability["name"] as? String)
            XCTAssertNotNil(capability["available"] as? Bool)
            XCTAssertNotNil(capability["detail"] as? String)
        }

        let daemon = try XCTUnwrap(object["daemon"] as? [String: Any])
        XCTAssertEqual(daemon["socket"] as? String, socketPath)
        XCTAssertEqual(daemon["running"] as? Bool, false)

        let displays = try XCTUnwrap(object["displays"] as? [String: Any])
        for key in ["spaceO", "orphanedSpaceO", "userOnline", "userActive", "mirroredUser"] {
            XCTAssertNotNil(displays[key] as? [Any], "missing displays.\(key)")
        }
    }

    private struct CLIResult {
        let status: Int32
        let standardOutput: Data
        let standardError: String

        var standardOutputText: String {
            String(data: standardOutput, encoding: .utf8) ?? "<non-UTF-8 output>"
        }
    }

    private func runSpaceO(_ arguments: [String]) throws -> CLIResult {
        // SwiftPM places sibling executable products next to the XCTest bundle. Deriving the
        // path from the bundle keeps this independent of architecture-specific `.build` paths.
        let executable = Bundle(for: UnitTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("spaceo")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("spaceo executable was not built next to the test bundle")
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        return CLIResult(
            status: process.terminationStatus,
            standardOutput: outputData,
            standardError: String(data: errorData, encoding: .utf8) ?? "<non-UTF-8 stderr>")
    }

}
