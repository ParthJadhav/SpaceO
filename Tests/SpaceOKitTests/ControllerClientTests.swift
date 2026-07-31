import Foundation
import XCTest
@testable import SpaceOKit
@testable import SpaceOMCP

final class ControllerClientTests: XCTestCase {

    func testMCPCreateUsesControllerMetadataAndTracksOnlyReturnedLease() throws {
        let processIdentity = try XCTUnwrap(ProcessIdentity.current(of: getpid()))
        let defaultOwner = DurableSessionOwner(
            id: "mcp-test",
            kind: .mcp,
            label: "SpaceO MCP",
            processIdentity: processIdentity
        )
        let context = MCPControllerContext(owner: defaultOwner)
        let translated = try MCPServer.toolRequest(
            name: "spaceo_session_create",
            arguments: [
                "name": "research",
                "controller_id": "controller-7",
                "controller_label": "Research agent",
                "controller_kind": "other",
                "ttl_seconds": 90,
            ],
            defaultControllerOwner: context.owner
        )
        let request = try context.prepare(translated)

        XCTAssertEqual(request.cmd, "session.create")
        XCTAssertEqual(request.session, "research")
        XCTAssertEqual(request.controllerOwner?.id, "controller-7")
        XCTAssertEqual(request.controllerOwner?.label, "Research agent")
        XCTAssertEqual(request.controllerOwner?.kind, .other)
        XCTAssertEqual(request.controllerOwner?.processIdentity, processIdentity)
        XCTAssertEqual(request.controllerTTLSeconds, 90)
        XCTAssertNotNil(request.controllerLeaseID)

        let returnedLease = UUID()
        var response = Response(ok: true)
        response.session = try sessionInfo(id: "research")
        response.controllerLeaseID = returnedLease
        context.record(response, for: request)

        let mutation = try context.prepare(MCPServer.toolRequest(
            name: "spaceo_open_app",
            arguments: ["session": "research", "app": "TextEdit"]
        ))
        XCTAssertEqual(mutation.controllerLeaseID, returnedLease,
                       "the daemon-returned credential, not a guessed value, is authoritative")

        let heartbeat = try context.prepare(MCPServer.toolRequest(
            name: "spaceo_session_heartbeat",
            arguments: ["session": "research"]
        ))
        XCTAssertEqual(heartbeat.cmd, "session.heartbeat")
        XCTAssertEqual(heartbeat.controllerLeaseID, returnedLease)

        let destroy = try context.prepare(MCPServer.toolRequest(
            name: "spaceo_session_destroy",
            arguments: ["session": "research"]
        ))
        XCTAssertEqual(destroy.controllerLeaseID, returnedLease)
    }

    func testMCPRequiresConnectionLocalLeaseForHeartbeatAndMutations() throws {
        let context = MCPControllerContext(owner: DurableSessionOwner(
            id: "mcp-test",
            kind: .mcp,
            label: "SpaceO MCP"
        ))

        for request in [
            try MCPServer.toolRequest(
                name: "spaceo_session_heartbeat",
                arguments: ["session": "external"]
            ),
            try MCPServer.toolRequest(
                name: "spaceo_click",
                arguments: ["session": "external", "x": 10, "y": 20]
            ),
        ] {
            XCTAssertThrowsError(try context.prepare(request)) { error in
                XCTAssertTrue("\(error)".contains("not recoverable from session.list"))
            }
        }
    }

    func testMCPAllowsNamedDetachedDestroyWithoutAStoredLease() throws {
        let context = MCPControllerContext(owner: DurableSessionOwner(
            id: "mcp-test",
            kind: .mcp,
            label: "SpaceO MCP"
        ))

        let request = try context.prepare(MCPServer.toolRequest(
            name: "spaceo_session_destroy",
            arguments: ["session": "detached-from-prior-daemon"]
        ))

        XCTAssertEqual(request.cmd, "session.destroy")
        XCTAssertEqual(request.session, "detached-from-prior-daemon")
        XCTAssertNil(request.controllerLeaseID)
    }

    func testMCPPublishesHeartbeatAndRejectsInvalidControllerCreateArguments() throws {
        let names = MCPServer.toolSchemas.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("spaceo_session_heartbeat"))

        let owner = MCPControllerContext.defaultOwner()
        XCTAssertEqual(owner.kind, .mcp)
        XCTAssertEqual(owner.label, "SpaceO MCP")
        XCTAssertNotNil(owner.processIdentity)

        for arguments: [String: Any] in [
            ["ttl_seconds": 29],
            ["ttl_seconds": 3_601],
            ["controller_kind": "daemon"],
            ["controller_label": " untrimmed"],
        ] {
            XCTAssertThrowsError(try MCPServer.toolRequest(
                name: "spaceo_session_create",
                arguments: arguments,
                defaultControllerOwner: owner
            ))
        }
    }

    func testMCPRenderingNeverDisclosesTopLevelLeaseCredential() {
        let lease = UUID()
        var response = Response(ok: true)
        response.message = "created"
        response.controllerLeaseID = lease

        XCTAssertFalse(MCPServer.render(response).contains(lease.uuidString))
    }

    func testMCPListRenderingLabelsDetachedRecoveryMetadataAndStalePlacement() throws {
        var response = Response(ok: true)
        response.sessions = [try detachedSessionInfo()]

        let rendered = MCPServer.render(response)

        XCTAssertTrue(rendered.contains(
            "session 'detached' [detached recovery record; no live display target]"
        ), rendered)
        XCTAssertTrue(rendered.contains(
            "last-known placement only: tile 2/4 of display 44"
        ), rendered)
        XCTAssertTrue(rendered.contains("lifecycle: reclaimable"), rendered)
        XCTAssertTrue(rendered.contains(
            "owner: Research agent (mcp, id controller-gone)"
        ), rendered)
        XCTAssertTrue(rendered.contains("last activity: 2026-07-28T01:02:03Z"), rendered)
        XCTAssertTrue(rendered.contains("age: 367s"), rendered)
        XCTAssertTrue(rendered.contains(
            "recovery blocker process-identity-imprecise: exact process identity unavailable"
        ), rendered)
        XCTAssertTrue(rendered.contains("recorded app TextEdit (pid 4321)"), rendered)
        XCTAssertFalse(rendered.contains("session 'detached' on tile"), rendered)
    }

    func testCLICreateSendsControllerContractAndPrintsSecretGuidance() throws {
        let requestedLease = UUID()
        let returnedLease = UUID()
        let capture = RequestCapture()
        let result = try withServer(capture: capture) { socketPath in
            try runSpaceO([
                "session", "create",
                "--socket", socketPath,
                "--session", "research",
                "--controller-id", "cli-test",
                "--controller-label", "Test CLI",
                "--controller-kind", "other",
                "--controller-ttl", "90",
                "--lease", requestedLease.uuidString,
            ])
        } response: { request in
            var response = Response(ok: true)
            response.message = "created '\(request.session ?? "?")'"
            response.controllerLeaseID = returnedLease
            return response
        }

        XCTAssertEqual(result.status, 0, result.standardError)
        let request = try XCTUnwrap(capture.value)
        XCTAssertEqual(request.cmd, "session.create")
        XCTAssertEqual(request.session, "research")
        XCTAssertEqual(request.controllerOwner?.id, "cli-test")
        XCTAssertEqual(request.controllerOwner?.label, "Test CLI")
        XCTAssertEqual(request.controllerOwner?.kind, .other)
        XCTAssertNil(request.controllerOwner?.processIdentity,
                     "short-lived CLI process exit must not abandon the session")
        XCTAssertEqual(request.controllerTTLSeconds, 90)
        XCTAssertEqual(request.controllerLeaseID, requestedLease)
        XCTAssertTrue(result.standardOutput.contains(returnedLease.uuidString.lowercased()))
        XCTAssertTrue(result.standardOutput.contains("Keep this credential secret"))
        XCTAssertTrue(result.standardOutput.contains("--lease <UUID>"))
        XCTAssertTrue(result.standardOutput.contains("cannot be recovered"))
    }

    func testCLIHeartbeatRequiresAndForwardsLease() throws {
        let missing = try runSpaceO([
            "session", "heartbeat",
            "--socket", temporarySocketPath(),
            "--session", "research",
        ])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.standardError.contains("--lease UUID is required"))

        let lease = UUID()
        let capture = RequestCapture()
        let result = try withServer(capture: capture) { socketPath in
            try runSpaceO([
                "session", "heartbeat",
                "--socket", socketPath,
                "--session", "research",
                "--lease", lease.uuidString,
            ])
        } response: { request in
            var response = Response(ok: true)
            response.message = "renewed"
            response.controllerLeaseID = request.controllerLeaseID
            return response
        }

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(capture.value?.cmd, "session.heartbeat")
        XCTAssertEqual(capture.value?.session, "research")
        XCTAssertEqual(capture.value?.controllerLeaseID, lease)
        XCTAssertTrue(result.standardOutput.contains(lease.uuidString.lowercased()))
    }

    func testCLIMutationForwardsLease() throws {
        let lease = UUID()
        let capture = RequestCapture()
        let result = try withServer(capture: capture) { socketPath in
            try runSpaceO([
                "run", "TextEdit",
                "--socket", socketPath,
                "--session", "research",
                "--lease", lease.uuidString,
            ])
        } response: { _ in
            Response.success("launched")
        }

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(capture.value?.cmd, "run")
        XCTAssertEqual(capture.value?.controllerLeaseID, lease)
    }

    func testCLIDestroyForwardsLease() throws {
        let lease = UUID()
        let capture = RequestCapture()
        let result = try withServer(capture: capture) { socketPath in
            try runSpaceO([
                "session", "destroy",
                "--socket", socketPath,
                "--session", "research",
                "--lease", lease.uuidString,
            ])
        } response: { _ in
            Response.success("destroyed")
        }

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(capture.value?.cmd, "session.destroy")
        XCTAssertEqual(capture.value?.session, "research")
        XCTAssertEqual(capture.value?.controllerLeaseID, lease)
    }

    func testCLIDaemonStopSupportsGlobalJSONOutput() throws {
        let capture = RequestCapture()
        let result = try withServer(capture: capture) { socketPath in
            try runSpaceO([
                "daemon", "stop",
                "--socket", socketPath,
                "--json",
            ])
        } response: { _ in
            Response.success("stopping SpaceO daemon")
        }

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(capture.value?.cmd, "daemon.stop")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["message"] as? String, "stopping SpaceO daemon")
    }

    func testCLIListRenderingLabelsDetachedRecoveryMetadataAndStalePlacement() throws {
        let capture = RequestCapture()
        let detached = try detachedSessionInfo()
        let result = try withServer(capture: capture) { socketPath in
            try runSpaceO([
                "session", "list",
                "--socket", socketPath,
            ])
        } response: { _ in
            var response = Response(ok: true)
            response.sessions = [detached]
            return response
        }

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(capture.value?.cmd, "session.list")
        XCTAssertTrue(result.standardOutput.contains(
            "session detached  DETACHED RECOVERY RECORD"
        ), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(
            "last-known placement only: display 44 (tile 2/4)"
        ), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains("not a live target"), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(
            "lifecycle: reclaimable"
        ), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(
            "owner: Research agent (mcp, id controller-gone)"
        ), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(
            "last activity: 2026-07-28T01:02:03Z"
        ), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains("age: 367s"), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(
            "! process-identity-imprecise: exact process identity unavailable"
        ), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(
            "recorded app  pid 4321  TextEdit"
        ), result.standardOutput)
        XCTAssertFalse(result.standardOutput.contains(
            "session detached  display"
        ), result.standardOutput)
    }

    private func sessionInfo(id: String) throws -> SessionInfo {
        let json = """
        {
          "id": "\(id)",
          "displayID": 7,
          "x": 0,
          "y": 0,
          "width": 1280,
          "height": 800,
          "tileIndex": 0,
          "tileCapacity": 1,
          "exclusiveDisplay": true,
          "spaces": [],
          "hasOwnSpace": false,
          "apps": [],
          "windows": [],
          "createdAt": "2026-07-28T00:00:00Z",
          "teardownPending": false
        }
        """
        return try Wire.decoder.decode(SessionInfo.self, from: Data(json.utf8))
    }

    private func detachedSessionInfo() throws -> SessionInfo {
        let json = """
        {
          "id": "detached",
          "displayID": 44,
          "x": 640,
          "y": 0,
          "width": 640,
          "height": 800,
          "tileIndex": 1,
          "tileCapacity": 4,
          "exclusiveDisplay": false,
          "spaces": [],
          "hasOwnSpace": false,
          "apps": [
            {
              "pid": 4321,
              "name": "TextEdit",
              "bundleID": "com.apple.TextEdit",
              "startedByUs": true
            }
          ],
          "windows": [],
          "createdAt": "2026-07-28T01:00:00Z",
          "teardownPending": false,
          "runtimeAttached": false,
          "controllerOwner": {
            "id": "controller-gone",
            "kind": "mcp",
            "label": "Research agent"
          },
          "ageSeconds": 367,
          "lastActivityAt": "2026-07-28T01:02:03Z",
          "abandoned": true,
          "reclaimable": true,
          "recoveryBlockers": [
            {
              "code": "process-identity-imprecise",
              "message": "exact process identity unavailable"
            }
          ]
        }
        """
        return try Wire.decoder.decode(SessionInfo.self, from: Data(json.utf8))
    }

    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Request?

        var value: Request? {
            lock.withLock { stored }
        }

        func set(_ request: Request) {
            lock.withLock { stored = request }
        }
    }

    private struct CLIResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private func withServer(
        capture: RequestCapture,
        run: (String) throws -> CLIResult,
        response: @escaping @Sendable (Request) -> Response
    ) throws -> CLIResult {
        let socketPath = temporarySocketPath()
        let server = Transport.Server(path: socketPath) { request in
            capture.set(request)
            return response(request)
        }
        try server.start()
        defer { server.stop() }
        return try run(socketPath)
    }

    private func temporarySocketPath() -> String {
        "/tmp/so-client-\(UUID().uuidString.prefix(12)).sock"
    }

    private func runSpaceO(_ arguments: [String]) throws -> CLIResult {
        let executable = Bundle(for: ControllerClientTests.self).bundleURL
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

        return CLIResult(
            status: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<non-UTF-8 stdout>",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<non-UTF-8 stderr>"
        )
    }
}
