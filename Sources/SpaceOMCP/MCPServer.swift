import Foundation
import Darwin
import SpaceOKit

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
            handle(message, socketPath: socketPath)
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
            if !process.isRunning { break }
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

    private static func handle(_ message: [String: Any], socketPath: String) {
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
                "serverInfo": ["name": "spaceo", "version": "1.0.0"],
                "instructions": """
                SpaceO gives each agent a virtual display and routes input without activating or \
                raising the agent's applications. Create a session before launching or driving \
                apps, prefer indexed accessibility elements over coordinates, and destroy the \
                session when work is complete. SpaceO isolates attention, not security: launched \
                apps and same-user clients retain the macOS user's file, network, app-session, \
                notification, and credential authority. Use a separate login session or VM for \
                untrusted agents or applications.
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
            callTool(name: name, arguments: arguments, socketPath: socketPath, id: id)

        default:
            respond(error: -32601, message: "unknown method '\(method)'", id: id)
        }
    }

    // MARK: - Tools

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static let sessionArg: [String: Any] = [
        "type": "string",
        "description": "Session id with no control characters or path separators. "
            + "Omit when only one session exists.",
    ]

    private static var toolSchemas: [[String: Any]] {
        let windowArg: [String: Any] = [
            "type": "integer",
            "minimum": 1,
            "maximum": UInt32.max,
            "description": "Window id; defaults to the session's main window.",
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
                opening any app.
                """, ["name": [
                    "type": "string",
                    "description": "Optional session id. Auto-generated when omitted.",
                ]]),

            tool("spaceo_session_list",
                 "List agent sessions with their displays, tiles, apps and windows."),

            tool("spaceo_session_destroy", """
                End a session: quit the apps it started and free its tile. Always do this when \
                you are finished, or the apps keep running invisibly.
                """, ["session": sessionArg,
                      "all": ["type": "boolean", "description": "Destroy every session."]]),

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
                need to see layout or images that the accessibility outline cannot convey.
                """, ["session": sessionArg,
                      "window": windowArg,
                      "full": ["type": "boolean", "description": "Capture the whole tile."]]),

            tool("spaceo_click", """
                Click an element by its reference from spaceo_read_screen (preferred — it cannot \
                miss), or by x/y coordinates relative to the window's top-left corner. \
                References look like "3" for an app control and "w3" for an element inside a \
                web page.
                """, ["element": ["type": "string", "maxLength": 32,
                                  "description": "Reference from spaceo_read_screen: \"3\" or \"w3\"."],
                      "x": ["type": "number", "description": "Window-relative x."],
                      "y": ["type": "number", "description": "Window-relative y."],
                      "button": ["type": "string", "enum": ["left", "right"]],
                      "count": ["type": "integer", "minimum": 1, "maximum": 3,
                                "description": "2 for a double-click."],
                      "session": sessionArg,
                      "window": windowArg]),

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
                Check that the session is healthy and has not disturbed the user: windows still \
                in their tile, apps alive, display intact.
                """, ["session": sessionArg]),

            tool("spaceo_pool_status",
                 "Show agent displays, how many sessions each holds, and spare capacity."),
        ]
    }

    private static func callTool(name: String, arguments: [String: Any],
                                 socketPath: String, id: Any?) {
        let request: Request
        do {
            request = try toolRequest(name: name, arguments: arguments)
        } catch {
            respond(result: toolError((error as? MCPInputError)?.description
                                      ?? error.localizedDescription), id: id)
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
            respond(result: toolError(response.error ?? "unknown failure"), id: id)
            return
        }

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

    /// Flatten a daemon response into something a model reads well.
    private static func render(_ response: Response) -> String {
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

        if let drift = response.drift {
            lines.append(drift.isEmpty
                ? "isolation intact — the user was not disturbed"
                : "ISOLATION BREACH: " + drift.joined(separator: "; "))
        }
        for change in response.ambient ?? [] { lines.append("note: \(change)") }
        return lines.isEmpty ? "ok" : lines.joined(separator: "\n")
    }

    private static func describe(_ session: SessionInfo) -> String {
        let tile = session.exclusiveDisplay
            ? "whole display \(session.displayID)"
            : "tile \(session.tileIndex + 1)/\(session.tileCapacity) of display \(session.displayID)"
        var text = "session '\(session.id)' on \(tile), "
                 + "\(whole(session.width))x\(whole(session.height)) "
                 + "at (\(whole(session.x)),\(whole(session.y)))"
        for app in session.apps {
            text += "\n  app \(app.name) (pid \(app.pid))\(app.startedByUs ? "" : " [adopted]")"
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
    static func toolRequest(name: String, arguments: [String: Any]) throws -> Request {
        let allowed: Set<String>
        switch name {
        case "spaceo_session_create": allowed = ["name"]
        case "spaceo_session_list", "spaceo_pool_status": allowed = []
        case "spaceo_session_destroy": allowed = ["session", "all"]
        case "spaceo_open_app": allowed = ["session", "app", "files"]
        case "spaceo_read_screen": allowed = ["session", "window", "full"]
        case "spaceo_screenshot": allowed = ["session", "window", "full"]
        case "spaceo_click":
            allowed = ["session", "window", "element", "x", "y", "button", "count"]
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

        var request = Request(cmd: "")
        request.session = try sessionID("session")
        request.window = try window()

        switch name {
        case "spaceo_session_create":
            request.cmd = "session.create"
            request.session = try sessionID("name")
        case "spaceo_session_list":
            request.cmd = "session.list"
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
            request.output = NSTemporaryDirectory() + "spaceo-mcp-\(UUID().uuidString).png"
        case "spaceo_click":
            request.cmd = "click"
            request.element = try str("element", max: 32)
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.button = try str("button", max: 5)
            request.count = try int("count")
            if let button = request.button, button != "left" && button != "right" {
                throw MCPInputError.invalid("'button' must be 'left' or 'right'")
            }
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
