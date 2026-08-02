import Foundation
import Darwin
import SpaceOKit

enum MCPControllerError: Error, CustomStringConvertible, LocalizedError {
    case missingLease(String)

    var description: String {
        switch self {
        case .missingLease(let session):
            let target = session.isEmpty ? "the requested session" : "session '\(session)'"
            return "No controller lease is available for \(target). Create the session with "
                + "this MCP connection and keep using the same connection; lease credentials "
                + "are intentionally not recoverable from session.list."
        }
    }

    var errorDescription: String? { description }
}

/// What one tool call turns into on the wire. Almost everything is a single daemon round trip;
/// a full destroy is deliberately not, because the daemon's `full` path is an unauthorized
/// machine-wide sweep and an agent must only ever tear down its own sessions.
enum MCPRequestPlan {
    case single(Request)
    /// One authorized named destroy per session this connection holds a lease for. Empty when
    /// the connection owns nothing, which is a no-op rather than a sweep.
    case ownedSessionDestroy([Request])
}

/// Controller credentials belong to one MCP stdio connection. They are never placed in tool
/// output or recovered from observer-facing session metadata.
final class MCPControllerContext {
    let owner: DurableSessionOwner
    private var leases: [String: UUID] = [:]

    init(owner: DurableSessionOwner = MCPControllerContext.defaultOwner()) {
        self.owner = owner
    }

    static func defaultOwner() -> DurableSessionOwner {
        let pid = getpid()
        let identity = ProcessIdentity.current(of: pid)
        let start = identity?.startedAtMicroseconds ?? 0
        return DurableSessionOwner(
            id: "mcp-\(pid)-\(start)",
            kind: .mcp,
            label: "SpaceO MCP",
            processIdentity: identity
        )
    }

    /// Translate one tool call into the daemon traffic it is allowed to produce.
    ///
    /// `session.destroy --all` is the one command that must not be forwarded as written: on the
    /// daemon it reaches `destroyAllNow` without passing controller authorization, so it would
    /// quit every app of every other agent sharing the pool. Agents share one daemon by design,
    /// so this connection expands it into named destroys for the sessions it actually leases.
    func plan(_ supplied: Request) throws -> MCPRequestPlan {
        guard supplied.cmd == "session.destroy", supplied.full == true else {
            return .single(try prepare(supplied))
        }
        return .ownedSessionDestroy(leases.keys.sorted().map { sessionID in
            var request = supplied
            request.full = nil
            request.session = sessionID
            request.controllerLeaseID = leases[sessionID]
            return request
        })
    }

    func prepare(_ supplied: Request) throws -> Request {
        var request = supplied
        switch request.cmd {
        case "session.create":
            if request.controllerOwner == nil {
                request.controllerOwner = owner
            }
            if request.controllerLeaseID == nil {
                request.controllerLeaseID = UUID()
            }
        case let command where DaemonCommand.ownerScopedMutations.contains(command):
            guard let lease = lease(for: request.session) else {
                throw MCPControllerError.missingLease(request.session ?? "")
            }
            request.controllerLeaseID = lease
        case "session.destroy":
            // A lease is required for a live explicitly owned session, but named detached
            // recovery records intentionally have no renewable credential. Forward a stored
            // connection-local lease when one exists and let the daemon distinguish those cases.
            // `plan` has already expanded any `full` destroy into named requests by this point.
            if request.full != true {
                request.controllerLeaseID = lease(for: request.session)
            }
        default:
            break
        }
        return request
    }

    func record(_ response: Response, for request: Request) {
        guard response.ok else { return }
        switch request.cmd {
        case "session.create", "session.heartbeat":
            guard let sessionID = response.session?.id,
                  let lease = response.controllerLeaseID else {
                return
            }
            leases[sessionID] = lease
        case "session.destroy":
            if request.full == true {
                leases.removeAll()
            } else if let sessionID = request.session {
                leases.removeValue(forKey: sessionID)
            } else if leases.count == 1, let sessionID = leases.keys.first {
                leases.removeValue(forKey: sessionID)
            }
        default:
            break
        }
    }

    func storedLease(for sessionID: String) -> UUID? {
        leases[sessionID]
    }

    private func lease(for sessionID: String?) -> UUID? {
        if let sessionID {
            return leases[sessionID]
        }
        guard leases.count == 1 else { return nil }
        return leases.values.first
    }
}

/// Model Context Protocol server over stdio, so Claude Code, Codex, Cursor and anything else
/// that speaks MCP can drive SpaceO.
///
/// The server is a thin translator onto the daemon's socket protocol. It deliberately does not
/// host sessions itself: agent displays must be shared across *all* agents on the machine, and
/// that only works if one process owns the pool. If no daemon is running, we start one.
///
/// stdout carries JSON-RPC and nothing else. Diagnostics go to stderr.
public enum MCPServer {

    static let protocolVersion = "2025-11-25"
    static let supportedVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    public static func run(socketPath: String) -> Never {
        ensureDaemon(socketPath: socketPath)
        let input = BoundedLineReader(handle: .standardInput)
        let controller = MCPControllerContext()

        while true {
            let line: String
            do {
                guard let next = try input.next() else { break }
                line = next
            } catch {
                respond(error: -32700, message: "parse error: \(error)", id: nil)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                respond(error: -32700, message: "parse error", id: nil)
                continue
            }
            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: data)
            } catch {
                respond(error: -32700, message: "parse error", id: nil)
                continue
            }
            guard let message = decoded as? [String: Any] else {
                respond(error: -32600, message: "invalid request", id: nil)
                continue
            }
            handle(message, socketPath: socketPath, controller: controller)
        }
        exit(0)
    }

    // MARK: - Daemon lifecycle

    private static func ensureDaemon(socketPath: String) {
        if Transport.ping(socketPath) { return }

        // argv[0] can be a bare or relative name when the client found us via PATH; resolving
        // that against the client's working directory spawns the wrong thing or nothing.
        let executable = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon", "--socket", socketPath]
        // A daemon must not keep stdout/stderr connected to the short-lived MCP process. A pipe
        // loses its reader when MCP exits, and a later diagnostic write can then kill the daemon
        // with SIGPIPE. An unlinked temporary file preserves startup diagnostics on failure and
        // becomes an anonymous, nonblocking sink after successful startup.
        let diagnostics = startupDiagnosticsFile()
        process.standardOutput = diagnostics ?? FileHandle.nullDevice
        process.standardError = diagnostics ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? diagnostics?.close()
            note("could not start the SpaceO daemon: \(error)")
            return
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if Transport.ping(socketPath) {
                try? diagnostics?.close()
                note("started SpaceO daemon on \(socketPath)")
                return
            }
            if !process.isRunning,
               !FileManager.default.fileExists(atPath: socketPath) {
                break
            }
            // A concurrently spawned daemon may have won the socket and still be fencing its
            // ledger. In that case this child exits, but the live socket remains; keep polling
            // the winner instead of returning a not-yet-ready MCP connection.
            usleep(200_000)
        }

        if process.isRunning {
            note("SpaceO daemon did not answer within 10s; stopping the failed child")
            stopSpawnedProcess(process)
        }
        let output = readStartupDiagnostics(diagnostics)
        note("SpaceO daemon exited during startup: \(output.isEmpty ? "no output" : output)")
    }

    private static func startupDiagnosticsFile() -> FileHandle? {
        var template = Array(
            (NSTemporaryDirectory() + "spaceo-daemon-startup.XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return mkstemp(base)
        }
        guard fd >= 0 else { return nil }
        _ = fchmod(fd, S_IRUSR | S_IWUSR)
        template.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { _ = unlink(base) }
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func readStartupDiagnostics(_ handle: FileHandle?) -> String {
        guard let handle else { return "" }
        try? handle.synchronize()
        try? handle.seek(toOffset: 0)
        // The daemon is our child, but diagnostics still cross a process boundary. Never let a
        // failed or corrupted child make the MCP parent allocate an unbounded file.
        let data = (try? handle.read(upToCount: 65_537)) ?? nil
        try? handle.close()
        let bounded = (data ?? Data()).prefix(65_536)
        let suffix = (data?.count ?? 0) > bounded.count ? "\n[diagnostics truncated]" : ""
        return String(decoding: bounded, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            + suffix
    }

    private static func stopSpawnedProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data("[spaceo-mcp] \(text)\n".utf8))
    }

    // MARK: - Dispatch

    private static func handle(
        _ message: [String: Any],
        socketPath: String,
        controller: MCPControllerContext
    ) {
        let hasID = message.keys.contains("id")
        let id = validID(message["id"])

        // MCP methods other than the two notifications below are requests, not fire-and-forget
        // operations. Ignoring an invalid notification also prevents a malformed tools/call
        // message from creating a GUI session that the client can never learn about or destroy.
        if !hasID {
            guard let method = message["method"] as? String else { return }
            if method == "notifications/initialized" || method == "notifications/cancelled" {
                return
            }
            return
        }

        guard message["jsonrpc"] as? String == "2.0", id != nil else {
            respond(error: -32600, message: "invalid request", id: nil)
            return
        }
        guard let method = message["method"] as? String else {
            respond(error: -32600, message: "missing method", id: id)
            return
        }
        let params: [String: Any]
        if let supplied = message["params"] {
            guard let object = supplied as? [String: Any] else {
                respond(error: -32602, message: "params must be an object", id: id)
                return
            }
            params = object
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String, !requested.isEmpty else {
                respond(error: -32602, message: "initialize needs a protocolVersion", id: id)
                return
            }
            let version = supportedVersions.contains(requested) ? requested : protocolVersion
            respond(result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "spaceo", "version": SpaceOVersion.current],
                "instructions": """
                SpaceO gives each agent a virtual display and routes input without activating or \
                raising the agent's applications. Create a session before launching or driving \
                apps, and destroy the session when work is complete.

                Addressing: prefer indexed accessibility elements from spaceo_read_screen over \
                coordinates — an index cannot miss and survives the window moving. Use \
                coordinates when you need something an accessibility press cannot express: a \
                right-click, a double-click, a modifier-held click, a drag, or a point with no \
                accessibility element at all. All coordinates are window-local points, and \
                spaceo_screenshot at the default scale=1 returns one pixel per point, so a \
                coordinate you read off the image is a coordinate you can click.

                Reaching content: spaceo_read_screen only describes what is currently on screen. \
                Use spaceo_scroll to bring anything below the fold into view, and spaceo_move to \
                reveal hover-only menus and tooltips, then read the screen again.

                SpaceO isolates attention, not security: launched apps and same-user clients \
                retain the macOS user's file, network, app-session, notification, and credential \
                authority. Use a separate login session or VM for untrusted agents or \
                applications.
                """,
            ], id: id)

        case "ping":
            respond(result: [:], id: id)

        case "tools/list":
            respond(result: ["tools": toolSchemas], id: id)

        case "tools/call":
            guard let name = params["name"] as? String else {
                respond(error: -32602, message: "tools/call needs a name", id: id)
                return
            }
            let arguments: [String: Any]
            if let supplied = params["arguments"] {
                guard let object = supplied as? [String: Any] else {
                    respond(result: toolError("tool arguments must be an object"), id: id)
                    return
                }
                arguments = object
            } else {
                arguments = [:]
            }
            callTool(
                name: name,
                arguments: arguments,
                socketPath: socketPath,
                controller: controller,
                id: id
            )

        default:
            respond(error: -32601, message: "unknown method '\(method)'", id: id)
        }
    }

    // MARK: - Tools

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static var sessionArg: [String: Any] {
        [
            "type": "string",
            "description": "Session id with no control characters or path separators. "
                + "Omit when only one session exists.",
        ]
    }

    static var toolSchemas: [[String: Any]] {
        let windowArg: [String: Any] = [
            "type": "integer",
            "minimum": 1,
            "maximum": UInt32.max,
            "description": "Window id; defaults to the session's main window.",
        ]

        let webPointArg: [String: Any] = [
            "type": "boolean",
            "description":
                "Treat x/y as CSS viewport coordinates inside a web page — the numbers "
                + "spaceo_read_screen prints beside each wN element. Leave unset for "
                + "window-local points.",
        ]

        let modifiersArg: [String: Any] = [
            "type": "array",
            "maxItems": 5,
            "items": ["type": "string", "enum": ["cmd", "shift", "alt", "ctrl", "fn"]],
            "description":
                "Modifier keys held for the whole action, e.g. [\"shift\"] to extend a "
                + "selection or [\"cmd\"] to multi-select.",
        ]

        func tool(_ name: String, _ description: String,
                  _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = [
                "type": "object",
                "properties": properties,
                "additionalProperties": false,
            ]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema]
        }

        return [
            tool("spaceo_session_create", """
                Create an agent session: a tile on a SpaceO virtual display that can be viewed \
                and controlled through the session tools or SpaceO Viewer. Do this once before \
                opening any app. The MCP connection keeps the returned controller lease secret \
                and automatically supplies it to later mutations.
                """, [
                    "name": [
                        "type": "string",
                        "description": "Optional session id. Auto-generated when omitted.",
                    ],
                    "controller_id": [
                        "type": "string",
                        "maxLength": 256,
                        "description": "Stable diagnostic controller id. Defaults to this MCP process.",
                    ],
                    "controller_label": [
                        "type": "string",
                        "maxLength": 256,
                        "description": "Human-readable owner label. Defaults to SpaceO MCP.",
                    ],
                    "controller_kind": [
                        "type": "string",
                        "enum": ["cli", "mcp", "viewer", "other"],
                        "description": "Controller kind. Defaults to mcp.",
                    ],
                    "ttl_seconds": [
                        "type": "number",
                        "minimum": 30,
                        "maximum": 3_600,
                        "description": "Lease lifetime; successful mutations renew it.",
                    ],
                ]),

            tool("spaceo_session_list",
                 "List agent sessions with their displays, tiles, apps and windows."),

            tool("spaceo_session_heartbeat", """
                Renew this MCP connection's controller lease without mutating the session. Use \
                this while reasoning or waiting longer than the lease TTL.
                """, ["session": sessionArg]),

            tool("spaceo_session_destroy", """
                End a session: quit the apps it started and free its tile. Always do this when \
                you are finished, or the apps keep running invisibly. If cleanup reports \
                surviving processes or displays, resolve the named resource and call this tool \
                again; SpaceO retains ownership specifically so the retry is safe. This only ever \
                ends sessions this MCP connection created; other agents share the same pool and \
                keep their sessions and apps.
                """, ["session": sessionArg,
                      "all": [
                          "type": "boolean",
                          "description": "Destroy every session this MCP connection created. "
                              + "Sessions belonging to other agents are left running.",
                      ]]),

            tool("spaceo_open_app", """
                Launch an app into the session's off-screen tile without activating it, so the \
                user keeps their frontmost app. Accepts an app name ("Safari"), a bundle id, or \
                a path. Optionally opens files.
                """, ["app": [
                          "type": "string",
                          "maxLength": 4_096,
                          "description": "App name, bundle id, or .app path.",
                      ],
                      "files": ["type": "array",
                                "maxItems": 256,
                                "items": ["type": "string", "maxLength": 4_096],
                                "description": "Optional file paths to open."],
                      "session": sessionArg],
                 required: ["app"]),

            tool("spaceo_read_screen", """
                Read the focused window as an indexed list of actionable accessibility elements, \
                e.g. "[3] Button — Save". This is the primary way to see what is on screen: it \
                is cheaper and far more reliable than a screenshot, and the indices it returns \
                are what spaceo_click takes. Call it again after anything changes.
                """, ["session": sessionArg,
                      "window": windowArg,
                      "full": ["type": "boolean",
                               "description": "Include non-actionable elements too. Verbose."]]),

            tool("spaceo_screenshot", """
                PNG of the session's window, or of its whole tile with full=true. Use when you \
                need to see layout or images that the accessibility outline cannot convey. \
                At the default scale=1 one image pixel is one point, so a coordinate you read \
                off the image is exactly what spaceo_click takes. Pass x/y/width/height \
                (tile-relative) to zoom into part of the tile instead of capturing all of it.
                """, ["session": sessionArg,
                      "window": windowArg,
                      "full": ["type": "boolean", "description": "Capture the whole tile."],
                      "scale": ["type": "integer", "minimum": 1, "maximum": 4,
                                "description":
                                    "Pixels per point. Leave at 1 so image coordinates are "
                                    + "click coordinates; raise only to read small text."],
                      "x": ["type": "number", "description": "Region origin x, tile-relative."],
                      "y": ["type": "number", "description": "Region origin y, tile-relative."],
                      "width": ["type": "integer", "minimum": 1,
                                "description": "Region width in points."],
                      "height": ["type": "integer", "minimum": 1,
                                 "description": "Region height in points."]]),

            tool("spaceo_click", """
                Click an element by its reference from spaceo_read_screen (preferred — it cannot \
                miss), or by x/y coordinates relative to the window's top-left corner. \
                References look like "3" for an app control and "w3" for an element inside a \
                web page. An element reference performs an accessibility press, so it cannot \
                carry a button, count, or modifiers — use x/y coordinates for those.
                """, ["element": ["type": "string", "maxLength": 32,
                                  "description": "Reference from spaceo_read_screen: \"3\" or \"w3\"."],
                      "x": ["type": "number", "description": "Window-relative x, in points."],
                      "y": ["type": "number", "description": "Window-relative y, in points."],
                      "button": ["type": "string", "enum": ["left", "right", "middle"]],
                      "count": ["type": "integer", "minimum": 1, "maximum": 3,
                                "description": "2 for a double-click, 3 to select a line."],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_scroll", """
                Scroll at a point inside the window. Positive dy scrolls content up (reveals \
                what is below); negative dy scrolls down. This is how you reach anything below \
                the fold — the accessibility outline only describes what is currently on screen.
                """, ["x": ["type": "number", "description": "Window-relative x to scroll over."],
                      "y": ["type": "number", "description": "Window-relative y to scroll over."],
                      "dy": ["type": "integer", "minimum": -10_000, "maximum": 10_000,
                             "description": "Vertical pixels per tick. Try -600 to page down."],
                      "dx": ["type": "integer", "minimum": -10_000, "maximum": 10_000,
                             "description": "Horizontal pixels per tick."],
                      "ticks": ["type": "integer", "minimum": 1, "maximum": 100,
                                "description": "How many wheel ticks to send."],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["x", "y"]),

            tool("spaceo_move", """
                Move the pointer to a point without pressing anything. Use this to reveal \
                hover-only interface — menus that open on hover, tooltips, controls that fade \
                in — then call spaceo_read_screen again to see what appeared.
                """, ["x": ["type": "number", "description": "Window-relative x."],
                      "y": ["type": "number", "description": "Window-relative y."],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["x", "y"]),

            tool("spaceo_drag", """
                Press at one point, drag to another, and release. Use for sliders, reordering, \
                resizing, and selecting text by dragging across it.
                """, ["x": ["type": "number", "description": "Window-relative start x."],
                      "y": ["type": "number", "description": "Window-relative start y."],
                      "to_x": ["type": "number", "description": "Window-relative end x."],
                      "to_y": ["type": "number", "description": "Window-relative end y."],
                      "button": ["type": "string", "enum": ["left", "right", "middle"]],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["x", "y", "to_x", "to_y"]),

            tool("spaceo_type", """
                Type text into the session's focused window. Newlines are sent as Return. \
                Set web=true to type into a web page field rather than the browser's own UI.
                """, ["text": [
                          "type": "string",
                          "maxLength": 8_000,
                          "description": "The text to type.",
                      ],
                      "web": ["type": "boolean", "description": "Type into page content."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["text"]),

            tool("spaceo_press_key", """
                Press a key or combination, e.g. "cmd+s", "return", "tab", "esc", "cmd+shift+a".
                """, ["key": [
                          "type": "string",
                          "maxLength": 64,
                          "description": "Key combination.",
                      ],
                      "web": ["type": "boolean",
                              "description": "Send a supported key to page content."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["key"]),

            tool("spaceo_list_windows",
                 "List the session's windows with ids, sizes and whether they are in its tile.",
                 ["session": sessionArg]),

            tool("spaceo_verify_isolation", """
                Audit session health and report per-check attention-isolation coverage. A partial \
                verdict means no covered breach was found but a required route was unobservable.
                """, ["session": sessionArg]),

            tool("spaceo_pool_status",
                 "Show agent displays, how many sessions each holds, and spare capacity."),
        ]
    }

    private static func callTool(
        name: String,
        arguments: [String: Any],
        socketPath: String,
        controller: MCPControllerContext,
        id: Any?
    ) {
        let plan: MCPRequestPlan
        do {
            let translated = try toolRequest(
                name: name,
                arguments: arguments,
                defaultControllerOwner: controller.owner
            )
            plan = try controller.plan(translated)
        } catch {
            respond(result: toolError((error as? MCPInputError)?.description
                                      ?? error.localizedDescription), id: id)
            return
        }

        let request: Request
        switch plan {
        case .single(let single):
            request = single
        case .ownedSessionDestroy(let requests):
            let outcome = destroyOwnedSessions(
                requests, socketPath: socketPath, controller: controller)
            respond(result: outcome.failed
                    ? toolError(outcome.text)
                    : ["content": [["type": "text", "text": outcome.text]]],
                    id: id)
            return
        }

        let response: Response
        do {
            response = try Transport.send(request, to: socketPath, timeout: 120)
        } catch {
            respond(result: toolError("\(error)"), id: id)
            return
        }

        guard response.ok else {
            respond(result: toolError(renderFailure(response)), id: id)
            return
        }
        controller.record(response, for: request)

        // Screenshots come back as an image the model can actually look at. Only read the
        // exact UUID-named file this MCP process requested; a daemon response must never turn
        // into an arbitrary local-file read. Always remove the temporary file on every branch.
        if name == "spaceo_screenshot" {
            guard let expectedPath = request.output else {
                respond(result: toolError("screenshot request had no temporary output path"), id: id)
                return
            }
            defer { try? FileManager.default.removeItem(atPath: expectedPath) }
            let data: Data
            do {
                data = try screenshotData(
                    responsePath: response.path, expectedPath: expectedPath)
            } catch {
                respond(result: toolError("\(error)"), id: id)
                return
            }
            respond(result: [
                "content": [
                    ["type": "text", "text": response.message ?? "screenshot"],
                    ["type": "image",
                     "data": data.base64EncodedString(),
                     "mimeType": "image/png"],
                ],
            ], id: id)
            return
        }

        respond(result: ["content": [["type": "text", "text": render(response)]]], id: id)
    }

    /// Tear down exactly the sessions this connection leases, one authorized request each.
    ///
    /// Every session is attempted even after one fails, so a single stuck teardown cannot strand
    /// the rest, and the report names what survived. Internal so the multi-connection isolation
    /// test can drive this without stdio.
    static func destroyOwnedSessions(
        _ requests: [Request],
        socketPath: String,
        controller: MCPControllerContext,
        timeout: TimeInterval = 120
    ) -> (text: String, failed: Bool) {
        guard !requests.isEmpty else {
            return ("no sessions belong to this MCP connection; nothing to destroy. "
                    + "Sessions created by other agents are never destroyed by this tool.",
                    false)
        }

        var destroyed: [String] = []
        var failures: [String] = []
        for request in requests {
            let sessionID = request.session ?? "?"
            do {
                let response = try Transport.send(request, to: socketPath, timeout: timeout)
                guard response.ok else {
                    failures.append("\(sessionID): \(renderFailure(response))")
                    continue
                }
                controller.record(response, for: request)
                destroyed.append(sessionID)
            } catch {
                failures.append("\(sessionID): \(error)")
            }
        }

        var lines: [String] = []
        if !destroyed.isEmpty {
            lines.append("destroyed \(destroyed.count) session(s) owned by this MCP "
                         + "connection: \(destroyed.joined(separator: ", "))")
        }
        if !failures.isEmpty {
            lines.append("failed to destroy \(failures.count) session(s):")
            lines.append(contentsOf: failures.map { "  \($0)" })
        }
        return (lines.joined(separator: "\n"), !failures.isEmpty)
    }

    /// Read only the temporary PNG this MCP process asked the daemon to create.
    /// Internal so the no-arbitrary-file-read and allocation caps have non-GUI regression tests.
    static func screenshotData(responsePath: String?, expectedPath: String) throws -> Data {
        guard responsePath == expectedPath else {
            throw MCPInputError.invalid("daemon returned an unexpected screenshot path")
        }
        var info = stat()
        guard lstat(expectedPath, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              info.st_size <= 64 * 1_024 * 1_024 else {
            throw MCPInputError.invalid(
                "screenshot file is missing, not regular, empty, or larger than 64 MiB")
        }
        guard let data = FileManager.default.contents(atPath: expectedPath),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw MCPInputError.invalid("daemon did not produce a valid PNG screenshot")
        }
        return data
    }

    static func renderIsolation(_ report: IsolationReport) -> String {
        let summary: String
        switch report.verdict {
        case .intact:
            summary = "isolation: intact (every required check has usable coverage)"
        case .partial:
            summary = "isolation: partial "
                + "(no covered breach; required checks remain unknown)"
        case .breached:
            summary = "ISOLATION BREACH"
        }

        var lines = [summary]
        for check in report.checks {
            lines.append("- \(check.dimension.rawValue): \(check.status.rawValue) "
                + "[\(check.coverage.rawValue)] — \(check.evidence)")
            for failure in check.failures {
                lines.append("  failure: \(failure)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderLegacyIsolation(_ drift: [String]) -> String {
        drift.isEmpty
            ? "isolation: coverage unavailable (daemon returned no per-check report)"
            : "ISOLATION BREACH: " + drift.joined(separator: "; ")
    }

    /// The exact text placed in an MCP tool error. Kept internal so production failure rendering,
    /// including per-check coverage, is exercised without a socket or JSON-RPC process.
    static func renderFailure(_ response: Response) -> String {
        var error = response.error ?? "unknown failure"
        if let teardown = response.teardown,
           !error.contains(teardown.recoveryDescription) {
            error += "\n" + teardown.recoveryDescription
        }
        if let isolation = response.isolation {
            error += "\n" + renderIsolation(isolation)
        } else if let drift = response.drift {
            error += "\n" + renderLegacyIsolation(drift)
        }
        return error
    }

    /// Flatten a daemon response into something a model reads well.
    static func render(_ response: Response) -> String {
        var lines: [String] = []
        if let message = response.message { lines.append(message) }
        if let outline = response.outline { lines.append(outline) }

        if let session = response.session { lines.append(describe(session)) }
        if let sessions = response.sessions {
            if sessions.isEmpty { lines.append("no sessions") }
            for session in sessions { lines.append(describe(session)) }
        }

        if let windows = response.windows {
            if windows.isEmpty { lines.append("no windows yet") }
            for window in windows { lines.append(describe(window)) }
        }
        for display in response.displays ?? [] {
            lines.append("display \(display.displayID): \(display.used)/\(display.capacity) tiles used, "
                       + "\(whole(display.width))x\(whole(display.height))")
        }
        if let value = response.value, !value.isEmpty {
            lines.append("window text now: \(value.prefix(400))")
        }
        for finding in response.findings ?? [] { lines.append("issue: \(finding)") }

        if let isolation = response.isolation {
            lines.append(renderIsolation(isolation))
        } else if let drift = response.drift {
            lines.append(renderLegacyIsolation(drift))
        }
        // Ahead of ambient notes: an unconfirmed effect changes what the agent should do next,
        // where an ambient note is only context.
        for warning in response.warnings ?? [] { lines.append("UNCONFIRMED: \(warning)") }
        for change in response.ambient ?? [] { lines.append("note: \(change)") }
        return lines.isEmpty ? "ok" : lines.joined(separator: "\n")
    }

    private static func describe(_ session: SessionInfo) -> String {
        let tile = session.exclusiveDisplay
            ? "whole display \(session.displayID)"
            : "tile \(session.tileIndex + 1)/\(session.tileCapacity) of display \(session.displayID)"
        var text: String
        if session.runtimeAttached == false {
            text = "session '\(session.id)' [detached recovery record; no live display target]"
            if session.displayID != 0, session.width > 0, session.height > 0 {
                text += "\n  last-known placement only: \(tile), "
                    + "\(whole(session.width))x\(whole(session.height)) "
                    + "at (\(whole(session.x)),\(whole(session.y)))"
            }
        } else {
            text = "session '\(session.id)' on \(tile), "
                + "\(whole(session.width))x\(whole(session.height)) "
                + "at (\(whole(session.x)),\(whole(session.y)))"
        }
        let lifecycleStatus: String?
        if session.teardownPending {
            lifecycleStatus = "cleanup pending"
        } else if session.reclaimable == true {
            lifecycleStatus = "reclaimable"
        } else if session.abandoned == true {
            lifecycleStatus = "abandoned"
        } else if session.controllerOwner != nil {
            lifecycleStatus = "owned"
        } else {
            lifecycleStatus = nil
        }
        if let lifecycleStatus {
            text += "\n  lifecycle: \(lifecycleStatus)"
        }
        if let owner = session.controllerOwner {
            text += "\n  owner: \(owner.label) (\(owner.kind.rawValue), id \(owner.id))"
        }
        if let lastActivityAt = session.lastActivityAt {
            text += "\n  last activity: \(lastActivityAt.ISO8601Format())"
        }
        if let age = session.ageSeconds, age.isFinite {
            text += "\n  age: \(Int(max(0, age).rounded(.down)))s"
        }
        for blocker in session.recoveryBlockers ?? [] {
            text += "\n  recovery blocker \(blocker.code): \(blocker.message)"
        }
        for app in session.apps {
            let prefix = session.runtimeAttached == false ? "recorded app" : "app"
            text += "\n  \(prefix) \(app.name) (pid \(app.pid))"
                + "\(app.startedByUs ? "" : " [adopted]")"
        }
        for window in session.windows { text += "\n  " + describe(window) }
        return text
    }

    private static func describe(_ window: WindowInfo) -> String {
        "window \(window.windowID) \(whole(window.width))x\(whole(window.height))"
            + (window.title.isEmpty ? "" : " \"\(window.title)\"")
            + (window.onStage ? "" : "  [outside this session's tile]")
    }

    private static func whole(_ value: Double) -> String {
        guard value.isFinite,
              let integral = Int(exactly: value.rounded()) else {
            return "?"
        }
        return String(integral)
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    // MARK: - JSON-RPC framing

    private static func respond(result: [String: Any], id: Any?) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        payload["id"] = id ?? NSNull()
        emit(payload)
    }

    private static func respond(error code: Int, message: String, id: Any?) {
        var payload: [String: Any] = ["jsonrpc": "2.0",
                                      "error": ["code": code, "message": message]]
        payload["id"] = id ?? NSNull()
        emit(payload)
    }

    private static func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func validID(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull), !isJSONBoolean(value) else { return nil }
        if value is String || value is Int || value is Double { return value }
        return nil
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    enum MCPInputError: Error, CustomStringConvertible, LocalizedError {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message): return message
            }
        }

        var errorDescription: String? { description }
    }

    /// Translate and validate model-supplied tool arguments without any trapping numeric casts.
    /// Internal so the package tests can fuzz this boundary directly.
    static func toolRequest(
        name: String,
        arguments: [String: Any],
        defaultControllerOwner: DurableSessionOwner? = nil
    ) throws -> Request {
        let allowed: Set<String>
        switch name {
        case "spaceo_session_create":
            allowed = [
                "name", "controller_id", "controller_label", "controller_kind", "ttl_seconds",
            ]
        case "spaceo_session_heartbeat": allowed = ["session"]
        case "spaceo_session_list", "spaceo_pool_status": allowed = []
        case "spaceo_session_destroy": allowed = ["session", "all"]
        case "spaceo_open_app": allowed = ["session", "app", "files"]
        case "spaceo_read_screen": allowed = ["session", "window", "full"]
        case "spaceo_screenshot":
            allowed = ["session", "window", "full", "scale", "x", "y", "width", "height"]
        case "spaceo_click":
            allowed = [
                "session", "window", "element", "x", "y", "button", "count", "modifiers", "web",
            ]
        case "spaceo_scroll":
            allowed = ["session", "window", "x", "y", "dx", "dy", "ticks", "modifiers", "web"]
        case "spaceo_move":
            allowed = ["session", "window", "x", "y", "modifiers", "web"]
        case "spaceo_drag":
            allowed = [
                "session", "window", "x", "y", "to_x", "to_y", "button", "modifiers", "web",
            ]
        case "spaceo_type": allowed = ["session", "window", "text", "web"]
        case "spaceo_press_key": allowed = ["session", "window", "key", "web"]
        case "spaceo_list_windows", "spaceo_verify_isolation": allowed = ["session"]
        default: throw MCPInputError.invalid("unknown tool '\(name)'")
        }
        let unexpected = Set(arguments.keys).subtracting(allowed)
        guard unexpected.isEmpty else {
            throw MCPInputError.invalid(
                "unexpected argument(s): \(unexpected.sorted().joined(separator: ", "))")
        }

        func supplied(_ key: String) -> Any? {
            guard let value = arguments[key], !(value is NSNull) else { return nil }
            return value
        }
        func str(_ key: String, max: Int = 4_096, maxBytes: Int? = nil) throws -> String? {
            guard let value = supplied(key) else { return nil }
            guard let string = value as? String else {
                throw MCPInputError.invalid("'\(key)' must be a string")
            }
            let byteLimit = maxBytes ?? max * 4
            guard string.count <= max, string.utf8.count <= byteLimit else {
                throw MCPInputError.invalid(
                    "'\(key)' is too long (maximum \(max) characters and "
                    + "\(byteLimit) UTF-8 bytes)")
            }
            return string
        }
        func sessionID(_ key: String) throws -> String? {
            guard let rawValue = supplied(key) else { return nil }
            guard let value = rawValue as? String else {
                throw MCPInputError.invalid("'\(key)' must be a string")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("/"), !trimmed.contains("\\"),
                  value.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw MCPInputError.invalid(
                    "'\(key)' must not be empty or contain control characters "
                    + "or path separators")
            }
            return trimmed
        }
        func int(_ key: String) throws -> Int? {
            guard let value = supplied(key) else { return nil }
            guard !isJSONBoolean(value) else {
                throw MCPInputError.invalid("'\(key)' must be an integer")
            }
            if let integer = value as? Int { return integer }
            if let number = value as? NSNumber,
               let exact = Int(exactly: number.doubleValue) {
                return exact
            }
            throw MCPInputError.invalid("'\(key)' must be an integer")
        }
        func dbl(_ key: String) throws -> Double? {
            guard let value = supplied(key) else { return nil }
            guard !isJSONBoolean(value), let number = value as? NSNumber else {
                throw MCPInputError.invalid("'\(key)' must be a finite number")
            }
            let double = number.doubleValue
            guard double.isFinite else {
                throw MCPInputError.invalid("'\(key)' must be a finite number")
            }
            return double
        }
        func flag(_ key: String) throws -> Bool? {
            guard let value = supplied(key) else { return nil }
            guard isJSONBoolean(value), let boolean = value as? Bool else {
                throw MCPInputError.invalid("'\(key)' must be a boolean")
            }
            return boolean
        }
        func window() throws -> UInt32? {
            guard let raw = try int("window") else { return nil }
            guard raw > 0, let value = UInt32(exactly: raw) else {
                throw MCPInputError.invalid("'window' must be an integer from 1 through \(UInt32.max)")
            }
            return value
        }
        func validatePointerButton(_ raw: String?) throws {
            guard let raw else { return }
            guard ["left", "right", "middle"].contains(raw) else {
                throw MCPInputError.invalid("'button' must be 'left', 'right', or 'middle'")
            }
        }
        func modifiers() throws -> [String]? {
            guard let value = supplied("modifiers") else { return nil }
            guard let list = value as? [Any], list.count <= 5 else {
                throw MCPInputError.invalid(
                    "'modifiers' must be an array of at most 5 modifier names")
            }
            return try list.map { item in
                guard let name = item as? String, name.count <= 16 else {
                    throw MCPInputError.invalid(
                        "'modifiers' entries must be strings of at most 16 characters")
                }
                return name
            }
        }
        func int32(_ key: String) throws -> Int32? {
            guard let raw = try int(key) else { return nil }
            guard let value = Int32(exactly: raw) else {
                throw MCPInputError.invalid(
                    "'\(key)' must be an integer from -10000 through 10000")
            }
            return value
        }
        func files() throws -> [String]? {
            guard let value = supplied("files") else { return nil }
            guard let list = value as? [Any], list.count <= 256 else {
                throw MCPInputError.invalid("'files' must be an array of at most 256 paths")
            }
            return try list.map { item in
                guard let path = item as? String,
                      path.count <= 4_096,
                      path.utf8.count <= 16_384 else {
                    throw MCPInputError.invalid(
                        "every file path must be a string of at most 4096 characters "
                        + "and 16384 UTF-8 bytes")
                }
                return path
            }
        }
        func controllerText(_ key: String, fallback: String) throws -> String {
            let value = try str(key, max: 256, maxBytes: 256) ?? fallback
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value == trimmed, !trimmed.isEmpty,
                  value.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw MCPInputError.invalid(
                    "'\(key)' must be trimmed, non-empty, and contain no control characters")
            }
            return value
        }
        func controllerKind(
            _ key: String,
            fallback: DurableSessionOwnerKind
        ) throws -> DurableSessionOwnerKind {
            guard let raw = try str(key, max: 16, maxBytes: 16) else { return fallback }
            guard let kind = DurableSessionOwnerKind(rawValue: raw) else {
                throw MCPInputError.invalid(
                    "'\(key)' must be one of cli, mcp, viewer, or other")
            }
            return kind
        }

        var request = Request(cmd: "")
        request.session = try sessionID("session")
        request.window = try window()

        switch name {
        case "spaceo_session_create":
            request.cmd = "session.create"
            request.session = try sessionID("name")
            if let defaultControllerOwner {
                request.controllerOwner = DurableSessionOwner(
                    id: try controllerText(
                        "controller_id",
                        fallback: defaultControllerOwner.id
                    ),
                    kind: try controllerKind(
                        "controller_kind",
                        fallback: defaultControllerOwner.kind
                    ),
                    label: try controllerText(
                        "controller_label",
                        fallback: defaultControllerOwner.label
                    ),
                    processIdentity: defaultControllerOwner.processIdentity
                )
            } else if supplied("controller_id") != nil
                        || supplied("controller_label") != nil
                        || supplied("controller_kind") != nil {
                throw MCPInputError.invalid(
                    "controller identity overrides require an MCP controller context")
            }
            request.controllerTTLSeconds = try dbl("ttl_seconds")
            if let ttl = request.controllerTTLSeconds, !(30...3_600).contains(ttl) {
                throw MCPInputError.invalid(
                    "'ttl_seconds' must be from 30 through 3600")
            }
        case "spaceo_session_list":
            request.cmd = "session.list"
        case "spaceo_session_heartbeat":
            request.cmd = "session.heartbeat"
        case "spaceo_session_destroy":
            request.cmd = "session.destroy"
            request.full = try flag("all")
            if request.session != nil, request.full == true {
                throw MCPInputError.invalid("use either 'session' or 'all', not both")
            }
        case "spaceo_open_app":
            request.cmd = "run"
            request.app = try str("app")
            request.files = try files()
            guard let app = request.app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPInputError.invalid("'app' is required")
            }
        case "spaceo_read_screen":
            request.cmd = "ax"
            request.full = try flag("full")
        case "spaceo_screenshot":
            request.cmd = "screenshot"
            request.full = try flag("full")
            request.scale = try int("scale")
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.width = try int("width")
            request.height = try int("height")
            if let scale = request.scale, !(1...4).contains(scale) {
                throw MCPInputError.invalid("'scale' must be from 1 through 4")
            }
            let regionParts = [
                request.x != nil, request.y != nil,
                request.width != nil, request.height != nil,
            ].filter { $0 }.count
            guard regionParts == 0 || regionParts == 4 else {
                throw MCPInputError.invalid(
                    "a screenshot region needs 'x', 'y', 'width' and 'height' together")
            }
            if let width = request.width, width < 1 {
                throw MCPInputError.invalid("'width' must be at least 1")
            }
            if let height = request.height, height < 1 {
                throw MCPInputError.invalid("'height' must be at least 1")
            }
            request.output = NSTemporaryDirectory() + "spaceo-mcp-\(UUID().uuidString).png"
        case "spaceo_click":
            request.cmd = "click"
            request.element = try str("element", max: 32)
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.button = try str("button", max: 6)
            request.count = try int("count")
            request.modifiers = try modifiers()
            request.web = try flag("web")
            try validatePointerButton(request.button)
            if let count = request.count, !(1...3).contains(count) {
                throw MCPInputError.invalid("'count' must be from 1 through 3")
            }
            if request.element != nil && (request.x != nil || request.y != nil) {
                throw MCPInputError.invalid("use either 'element' or x/y coordinates, not both")
            }
            if (request.x == nil) != (request.y == nil) {
                throw MCPInputError.invalid("'x' and 'y' must be supplied together")
            }
            if request.element == nil && request.x == nil {
                throw MCPInputError.invalid("click needs either 'element' or x/y coordinates")
            }
            // An element reference performs an accessibility press, which carries no button,
            // click count, or modifier state. The daemon refuses this too; catching it here
            // saves a round trip and names the alternative while the model is still deciding.
            if request.element != nil {
                let pointerOnly = [
                    request.button != nil ? "button" : nil,
                    (request.count ?? 1) != 1 ? "count" : nil,
                    !(request.modifiers ?? []).isEmpty ? "modifiers" : nil,
                ].compactMap { $0 }
                guard pointerOnly.isEmpty else {
                    throw MCPInputError.invalid(
                        "'\(pointerOnly.joined(separator: "', '"))' cannot apply to an element "
                        + "reference, which performs an accessibility press. Read the element's "
                        + "coordinates from a screenshot and click with x/y instead.")
                }
            }
        case "spaceo_scroll", "spaceo_move", "spaceo_drag":
            request.cmd = String(name.dropFirst("spaceo_".count))
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.modifiers = try modifiers()
            request.web = try flag("web")
            guard request.x != nil, request.y != nil else {
                throw MCPInputError.invalid("'x' and 'y' are required")
            }
            if name == "spaceo_scroll" {
                request.dx = try int32("dx")
                request.dy = try int32("dy")
                request.ticks = try int("ticks")
                guard request.dx != nil || request.dy != nil else {
                    throw MCPInputError.invalid("scroll needs 'dx' or 'dy'")
                }
                if let ticks = request.ticks, !(1...100).contains(ticks) {
                    throw MCPInputError.invalid("'ticks' must be from 1 through 100")
                }
            }
            if name == "spaceo_drag" {
                request.toX = try dbl("to_x")
                request.toY = try dbl("to_y")
                request.button = try str("button", max: 6)
                try validatePointerButton(request.button)
                guard request.toX != nil, request.toY != nil else {
                    throw MCPInputError.invalid("'to_x' and 'to_y' are required")
                }
            }
        case "spaceo_type":
            request.cmd = "type"
            request.text = try str("text", max: 8_000, maxBytes: 32_000)
            request.web = try flag("web")
            guard let text = request.text else {
                throw MCPInputError.invalid("'text' is required")
            }
            guard text.unicodeScalars.count <= 8_000 else {
                throw MCPInputError.invalid(
                    "'text' is too long (maximum 8000 Unicode scalars)")
            }
        case "spaceo_press_key":
            request.cmd = "key"
            request.key = try str("key", max: 64, maxBytes: 256)
            request.web = try flag("web")
            guard let key = request.key, !key.isEmpty else {
                throw MCPInputError.invalid("'key' is required")
            }
        case "spaceo_list_windows":
            request.cmd = "windows"
        case "spaceo_verify_isolation":
            request.cmd = "verify"
        case "spaceo_pool_status":
            request.cmd = "pool"
        default:
            // Exhaustive validation above keeps this unreachable.
            throw MCPInputError.invalid("unknown tool '\(name)'")
        }
        return request
    }
}

/// Streaming, bounded newline reader for MCP stdio.
///
/// Foundation's global `readLine()` accumulates an arbitrarily large line. MCP arguments are
/// tiny by design, so accepting unbounded input only turns malformed clients into an OOM risk.
final class BoundedLineReader {
    enum ReaderError: Error, CustomStringConvertible, LocalizedError {
        case lineTooLong(Int)
        case invalidUTF8
        case io(Int32)

        var description: String {
            switch self {
            case .lineTooLong(let limit): return "line exceeds \(limit) bytes"
            case .invalidUTF8: return "input is not valid UTF-8"
            case .io(let code): return "input read failed with errno \(code)"
            }
        }

        var errorDescription: String? { description }
    }

    private let handle: FileHandle
    private let maximumBytes: Int
    private var buffer = Data()
    private var discardingOversizedLine = false

    init(handle: FileHandle, maximumBytes: Int = 1_048_576) {
        self.handle = handle
        self.maximumBytes = max(1, maximumBytes)
    }

    func next() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if discardingOversizedLine || line.count > maximumBytes {
                    discardingOversizedLine = false
                    throw ReaderError.lineTooLong(maximumBytes)
                }
                guard let text = String(data: line, encoding: .utf8) else {
                    throw ReaderError.invalidUTF8
                }
                return text
            }

            if buffer.count > maximumBytes {
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }

            // Read through the descriptor into a fixed-size chunk. `availableData` can return
            // an unbounded amount when stdin is a regular file, defeating the line-size cap
            // before `buffer` gets a chance to inspect it.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            var count: Int
            repeat {
                count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            } while count < 0 && errno == EINTR
            if count < 0 { throw ReaderError.io(errno) }
            guard count > 0 else {
                guard !buffer.isEmpty || discardingOversizedLine else { return nil }
                if discardingOversizedLine {
                    buffer.removeAll(keepingCapacity: false)
                    discardingOversizedLine = false
                    throw ReaderError.lineTooLong(maximumBytes)
                }
                let tail = buffer
                buffer.removeAll(keepingCapacity: false)
                guard let text = String(data: tail, encoding: .utf8) else {
                    throw ReaderError.invalidUTF8
                }
                return text
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
