import Foundation
import Darwin
import SpaceOKit

enum MCPControllerError: Error, CustomStringConvertible, LocalizedError {
    case missingLease(String)
    /// The call omitted `session` while this connection holds more than one lease.
    case ambiguousSession([String])

    var description: String {
        switch self {
        case .missingLease(let session):
            let target = session.isEmpty ? "the requested session" : "session '\(session)'"
            return "No controller lease is available for \(target). Create the session with "
                + "this MCP connection and keep using the same connection; lease credentials "
                + "are intentionally not recoverable from session.list."
        case .ambiguousSession(let sessions):
            let shown = sessions.prefix(8).map { MCPDiagnostic.name($0) }
            let more = sessions.count > shown.count ? " and \(sessions.count - shown.count) more" : ""
            return "this connection holds sessions \(shown.joined(separator: ", "))\(more); pass session"
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
final class MCPControllerContext: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    let owner: DurableSessionOwner
    let diagnosticRunID: String?
    let diagnosticMetrics: Bool
    /// Presentation state for this connection: seen display targets, snapshot bases, notes.
    let memory: MCPConnectionMemory
    /// Per-call agent journal (`spaceo logging enable`); nil outside the stdio server.
    let journal: MCPJournal?
    private var leases: [String: UUID] = [:]

    init(
        owner: DurableSessionOwner = MCPControllerContext.defaultOwner(),
        diagnosticRunID: String? = nil,
        diagnosticMetrics: Bool? = nil,
        memory: MCPConnectionMemory = MCPConnectionMemory(),
        journal: MCPJournal? = nil
    ) {
        self.owner = owner
        self.memory = memory
        self.journal = journal
        self.diagnosticRunID = diagnosticRunID
            ?? MCPControllerContext.environmentRunID()
        self.diagnosticMetrics = diagnosticMetrics
            ?? (ProcessInfo.processInfo.environment["SPACEO_LOG_METRICS"] == "1")
    }

    private static func environmentRunID() -> String? {
        guard let value = ProcessInfo.processInfo.environment["SPACEO_RUN_ID"] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return String(trimmed.prefix(128))
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
        lock.lock()
        defer { lock.unlock() }
        guard supplied.cmd == "session.destroy", supplied.full == true else {
            return .single(try prepare(supplied))
        }
        return .ownedSessionDestroy(try leases.keys.sorted().map { sessionID in
            var request = supplied
            request.full = nil
            request.session = sessionID
            request.controllerLeaseID = leases[sessionID]
            return try prepare(request)
        })
    }

    func prepare(_ supplied: Request) throws -> Request {
        lock.lock()
        defer { lock.unlock() }
        var request = supplied
        // Attach non-secret controller identity to every request so daemon telemetry can group a
        // whole MCP run rather than only its create/list calls. Authorization still uses the
        // connection-local lease; this metadata grants nothing.
        if request.controllerOwner == nil { request.controllerOwner = owner }
        if request.diagnosticRunID == nil { request.diagnosticRunID = diagnosticRunID }
        if request.diagnosticMetrics == nil { request.diagnosticMetrics = diagnosticMetrics }
        // "My session": the daemon resolves an omitted session against every session on the
        // machine, so another agent's session made omission fail. Resolve it here against the
        // sessions this connection leases instead, and refuse to guess between several.
        if request.session == nil, request.full != true, Self.isSessionAddressed(request.cmd) {
            if leases.count == 1 {
                request.session = leases.keys.first
            } else if leases.count > 1 {
                throw MCPControllerError.ambiguousSession(leases.keys.sorted())
            }
        }
        switch request.cmd {
        case "session.create":
            if request.controllerLeaseID == nil {
                request.controllerLeaseID = UUID()
            }
        case let command where DaemonCommand.ownerScopedMutations.contains(command)
            || DaemonCommand.ownerScopedReads.contains(command):
            // Reads of a session's windows, AX tree, pixels, or audit are fenced exactly like
            // mutations: this connection can only see the sessions it holds leases for.
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
        case "session.list":
            // Declaring the owner keeps this connection's own sessions unredacted in the
            // shared inventory; other controllers' app/window detail stays redacted.
            request.controllerOwner = owner
        default:
            break
        }
        return request
    }

    /// Commands that act on one session and therefore take the implicit connection session.
    static func isSessionAddressed(_ command: String) -> Bool {
        command == "session.destroy"
            || DaemonCommand.ownerScopedMutations.contains(command)
            || DaemonCommand.ownerScopedReads.contains(command)
    }

    /// Error codes proving a session this connection leased no longer exists as a live session.
    static let endedSessionCodes: Set<String> = ["unknown_session", "session_detached"]

    func record(_ response: Response, for request: Request) {
        lock.lock()
        defer { lock.unlock() }
        if !response.ok, let code = response.errorCode, Self.endedSessionCodes.contains(code),
           request.cmd != "session.create",
           let sessionID = request.session, leases[sessionID] != nil {
            // Keeping the lease would aim every later implicit call at a session that is gone.
            leases.removeValue(forKey: sessionID)
            memory.forget(session: sessionID)
            return
        }
        // Create-and-open can create a session successfully and then fail its launch. The
        // returned session and lease remain authoritative recovery state in that response.
        guard response.ok || (DaemonCommand.leaseIssuing.contains(request.cmd)
                              && response.session != nil && response.controllerLeaseID != nil) else { return }
        switch request.cmd {
        case "session.create", "session.claim", "session.heartbeat":
            if request.cmd == "session.heartbeat", let id = request.session,
               let credential = request.controllerLeaseID, leases[id] != credential { return }
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
                memory.forget(session: sessionID)
            } else if leases.count == 1, let sessionID = leases.keys.first {
                leases.removeValue(forKey: sessionID)
                memory.forget(session: sessionID)
            }
        default:
            break
        }
    }

    /// Background renewal found a session gone: drop its lease and tell the agent on its next
    /// tool result, since nothing else would until one of its calls failed.
    func recordRenewal(_ response: Response, for request: Request) {
        guard !response.ok, let code = response.errorCode, Self.endedSessionCodes.contains(code),
              let sessionID = request.session else {
            record(response, for: request)
            return
        }
        lock.lock()
        let held = leases[sessionID] != nil && leases[sessionID] == request.controllerLeaseID
        if held {
            leases.removeValue(forKey: sessionID)
            memory.forget(session: sessionID)
        }
        lock.unlock()
        guard held else { return }
        let detail = (response.error ?? code).split(separator: "\n").first.map(String.init) ?? code
        let reason = code == "unknown_session"
            ? "the daemon no longer has it"
            : MCPDiagnostic.preview(detail, maximumBytes: 200)
        memory.queueNote("NOTE: session '\(MCPDiagnostic.name(sessionID))' ended (\(reason)); "
                         + "create a new session with spaceo_session_create")
    }

    /// The daemon restarted: none of this connection's leases can authorize anything any more.
    func dropAllLeases() {
        lock.lock()
        defer { lock.unlock() }
        leases.removeAll()
        memory.forgetAllSessions()
    }

    /// Session ids this connection holds a lease for.
    var ownedSessions: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(leases.keys)
    }

    func storedLease(for sessionID: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return leases[sessionID]
    }

    func renewalRequests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return leases.keys.sorted().map { id in
            var request = Request(cmd: "session.heartbeat")
            request.session = id
            request.controllerLeaseID = leases[id]
            return request
        }
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

    /// An MCP client restart ends this stdio process and abandons its sessions. Two minutes is
    /// enough for a restarted conversation to call `spaceo_session_claim`; the daemon's own
    /// default (30 s) stays unchanged for other clients.
    static let defaultOrphanGraceSeconds: Double = 120

    public static func run(socketPath: String) -> Never {
        // macOS attributes TCC grants to the responsible app, not to this binary. Saying which
        // app that is, in the client's own log, is the difference between "grant Accessibility"
        // and knowing where to click.
        let attribution = ResponsibleProcess.describeCurrent()
        SpaceOError.setResponsibleProcessAttribution(attribution)
        if let attribution { note("caller attributed to: \(attribution)") }
        let drift = ensureDaemon(socketPath: socketPath)
        note("server.started pid=\(getpid()) version=\(SpaceOVersion.current)")
        let input = BoundedLineReader(handle: .standardInput)
        let controller = MCPControllerContext(journal: MCPJournal())
        // stderr reaches a person only if they read the client's logs; the agent needs to know
        // too, because the symptoms (unknown commands, missing fields) look like its own mistakes.
        controller.memory.setDaemonDrift(drift)
        let renewal = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "spaceo.mcp.renewal"))
        renewal.schedule(deadline: .now() + 10, repeating: 10)
        renewal.setEventHandler {
            for request in controller.renewalRequests() {
                if let response = try? Transport.send(request, to: socketPath, timeout: 2) {
                    controller.recordRenewal(response, for: request)
                }
            }
        }
        renewal.resume()

        while true {
            // Foundation JSON parsing/encoding bridges through autoreleased objects. Drain
            // after each message, including refusals, before blocking for the next request.
            autoreleasepool {
                let line: MCPInputLine
                switch nextInput(from: input) {
                case .line(let value):
                    line = value
                case .endOfInput:
                    controller.journal?.connectionEnded(reason: "eof")
                    exit(0)
                case .recoverable(let error):
                    controller.journal?.method("parse_error", ok: false, detail: "\(error)")
                    respond(error: -32700, message: "parse error: \(error)", id: nil)
                    return
                case .fatal(let error):
                    // stdout carries JSON-RPC only, and a dead descriptor means the peer is gone
                    // anyway. Announcing this on stdout instead would be the loop that never ends.
                    note("stdin unreadable, exiting: \(error)")
                    controller.journal?.connectionEnded(reason: "stdin_unreadable")
                    exit(1)
                }
                let decoded: Any
                do {
                    guard let value = try line.jsonObject() else { return }
                    decoded = value
                } catch {
                    respond(error: -32700, message: "parse error", id: nil)
                    return
                }
                guard let message = decoded as? [String: Any] else {
                    respond(error: -32600, message: "invalid request", id: nil)
                    return
                }
                handle(message, socketPath: socketPath, controller: controller)
            }
        }
    }

    /// What the run loop should do with one read of stdin.
    enum InputOutcome {
        case line(MCPInputLine)
        case endOfInput
        /// One unusable line. The peer can send another, so the loop reports and continues.
        case recoverable(Error)
        /// The descriptor itself failed. Every retry fails the same way, so the loop stops
        /// rather than spinning at 100% CPU while flooding the peer with parse errors.
        case fatal(Error)
    }

    static func nextInput(from reader: BoundedLineReader) -> InputOutcome {
        do {
            guard let line = try reader.nextInputLine() else { return .endOfInput }
            return .line(line)
        } catch let error as BoundedLineReader.ReaderError where !error.isFatal {
            return .recoverable(error)
        } catch {
            // Anything unrecognized is treated as fatal: exiting on a recoverable error costs
            // one restart, while retrying an unrecoverable one costs a spinning core forever.
            return .fatal(error)
        }
    }

    // MARK: - Daemon lifecycle

    /// Make sure a daemon answers at `socketPath`. Returns the agent-facing drift warning when
    /// the daemon that answered is a different build from this MCP server.
    @discardableResult
    private static func ensureDaemon(socketPath: String) -> String? {
        if let response = Transport.pingResponse(socketPath), response.ok {
            return reportDaemonProvenance(response.daemon)
        }
        // A launchd-supervised daemon (SPAO-206) has a stable TCC identity precisely because
        // no client spawns it. Spawning one here would race launchd and inherit *this*
        // client's grants, which is the failure mode the LaunchAgent exists to end.
        let supervision = LaunchAgentInstaller.status()
        if supervision.installed {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if Transport.ping(socketPath) {
                    return reportDaemonProvenance(Transport.pingResponse(socketPath)?.daemon)
                }
                usleep(200_000)
            }
            note("the SpaceO LaunchAgent (\(LaunchAgentInstaller.label)) is installed but no daemon "
                 + "answered at \(socketPath) within 10s; check `spaceo daemon status` and "
                 + "`launchctl print gui/\(getuid())/\(LaunchAgentInstaller.label)`. Not spawning a "
                 + "client-owned daemon, because it would carry this client's grants instead of SpaceO's.")
            return nil
        }

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
            return nil
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if Transport.ping(socketPath) {
                try? diagnostics?.close()
                note("started SpaceO daemon on \(socketPath)")
                return reportDaemonProvenance(Transport.pingResponse(socketPath)?.daemon)
            }
            // Stop polling as soon as the child is gone and nothing could answer at the path:
            // either nothing is there, or what is there is a stale non-socket the daemon has
            // just refused to replace. Waiting the full deadline in the latter case only
            // delays the diagnostic that names the file.
            if !process.isRunning, !isSocket(socketPath) {
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
        return nil
    }

    private static func isSocket(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFSOCK
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

    /// Log daemon provenance to stderr and return the agent-facing warning when the daemon is
    /// provably a different build. An unknown comparison is logged but not shown to the agent:
    /// it cannot act on "maybe".
    private static func reportDaemonProvenance(_ daemon: DaemonRuntimeInfo?) -> String? {
        guard let daemon else {
            note("warning: running daemon does not report executable provenance; restart it "
                 + "before testing or after an upgrade")
            return nil
        }
        let drift = MCPPresentation.daemonDriftWarning(
            daemonVersion: daemon.version, daemonPID: daemon.pid, clientVersion: SpaceOVersion.current)
        if let clientBuildUUID = RuntimeIdentity.currentExecutableBuildUUID(),
           let daemonBuildUUID = daemon.executableBuildUUID {
            if clientBuildUUID != daemonBuildUUID {
                note("warning: running daemon pid=\(daemon.pid) uses a different executable "
                     + "build; restart it before testing or relying on new behavior")
                return drift
            }
            return nil
        }
        guard let daemonSHA = daemon.executableSHA256,
              let clientSHA = RuntimeIdentity.currentExecutableSHA256() else {
            note("warning: could not compare MCP and daemon executable fingerprints")
            return daemon.version != SpaceOVersion.current ? drift : nil
        }
        if clientSHA != daemonSHA {
            note("warning: running daemon pid=\(daemon.pid) uses a different executable image; "
                 + "restart it before testing or relying on new behavior")
            return drift
        }
        return nil
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
            let clientInfo = params["clientInfo"] as? [String: Any]
            controller.journal?.connectionStarted(
                clientName: clientInfo?["name"] as? String,
                clientVersion: clientInfo?["version"] as? String,
                protocolVersion: version)
            respond(result: [
                "protocolVersion": version,
                "capabilities": [
                    "tools": [:] as [String: Any],
                    "prompts": [:] as [String: Any],
                    "resources": [:] as [String: Any],
                ],
                "serverInfo": ["name": "spaceo", "version": SpaceOVersion.current],
                "instructions": """
                SpaceO gives each agent a virtual display and routes input without activating or \
                raising the agent's applications. Create a session before launching or driving \
                apps, and destroy the session when work is complete. Tools that omit session use \
                the session this connection created, and its lease renews automatically.

                Receipts are compact: an action leads with its outcome (confirmed, unconfirmed, \
                refused) and an intact isolation check is one line. Pass verbose: true for every \
                field. After a successful native action the result ends with "after action:" and \
                the changed elements with fresh indices (observe: diff, the default), so you can \
                act again without re-reading the screen.

                Addressing: prefer indexed accessibility elements from spaceo_read_screen over \
                coordinates — an index cannot miss and survives the window moving. Use \
                coordinates when you need something an accessibility press cannot express: a \
                right-click, a double-click, a modifier-held click, a drag, or a point with no \
                accessibility element at all. All coordinates are window-local points, and \
                spaceo_screenshot at the default scale=1 returns one pixel per point, so a \
                coordinate read off a window capture is a coordinate you can click. A tile or \
                region capture (full=true, or x/y/width/height) is measured from the capture's \
                own global origin instead, so follow the conversion in the returned image \
                geometry — add its originX/originY, then subtract the target window's x/y from \
                spaceo_list_windows.

                Reaching content: spaceo_read_screen only describes what is currently on screen. \
                Use spaceo_scroll to bring anything below the fold into view, and spaceo_move to \
                reveal hover-only menus and tooltips, then read the screen again. Every read ends \
                with an "elements: N shown, truncated: …" footer; when truncated is true, use \
                spaceo_find for a specific control instead of trusting the partial list. Pass \
                since=<snapshot id> to receive only what changed. Wait with spaceo_wait_for instead \
                of polling screenshots; read documents with spaceo_read_text instead of \
                screenshots. Errors carry a JSON "recovery" object naming the exact tool to call \
                next. A "HUMAN HANDOFF:" line means the operator drove the session; re-read the \
                screen before acting. The playbook is available as prompts (drive-app, drive-web, \
                hand-off-to-human) and resources (spaceo://docs/…).

                SpaceO isolates attention, not security: launched apps and same-user clients \
                retain the macOS user's file, network, app-session, notification, and credential \
                authority. Use a separate login session or VM for untrusted agents or \
                applications.
                """,
            ], id: id)

        case "ping":
            respond(result: [:], id: id)

        case "tools/list":
            controller.journal?.method("tools/list", ok: true, detail: "\(toolSchemas.count) tools")
            respond(result: ["tools": toolSchemas], id: id)

        case "prompts/list":
            respond(result: ["prompts": Playbook.prompts.map { prompt -> [String: Any] in
                [
                    "name": prompt.name,
                    "description": prompt.description,
                    "arguments": prompt.arguments.map { argument -> [String: Any] in
                        ["name": argument.name, "description": promptArgumentDescription(argument.description), "required": argument.required]
                    },
                ]
            }], id: id)

        case "prompts/get":
            controller.journal?.method("prompts/get", ok: true, detail: params["name"] as? String)
            do {
                respond(result: try promptResult(params), id: id)
            } catch {
                respond(error: -32602, message: String(describing: error), id: id)
            }

        case "resources/list":
            var resources: [[String: Any]] = Playbook.documents.map { document in
                ["uri": document.uri, "name": document.name, "title": document.title,
                 "description": "SpaceO playbook: \(document.title)", "mimeType": "text/markdown"]
            }
            resources.append(["uri": "spaceo://schema", "name": "schema", "title": "Tool schemas",
                              "description": "The exact tools/list payload as JSON.", "mimeType": "application/json"])
            resources.append(["uri": "spaceo://doctor", "name": "doctor", "title": "Live daemon health",
                              "description": "Redacted daemon health: version, grants, attribution, draining state.",
                              "mimeType": "application/json"])
            respond(result: ["resources": resources], id: id)

        case "resources/read":
            controller.journal?.method("resources/read", ok: true, detail: params["uri"] as? String)
            guard let uri = params["uri"] as? String, uri.utf8.count <= 512 else {
                respond(error: -32602, message: "resources/read needs a uri", id: id)
                return
            }
            if let document = Playbook.documents.first(where: { $0.uri == uri }) {
                respond(result: ["contents": [["uri": uri, "mimeType": "text/markdown", "text": document.markdown]]], id: id)
            } else if uri == "spaceo://schema" {
                guard let text = toolSchemaResourceText else {
                    respond(error: -32603, message: "tool schemas could not be encoded", id: id)
                    return
                }
                respond(result: ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]], id: id)
            } else if uri == "spaceo://doctor" {
                respond(result: ["contents": [["uri": uri, "mimeType": "application/json", "text": doctorResource(socketPath: socketPath)]]], id: id)
            } else {
                respond(error: -32602, message: "unknown resource '\(MCPDiagnostic.name(uri))'", id: id)
            }

        case "tools/call":
            guard let name = params["name"] as? String else {
                respond(error: -32602, message: "tools/call needs a name", id: id)
                return
            }
            let arguments: [String: Any]
            if let supplied = params["arguments"] {
                guard let object = supplied as? [String: Any] else {
                    respond(result: toolError("tool arguments must be an object", tool: name), id: id)
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
            respond(error: -32601, message: "unknown method '\(MCPDiagnostic.name(method))'", id: id)
        }
    }

    // MARK: - Tools

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static var sessionArg: [String: Any] {
        [
            "type": "string",
            "description": "Omit to use the session this connection created.",
        ]
    }

    // The catalogue is independent of daemon/session state. Share its immutable values across
    // discovery requests instead of rebuilding the nested dictionaries for every caller.
    //
    // Every byte here is paid by every agent on every connection, so descriptions stay under
    // 400 characters and say what a tool is for; budgets, queues and late-frame mechanics live in
    // the spaceo://docs resources. MCPCompactReceiptTests enforces the size.
    static let toolSchemas: [[String: Any]] = {
        let windowArg: [String: Any] = [
            "type": "integer",
            "minimum": 1,
            "maximum": UInt32.max,
            "description": "Window id; omit for the [default] window.",
        ]

        let webPointArg: [String: Any] = [
            "type": "boolean",
            "description": "x/y are CSS viewport coordinates (as beside wN).",
        ]

        let modifiersArg: [String: Any] = [
            "type": "array",
            "maxItems": 5,
            "items": ["type": "string", "enum": ["cmd", "shift", "alt", "ctrl", "fn"]],
            "description": "Keys held during the action.",
        ]

        let buttonArg: [String: Any] = [
            "type": "string", "enum": ["left", "right", "middle"],
            "description": "Mouse button (default left).",
        ]

        func tool(_ name: String, _ description: String,
                  _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var enrichedProperties = properties
            for field in (Self.reviewFields[name] ?? []).subtracting(Self.unadvertisedFields(for: name)) {
                enrichedProperties[field] = Self.reviewFieldSchema(field)
            }
            for field in Self.presentationFields(for: name).subtracting(Self.unadvertisedFields(for: name)) {
                enrichedProperties[field] = Self.presentationFieldSchema(field)
            }
            var schema: [String: Any] = [
                "type": "object",
                "properties": enrichedProperties,
                "additionalProperties": false,
            ]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema]
        }

        return [
            tool("spaceo_place_window", "Place an owned window using preserve, fit or cover policy. Cover requires an exclusive display.", [
                "session": sessionArg, "window": windowArg,
                "placement": ["type": "string", "enum": ["preserve", "fit", "cover"],
                              "description": "preserve keeps the frame, fit shrinks into the tile, cover fills an exclusive display."]],
                 required: ["window", "placement"]),
            tool("spaceo_adopt_app", "Adopt this exact running process into the session (no bundle-wide matching).", [
                "session": sessionArg,
                "pid": ["type": "integer", "minimum": 1, "description": "Process id of the running app."]], required: ["pid"]),
            tool("spaceo_session_pause", """
                Park this session and refuse agent input. Give a reason when you need a person \
                ("needs 2FA code"); the Viewer shows it with a Take Control button.
                """, ["session": sessionArg,
                      "reason": ["type": "string", "maxLength": 240, "description": "Why the agent stopped; shown to the human."]]),
            tool("spaceo_session_resume", "Lift a pause you set with spaceo_session_pause. An operator pause is released only by the operator.",
                 ["session": sessionArg]),
            tool("spaceo_session_create", """
                Create an agent session (a tile on a SpaceO virtual display) once, before opening \
                apps. This connection keeps its lease secret and renewed; tools that omit session \
                use it.
                """, [
                    "name": ["type": "string", "description": "Session id; generated when omitted."],
                    "ttl_seconds": ["type": "number", "minimum": 30, "maximum": 3_600,
                                    "description": "Lease lifetime; renewed automatically while connected."],
                    "app": ["type": "string", "maxLength": 4_096,
                            "description": "Also launch this app (as spaceo_open_app)."],
                    "files": ["type": "array", "maxItems": 256, "items": ["type": "string", "maxLength": 4_096],
                              "description": "Files for the launched app to open."],
                    "preset": ["type": "string", "enum": ["shared", "exclusive", "exclusive_1080p", "exclusive_1440p"],
                               "description": "shared (default) takes a tile; exclusive* a whole display."],
                    "title": ["type": "string", "maxLength": 120,
                              "description": "Task title shown in the Viewer."],
                    "record": ["type": "string", "enum": ["actions", "actions+frames"],
                               "description": "Record receipts; +frames adds images that may show typed text."],
                    "mute_audio": ["type": "boolean", "description": "Launch a managed Chromium muted."],
                    "orphan_grace_seconds": ["type": "number", "minimum": 30, "maximum": 1_800,
                                             "description": "If this connection ends, seconds the session keeps its apps for spaceo_session_claim. Default 120."],
                ]),

            tool("spaceo_session_claim", """
                Take over an abandoned session (its controller exited, e.g. your own before this \
                client restarted), keeping its apps and windows. Works only within its grace \
                period; a live session is refused with who holds it. This connection keeps the \
                new lease. Leases coordinate agents; they are not a security boundary. Re-read \
                the screen after claiming.
                """, ["session": ["type": "string", "description": "The session id to claim, e.g. from spaceo_session_list."]],
                required: ["session"]),

            tool("spaceo_session_list",
                 "List agent sessions with displays, tiles, apps and windows. [yours] marks sessions this connection created; other controllers' contents are redacted."),

            tool("spaceo_session_heartbeat",
                 "Renew the lease without acting. Rarely needed: leases renew every 10 s while connected.",
                 ["session": sessionArg]),

            tool("spaceo_session_destroy", """
                End a session: quit its apps and free its tile. Always do this when finished. If \
                cleanup reports survivors, resolve them and call again (safe). Only ends sessions \
                this connection created.
                """, ["session": sessionArg,
                      "all": ["type": "boolean",
                              "description": "Destroy every session this connection created; other agents' are untouched."]]),

            tool("spaceo_open_app", """
                Launch an app (name, bundle id or path, plus optional files) into the session's \
                tile without activating it. Reuses the session's running instance unless \
                new_instance=true. Web pages: spaceo_open_url.
                """, ["app": ["type": "string", "maxLength": 4_096, "description": "App name, bundle id, or .app path."],
                      "files": ["type": "array", "maxItems": 256, "items": ["type": "string", "maxLength": 4_096],
                                "description": "File paths to open."],
                      "new_instance": ["type": "boolean", "description": "Launch even if the session already runs this app."],
                      "mute_audio": ["type": "boolean", "description": "Managed Chromium only: launch muted."],
                      "session": sessionArg],
                 required: ["app"]),

            tool("spaceo_open_url", """
                Open a URL in the session's managed Chromium (launched if needed) via DevTools, \
                wait for the load, and bind web reads and actions to that page. Returns title, \
                final_url, target_id and load. Don't type into the address bar instead.
                """, ["url": ["type": "string", "maxLength": 8_192, "description": "http(s) URL to open."],
                      "new_tab": ["type": "boolean", "description": "Open in a new tab instead of navigating the bound page."],
                      "timeout": ["type": "number", "minimum": 0.5, "maximum": 60, "description": "Load wait in seconds; a timeout is reported, not an error."],
                      "mute_audio": ["type": "boolean", "description": "If a browser must be launched, mute it."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["url"]),

            tool("spaceo_wait_for", """
                Wait (up to 60 s) for a condition instead of polling: element_label, element_gone, \
                window_title_contains, web_selector, web_title_contains, stable_ms (pixels still \
                for N ms), ms, or session_resumed (a human's pause is lifted; works while paused, \
                returns their note). Labels match the accessible name. Returns what it saw \
                (index, title, snapshot id). A timeout is a normal outcome.
                """, ["condition": ["type": "string", "enum": WaitCondition.knownKinds,
                                    "description": "What to wait for."],
                      "value": ["type": "string", "maxLength": 480, "description": "The label, title fragment, selector, or millisecond count. Omit for session_resumed."],
                      "match": ["type": "string", "enum": ["exact", "contains"], "description": "Label matching: exact (default) or contains."],
                      "role": ["type": "string", "maxLength": 64, "description": "Only elements of this role, e.g. TextField."],
                      "timeout": ["type": "number", "minimum": 0.5, "maximum": 60, "description": "Budget in seconds, queueing included (default 15)."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["condition"]),

            tool("spaceo_menu", """
                Use the menu bar of the session's app without activating it. No path lists the \
                top-level menus; a path such as ["File"] lists that menu (title, enabled, checked, \
                shortcut, submenu); press=true runs the item a full path names. The Apple and \
                Services menus are never available. Pressing is input and may open windows.
                """, ["path": ["type": "array", "maxItems": 6,
                               "items": ["type": "string", "maxLength": 256],
                               "description": "Menu titles from the top level down, e.g. [\"File\", \"Export as PDF…\"]."],
                      "press": ["type": "boolean", "description": "Press the item the path names."],
                      "pid": ["type": "integer", "minimum": 1, "maximum": Int32.max, "description": "Which of the session's apps; default: the app owning the default window."],
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_find", """
                Search the window's accessibility tree (and a managed browser's page) for \
                elements whose label, value or role contains query. Returns up to 25 native and \
                25 page hits with usable indices. A truncated search cannot prove absence.
                """, ["query": ["type": "string", "maxLength": 480, "description": "Case-insensitive text to find."],
                      "role": ["type": "string", "maxLength": 64, "description": "Native role filter, e.g. Button; skips page search."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["query"]),

            tool("spaceo_read_text", """
                Read the window's text in reading order (document, terminal, web article) plus \
                the current selection, without a screenshot; element reads one element's value. \
                Reports truncated and source.
                """, ["element": ["type": "string", "maxLength": 32, "description": "Native element index from spaceo_read_screen."],
                      "max_chars": ["type": "integer", "minimum": 1, "maximum": 20_000, "description": "Character limit (default 20000)."],
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_run_steps", """
                Run up to 16 steps (click, type, press_key, scroll, move, drag, wait_for, find) \
                in one round trip. Returns per-step receipts and the first failure. 60 s budget. \
                After a failure, re-read; never replay completed steps.
                """, ["steps": ["type": "array", "minItems": 1, "maxItems": 16,
                                "description": "Steps as {tool: \"spaceo_click\", arguments: {...}}.",
                                "items": ["type": "object", "additionalProperties": false,
                                          "properties": ["tool": ["type": "string", "maxLength": 64],
                                                         "arguments": ["type": "object"]],
                                          "required": ["tool"]]],
                      "stop_on_failure": ["type": "boolean", "description": "Skip later steps after a failure (default true)."],
                      "session": sessionArg],
                 required: ["steps"]),

            tool("spaceo_clipboard_set", """
                Put text on the session's private clipboard (up to 1 MiB). spaceo_press_key \
                "cmd+v" then pastes it via DevTools for web content or typing for native apps. \
                The user's pasteboard is never read or written.
                """, ["text": ["type": "string", "maxLength": 1_048_576, "description": "Text to store."], "session": sessionArg],
                 required: ["text"]),

            tool("spaceo_clipboard_get", """
                Read the session's private clipboard. spaceo_press_key "cmd+c" / "cmd+x" copies \
                the current selection into it.
                """, ["session": sessionArg]),

            tool("spaceo_session_set_title", """
                Name the task this session is doing ("Booking flight to SFO") so the human can \
                tell sessions apart in the Viewer.
                """, ["title": ["type": "string", "maxLength": 120, "description": "Short task title."], "session": sessionArg],
                 required: ["title"]),

            tool("spaceo_events", """
                Daemon events after since_seq (sessions, apps, agent actions, pauses, isolation \
                verdicts). Other controllers' detail is redacted. On resync_required call \
                spaceo_session_list once, then keep passing next_seq back.
                """, ["since_seq": ["type": "integer", "minimum": 0, "description": "Return events strictly after this; pass next_seq back unchanged."]]),

            tool("spaceo_read_screen", """
                Read the window as indexed actionable elements ("[3] Button — Save"): cheaper and \
                more reliable than a screenshot; actions take these indices. since=<snapshot id> \
                returns only changes. If the footer says truncated, use spaceo_find or scroll.
                """, ["session": sessionArg,
                      "window": windowArg,
                      "since": ["type": "string", "maxLength": 128,
                                "description": "Snapshot id from a previous read; return only the differences."],
                      "full": ["type": "boolean",
                               "description": "Include non-actionable elements too. Verbose."]]),

            tool("spaceo_list_targets", """
                List the Chromium page targets of the selected browser window; * marks where web \
                reads and actions go. Use after opening or closing a tab, and before attaching.
                """, ["session": sessionArg, "window": windowArg]),

            tool("spaceo_attach_target", """
                Bind the browser window's web reads and actions to one target id from \
                spaceo_list_targets. The binding is verified before every action and fails \
                closed if the page is closed or replaced.
                """, [
                    "target": ["type": "string", "maxLength": 256, "description": "Exact target id from spaceo_list_targets."],
                    "session": sessionArg,
                    "window": windowArg,
                ], required: ["target"]),

            tool("spaceo_screenshot", """
                PNG of the session's window, or its tile with full=true, for what the outline \
                cannot convey. At scale=1 a window capture's pixels are click points; tile and \
                region captures report their origin in the image geometry. See \
                spaceo://docs/coordinates.
                """, ["session": sessionArg,
                      "window": windowArg,
                      "full": ["type": "boolean", "description": "Capture the whole tile."],
                      "scale": ["type": "integer", "minimum": 1, "maximum": 4,
                                "description": "Pixels per point; keep 1 unless reading small text."],
                      "x": ["type": "number", "description": "Region origin x, tile-relative."],
                      "y": ["type": "number", "description": "Region origin y, tile-relative."],
                      "width": ["type": "integer", "minimum": 1, "description": "Region width in points."],
                      "height": ["type": "integer", "minimum": 1, "description": "Region height in points."],
                      "annotate": ["type": "boolean",
                                   "description": "Window captures: tag each actionable element with its read index (image only)."]]),

            tool("spaceo_click", """
                Click an element reference from spaceo_read_screen ("3", web "w3"; preferred), \
                an exact label, or window-local x/y. References and labels are accessibility \
                presses: no button, count or modifiers; use x/y for those.
                """, ["element": ["type": "string", "maxLength": 32,
                                  "description": "Reference from spaceo_read_screen: \"3\" or \"w3\"."],
                      "x": ["type": "number", "description": "Window-relative x, in points."],
                      "y": ["type": "number", "description": "Window-relative y, in points."],
                      "button": buttonArg,
                      "count": ["type": "integer", "minimum": 1, "maximum": 3,
                                "description": "2 for a double-click, 3 to select a line."],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_scroll", """
                Scroll at a point or over an element, like a finger: negative dy moves the view \
                down (reveals what is below), negative dx moves the view right; native and web \
                alike. Reads describe only what is on screen, so scroll to reach more.
                """, ["element": ["type": "string", "maxLength": 32, "description": "Scroll over this element (\"3\" or \"w3\") instead of x/y."],
                      "x": ["type": "number", "description": "Window-relative x to scroll over."],
                      "y": ["type": "number", "description": "Window-relative y to scroll over."],
                      "dy": ["type": "integer", "minimum": -10_000, "maximum": 10_000,
                             "description": "Vertical pixels per tick; try -600 to page down."],
                      "dx": ["type": "integer", "minimum": -10_000, "maximum": 10_000,
                             "description": "Horizontal pixels per tick; try -600 to reveal later columns."],
                      "ticks": ["type": "integer", "minimum": 1, "maximum": 100,
                                "description": "Number of wheel ticks."],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_select_text", """
                Select text in a VS Code-family editor by zero-based line and character (read \
                back from the editor). Use instead of spaceo_drag there; x/y only pick the pane.
                """, ["x": ["type": "number", "description": "Window-relative x inside the editor pane."],
                      "y": ["type": "number", "description": "Window-relative y inside the editor pane."],
                      "anchor_line": ["type": "integer", "minimum": 0, "description": "Line where the selection starts."],
                      "anchor_character": ["type": "integer", "minimum": 0, "description": "Character on that line."],
                      "active_line": ["type": "integer", "minimum": 0, "description": "Line where the selection ends."],
                      "active_character": ["type": "integer", "minimum": 0, "description": "Character on that line."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: [
                     "x", "y", "anchor_line", "anchor_character", "active_line",
                     "active_character",
                 ]),

            tool("spaceo_move", """
                Move the pointer without pressing, to reveal hover-only menus, tooltips and \
                controls that fade in; then read the screen (or rely on observe) to see them.
                """, ["element": ["type": "string", "maxLength": 32, "description": "Hover this element (\"3\" or \"w3\") instead of x/y."],
                      "x": ["type": "number", "description": "Window-relative x."],
                      "y": ["type": "number", "description": "Window-relative y."],
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_drag", """
                Press at one point, drag to another, and release: sliders, reordering, resizing, \
                selecting text. Either end may be an element reference (from_element / \
                to_element) instead of coordinates.
                """, ["from_element": ["type": "string", "maxLength": 32, "description": "Start at this element's centre instead of x/y."],
                      "to_element": ["type": "string", "maxLength": 32, "description": "End at this element's centre instead of to_x/to_y."],
                      "x": ["type": "number", "description": "Window-relative start x."],
                      "y": ["type": "number", "description": "Window-relative start y."],
                      "to_x": ["type": "number", "description": "Window-relative end x."],
                      "to_y": ["type": "number", "description": "Window-relative end y."],
                      "button": buttonArg,
                      "modifiers": modifiersArg,
                      "web": webPointArg,
                      "session": sessionArg,
                      "window": windowArg]),

            tool("spaceo_type", """
                Type text into the focused element; newlines are Return. web=true types into page \
                content rather than the browser's own UI. replace=true selects the field's \
                contents first; submit=true presses Return afterwards.
                """, ["text": ["type": "string", "maxLength": 8_000, "description": "The text to type."],
                      "replace": ["type": "boolean", "description": "Select-all in the focused field first."],
                      "submit": ["type": "boolean", "description": "Press Return after the text."],
                      "web": ["type": "boolean", "description": "Type into page content."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["text"]),

            tool("spaceo_press_key", """
                Press a key or combination: "cmd+s", "return", "tab", "esc". hold_ms holds it; \
                action down/up sends one half (released after 10 s). cmd+c/x/v use the session's \
                private clipboard, never the user's pasteboard.
                """, ["key": ["type": "string", "maxLength": 64, "description": "Key combination."],
                      "hold_ms": ["type": "integer", "minimum": 0, "maximum": 5_000, "description": "Hold before release, in ms."],
                      "action": ["type": "string", "enum": ["tap", "down", "up"], "description": "tap (default), or only down / up."],
                      "web": ["type": "boolean", "description": "Send the key to page content."],
                      "session": sessionArg,
                      "window": windowArg],
                 required: ["key"]),

            tool("spaceo_list_windows",
                 "List the session's windows with ids, frames, titles and [focused]/[modal]/[default] markers. With timeout, wait (bounded) until a window is listed.",
                 ["session": sessionArg]),

            tool("spaceo_verify_isolation", """
                Audit session health and attention isolation. \
                \(IsolationVerdictGuidance.toolDescriptionLine())
                """, ["session": sessionArg]),

            tool("spaceo_pool_status",
                 "Show agent displays, how many sessions each holds, and spare capacity."),
        ]
    }()

    static let toolSchemaResourceText: String? = {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["tools": toolSchemas], options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }()

    private static func callTool(
        name: String,
        arguments: [String: Any],
        socketPath: String,
        controller: MCPControllerContext,
        id: Any?
    ) {
        let trace = UUID().uuidString.lowercased()
        let started = Date()
        var outcome = "invalid"
        // What the journal needs once the call has been answered.
        var journaled = MCPJournalCall(tool: name, trace: trace, arguments: arguments,
                                       startedAt: started, milliseconds: 0, outcome: outcome)
        defer {
            let milliseconds = Int(max(0, Date().timeIntervalSince(started) * 1_000).rounded())
            note("tool.finished trace=\(trace) tool=\(MCPDiagnostic.name(name)) outcome=\(outcome) ms=\(milliseconds)")
            if let journal = controller.journal {
                journaled.milliseconds = milliseconds
                journaled.outcome = outcome
                journal.toolCall(journaled)
            }
        }

        // One-time notes (daemon drift, sessions that ended in the background) lead whatever
        // this call returns, success or failure, so the agent reads them before acting on it.
        func reply(_ result: [String: Any]) {
            let notes = controller.memory.drainNotes()
            let final = prependingNotes(notes, to: result)
            journaled.notes = notes
            journaled.result = final
            respond(result: final, id: id)
        }

        let plan: MCPRequestPlan
        let options: MCPCallOptions
        do {
            var translated = try toolRequest(
                name: name,
                arguments: arguments,
                defaultControllerOwner: controller.owner
            )
            translated.diagnosticTraceID = trace
            options = MCPCallOptions(arguments: arguments, connectionVerbose: controller.memory.verbose)
            plan = try controller.plan(translated)
            journaled.request = translated
            if observeTools.contains(name) { journaled.observe = options.observe.rawValue }
        } catch {
            outcome = "invalid_arguments"
            reply(toolError(
                (error as? MCPInputError)?.description ?? error.localizedDescription,
                tool: name))
            return
        }

        let request: Request
        switch plan {
        case .single(let single):
            request = single
        case .ownedSessionDestroy(let requests):
            let destroyOutcome = destroyOwnedSessions(
                requests, socketPath: socketPath, controller: controller)
            outcome = destroyOutcome.failed ? "tool_error" : "ok"
            reply(destroyOutcome.failed
                  ? toolError(destroyOutcome.text, tool: name)
                  : ["content": [["type": "text", "text": destroyOutcome.text]]])
            return
        }

        var response: Response
        do {
            response = try sendRecoveringDaemon(request, socketPath: socketPath, controller: controller)
            // A draining daemon (SPAO-204) refuses only creates, and only until its replacement
            // is up. Bounded retry here spares the model from learning a restart dance.
            var attempts = 0
            while !response.ok, response.errorCode == "daemon_draining", request.cmd == "session.create", attempts < 20 {
                attempts += 1
                sleep(1)
                if !Transport.ping(socketPath) {
                    controller.memory.setDaemonDrift(ensureDaemon(socketPath: socketPath))
                }
                response = try Transport.send(request, to: socketPath, timeout: 120)
            }
        } catch let restart as MCPDaemonRestart {
            outcome = "daemon_restarted"
            reply(toolError(restart.description, tool: name))
            return
        } catch {
            outcome = "transport_error"
            reply(toolError("\(error)", tool: name))
            return
        }

        response = rewritingOutdatedDaemon(response, drift: controller.memory.daemonDrift)
        controller.record(response, for: request)
        journaled.request = request
        journaled.response = response
        guard response.ok else {
            outcome = "tool_error"
            reply(toolError(renderFailure(response, for: request, verbose: options.verbose), tool: name))
            return
        }
        rememberSnapshot(response, for: request, controller: controller)
        var context = MCPRenderContext(
            verbose: options.verbose, command: request.cmd,
            session: request.session ?? response.session?.id,
            ownedSessions: controller.ownedSessions, trace: trace,
            menuPath: request.menuPath, menuPressed: request.press == true)
        if let target = response.displayTarget, let session = context.session {
            context.displayTargetChanged = controller.memory.displayTargetChanged(session: session, target: target)
        }
        // The daemon returns an in-memory image; validate it without re-encoding the PNG
        // or accepting a file path supplied by a daemon response.
        if name == "spaceo_screenshot" {
            do {
                let content = try screenshotContent(
                    message: render(response, context: context) + "\ncapture: in-memory; freshness=unknown; visibility=unknown; presentation=unverified",
                    geometry: response.image, pngBase64: response.imageBase64)
                reply(["content": content])
                outcome = response.warnings?.isEmpty == false ? "warning" : "ok"
            } catch {
                outcome = "mcp_error"
                reply(toolError("\(error)", tool: name))
            }
            return
        }

        var text = render(response, context: context)
        if observeTools.contains(name),
           let observation = observeAfterAction(
               request: request, response: response, mode: options.observe,
               socketPath: socketPath, controller: controller) {
            text += "\n" + observation
            journaled.observed = true
        }
        reply(["content": [["type": "text", "text": text]]])
        outcome = response.warnings?.isEmpty == false ? "warning" : "ok"
    }

    /// Put one-time notes in front of the first text block of a tool result.
    static func prependingNotes(_ notes: [String], to result: [String: Any]) -> [String: Any] {
        guard !notes.isEmpty, var content = result["content"] as? [[String: Any]] else { return result }
        let prefix = notes.joined(separator: "\n")
        if let index = content.firstIndex(where: { $0["type"] as? String == "text" }),
           let text = content[index]["text"] as? String {
            content[index]["text"] = prefix + "\n" + text
        } else {
            content.insert(["type": "text", "text": prefix], at: 0)
        }
        var copy = result
        copy["content"] = content
        return copy
    }

    // MARK: - Daemon restart during a call

    /// Thrown instead of a response when the daemon vanished and the call cannot be replayed.
    struct MCPDaemonRestart: Error, CustomStringConvertible {
        var started: Bool
        var description: String {
            started
                ? "the SpaceO daemon restarted; sessions from before the restart have ended — "
                    + "create a new session with spaceo_session_create"
                : "the SpaceO daemon is not running and could not be started; ask the user to run `spaceo doctor`"
        }
    }

    /// Commands safe to replay once against a replacement daemon. A connect failure means the
    /// first attempt never reached a daemon, so a replay cannot double an effect; mutations are
    /// still not replayed, because the session they name ended with the old daemon. Create has
    /// no prior session to lose.
    static let replayableAfterDaemonRestart: Set<String> = [
        "ax", "ax.find", "ax.text", "screenshot", "windows", "verify", "targets", "wait",
        "clipboard.get", "session.list", "pool", "events.poll", "session.create",
    ]

    private static func sendRecoveringDaemon(
        _ request: Request, socketPath: String, controller: MCPControllerContext
    ) throws -> Response {
        do {
            return try Transport.send(request, to: socketPath, timeout: 120)
        } catch Transport.TransportError.notRunning {
            controller.memory.setDaemonDrift(ensureDaemon(socketPath: socketPath))
            let started = Transport.ping(socketPath)
            // Leases belonged to the old daemon's sessions; none of them authorizes anything now.
            controller.dropAllLeases()
            guard started else { throw MCPDaemonRestart(started: false) }
            guard replayableAfterDaemonRestart.contains(request.cmd) else {
                throw MCPDaemonRestart(started: true)
            }
            note("daemon restarted during \(request.cmd); replaying once")
            return try Transport.send(request, to: socketPath, timeout: 120)
        }
    }

    // MARK: - Observe after an action

    /// Tools whose successful receipt can carry fresh indices (`observe`).
    static let observeTools: Set<String> = [
        "spaceo_click", "spaceo_type", "spaceo_press_key", "spaceo_scroll", "spaceo_move",
        "spaceo_drag", "spaceo_select_text",
    ]

    /// Remember the newest snapshot a read returned, per session window, as the base for the
    /// next action's `observe: diff`.
    static func rememberSnapshot(_ response: Response, for request: Request, controller: MCPControllerContext) {
        guard response.ok, request.cmd != "steps.run",
              let snapshot = response.snapshotID,
              let windowID = response.geometry?.windowID,
              let session = request.session ?? response.session?.id else { return }
        controller.memory.recordSnapshot(session: session, windowID: windowID, snapshotID: snapshot)
    }

    /// Whether an action addressed web content, where `wN` indices are live page order and an
    /// accessibility diff of the browser chrome would say nothing useful.
    static func actionTargetsWeb(_ request: Request, response: Response) -> Bool {
        request.web == true
            || [request.element, request.fromElement, request.toElement].contains { $0?.hasPrefix("w") == true }
            || response.action?.route == "chromium-devtools"
    }

    /// The owner-scoped read an action's `observe` issues, or nil with the line to show instead.
    static func observeRequest(
        after request: Request, response: Response, mode: MCPCallOptions.Observe,
        memory: MCPConnectionMemory
    ) -> (request: Request?, line: String?) {
        guard mode != .none, response.ok, response.action?.outcome != "refused",
              !actionTargetsWeb(request, response: response),
              let session = request.session else { return (nil, nil) }
        guard let windowID = response.action?.windowID ?? request.window else {
            return (nil, "after action: read the screen for fresh indices")
        }
        let base = memory.snapshot(session: session, windowID: windowID)
        if mode == .diff, base == nil {
            return (nil, "after action: read the screen for fresh indices")
        }
        var read = Request(cmd: "ax")
        read.session = session
        read.window = windowID
        read.since = mode == .diff ? base : nil
        read.diagnosticTraceID = request.diagnosticTraceID
        return (read, nil)
    }

    /// Render the observe read. A failed read is one line; it never fails the action.
    static func renderObservation(_ observed: Response, mode: MCPCallOptions.Observe, base: String?) -> String {
        guard observed.ok else {
            let reason = observed.errorCode
                ?? observed.error.map { MCPDiagnostic.preview($0, maximumBytes: 160) } ?? "no response"
            return "observe: unavailable (\(reason))"
        }
        var lines: [String] = []
        if let handoff = observed.handoff { lines.append(handoff.summaryLine) }
        let snapshot = observed.snapshotID ?? "?"
        if mode == .diff, observed.diff?.baseMissing == true {
            lines.append("after action: snapshot \(snapshot) (earlier snapshot no longer cached; read the screen for fresh indices)")
            return lines.joined(separator: "\n")
        }
        lines.append("after action: snapshot \(snapshot)"
            + (mode == .diff ? " (changes since \(base.map { String($0.prefix(8)) } ?? "?"))" : ""))
        if let outline = observed.outline { lines.append(outline) }
        if let report = observed.truncation, mode == .full || report.truncated {
            lines.append(report.footer)
        }
        return lines.joined(separator: "\n")
    }

    private static func observeAfterAction(
        request: Request, response: Response, mode: MCPCallOptions.Observe,
        socketPath: String, controller: MCPControllerContext
    ) -> String? {
        let planned = observeRequest(after: request, response: response, mode: mode, memory: controller.memory)
        guard let read = planned.request else { return planned.line }
        do {
            let prepared = try controller.prepare(read)
            let observed = try Transport.send(prepared, to: socketPath, timeout: 30)
            controller.record(observed, for: prepared)
            if observed.ok, let snapshot = observed.snapshotID, let session = prepared.session,
               let windowID = prepared.window {
                controller.memory.recordSnapshot(session: session, windowID: windowID, snapshotID: snapshot)
            }
            return renderObservation(observed, mode: mode, base: read.since)
        } catch {
            return "observe: unavailable (\(MCPDiagnostic.preview(String(describing: error), maximumBytes: 160)))"
        }
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
        var summaries: [String] = []
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
                if let summary = response.destroySummary {
                    summaries.append("  " + MCPPresentation.destroySummary(summary, session: sessionID, verbose: false))
                }
            } catch {
                failures.append("\(sessionID): \(error)")
            }
        }

        var lines: [String] = []
        if !destroyed.isEmpty {
            lines.append("destroyed \(destroyed.count) session(s) owned by this MCP "
                         + "connection: \(destroyed.joined(separator: ", "))")
            lines.append(contentsOf: summaries)
        }
        if !failures.isEmpty {
            lines.append("failed to destroy \(failures.count) session(s):")
            lines.append(contentsOf: failures.map { "  \($0)" })
        }
        return (lines.joined(separator: "\n"), !failures.isEmpty)
    }

    /// The MCP content for a screenshot: what was captured, what its pixels mean, then the image.
    ///
    /// The geometry block is the machine-readable half. Prose alone left an MCP client unable to
    /// recover `originX`/`originY`, so a coordinate read off a tile capture could not be converted
    /// into a click at all — the numbers exist in the daemon's response and were simply dropped
    /// on the floor here. Internal so a non-GUI test can assert they survive.
    static func screenshotContent(
        message: String?,
        geometry: ImageGeometry?,
        pngBase64: String?
    ) throws -> [[String: Any]] {
        guard let pngBase64,
              PNGBase64.isValid(pngBase64, maximumDecodedBytes: Capture.maximumInMemoryPNGBytes) else {
            throw MCPInputError.invalid("daemon returned no valid bounded in-memory PNG; update daemon or reduce capture size")
        }
        var content: [[String: Any]] = [
            ["type": "text", "text": message ?? "screenshot"],
        ]
        if let geometry, let json = geometryJSON(geometry) {
            content.append(["type": "text", "text": "image geometry: \(json)"])
        }
        content.append(["type": "image",
                        "data": pngBase64,
                        "mimeType": "image/png"])
        return content
    }

    private static func geometryJSON(_ geometry: ImageGeometry) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(geometry) else { return nil }
        return String(data: data, encoding: .utf8)
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

    /// Intact is one line; partial names only the checks that did not pass; a breach, or
    /// `verbose`, prints the whole per-check table.
    static func renderIsolation(_ report: IsolationReport, verbose: Bool = false) -> String {
        MCPPresentation.isolation(report, verbose: verbose)
    }

    private static func renderLegacyIsolation(_ drift: [String]) -> String {
        drift.isEmpty
            ? "isolation: coverage unavailable (daemon returned no per-check report)"
            : "ISOLATION BREACH: " + drift.joined(separator: "; ")
    }

    /// The exact text placed in an MCP tool error. Kept internal so production failure rendering,
    /// including per-check coverage, is exercised without a socket or JSON-RPC process.
    static func renderFailure(_ response: Response, for request: Request? = nil, verbose: Bool = false) -> String {
        // Error bodies written for the CLI name `spaceo ax` and friends; an MCP agent can only
        // call tools, so name the tool instead wherever one exists.
        var error = MCPPresentation.translateBacktickedCLI(
            in: response.error ?? "unknown failure", toolsOnly: true)
        if let code = response.errorCode { error = "[\(code)] " + error }
        // A create-and-open can allocate a session, then fail to launch its app. The daemon
        // returns both the session and its lease in that case; tell the agent the exact ID so
        // it can recover or destroy the retained session without another discovery call.
        if request?.cmd == "session.create", let sessionID = response.session?.id,
           response.controllerLeaseID != nil,
           !sessionID.isEmpty,
           sessionID.utf8.count <= SessionManager.maximumSessionIDBytes,
           sessionID.count <= SessionManager.maximumSessionIDCharacters,
           sessionID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
           !sessionID.contains("/"), !sessionID.contains("\\") {
            error += "\nretained session: '\(sessionID)' (use this session ID to recover or call spaceo_session_destroy)"
        }
        if let capacity = MCPPresentation.capacity(retryAfter: response.retryAfterSeconds, holders: response.holders) {
            error += "\n" + capacity
        }
        // The structured recovery names the exact tool; the prose next action is the CLI's twin
        // of it and only adds noise. Without a recovery, translate the prose into tool terms.
        if let recovery = response.recovery, let json = recoveryJSON(recovery) {
            error += "\nrecovery: " + json
        } else if let next = response.nextAction, !next.isEmpty {
            error += "\nnext action: " + MCPPresentation.translateNextAction(next)
        }
        if let handoff = response.handoff { error = handoff.summaryLine + "\n" + error }
        if let teardown = response.teardown,
           !error.contains(teardown.recoveryDescription) {
            error += "\n" + teardown.recoveryDescription
        }
        if let isolation = response.isolation {
            error += "\n" + renderIsolation(isolation, verbose: verbose)
        } else if let drift = response.drift {
            error += "\n" + renderLegacyIsolation(drift)
        }
        if let steps = response.steps {
            error += "\n" + renderSteps(steps, firstFailureIndex: response.firstFailureIndex).joined(separator: "\n")
        }
        if let report = response.truncation, !error.contains(report.footer) {
            error += "\n" + report.footer
        }
        for warning in response.warnings ?? [] { error += "\nWARNING: " + warning }
        if let trace = request?.diagnosticTraceID { error += "\ntrace: " + trace }
        return error
    }

    /// An old daemon answers a command it predates with `unknown command 'X'`, which reads like
    /// the agent's mistake. When this connection already knows the daemon is a different build,
    /// say what actually happened and who can fix it.
    static func rewritingOutdatedDaemon(_ response: Response, drift: String?) -> Response {
        guard !response.ok, let drift,
              let error = response.error, error.hasPrefix("unknown command") else { return response }
        var rewritten = response
        rewritten.errorCode = "daemon_outdated"
        rewritten.error = error + " — " + drift
        rewritten.nextAction = "ask the user to run `spaceo daemon restart --operator`"
        rewritten.recovery = nil
        return rewritten
    }

    static func recoveryJSON(_ recovery: RecoveryHint) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(recovery) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Live, redacted daemon health for the `spaceo://doctor` resource: what an agent needs to
    /// self-diagnose (grants, attribution, build, draining) and nothing that identifies a user.
    static func doctorResource(socketPath: String) -> String {
        var payload: [String: Any] = [
            "socket": socketPath,
            "clientVersion": SpaceOVersion.current,
            "callerAttribution": ResponsibleProcess.describeCurrent() ?? NSNull(),
        ]
        if let response = Transport.pingResponse(socketPath) {
            payload["daemonRunning"] = response.ok
            if let daemon = response.daemon {
                payload["daemon"] = [
                    "version": daemon.version,
                    "pid": daemon.pid,
                    "accessibilityGranted": daemon.accessibilityGranted ?? NSNull(),
                    "screenRecordingGranted": daemon.screenRecordingGranted ?? NSNull(),
                    "canDrive": daemon.canDrive ?? NSNull(),
                    "canCapture": daemon.canCapture ?? NSNull(),
                    "responsibleProcess": daemon.responsibleProcess ?? NSNull(),
                    "draining": daemon.draining ?? false,
                    "supervisedByLaunchd": daemon.supervisedByLaunchd ?? NSNull(),
                    "matchesClientBuild": RuntimeIdentity.matchesCurrentExecutable(daemon) ?? NSNull(),
                ] as [String: Any]
            }
        } else {
            payload["daemonRunning"] = false
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func renderSteps(_ steps: [StepReceipt], firstFailureIndex: Int?) -> [String] {
        var lines: [String] = []
        for step in steps {
            var text = "step \(step.index) \(step.cmd): " + (step.executed ? (step.ok ? "ok" : "FAILED") : "not executed")
            if let completion = step.completion { text += " (\(completion))" }
            if let error = step.error { text += " — " + error.replacingOccurrences(of: "\n", with: " | ") }
            else if let message = step.message { text += " — " + message.replacingOccurrences(of: "\n", with: " | ").prefix(200) }
            lines.append(text)
            if let snapshot = step.snapshotID { lines.append("step \(step.index) snapshot: \(snapshot)") }
            if let outline = step.outline { lines.append(outline) }
            if let report = step.truncation { lines.append(report.footer) }
            if step.outputTruncated == true { lines.append("step output truncated; run spaceo_find separately and check its truncation report") }
        }
        if let failure = firstFailureIndex { lines.append("first_failure_index: \(failure)") }
        return lines
    }

    /// Flatten a daemon response into something a model reads well.
    static func render(_ response: Response, context: MCPRenderContext = .default) -> String {
        var lines: [String] = []
        let verbose = context.verbose
        // The operator's note is the first thing the agent must read after a pause.
        if let handoff = response.handoff { lines.append(handoff.summaryLine) }
        // The outcome leads: it is the one fact every action receipt exists to report.
        if let action = response.action {
            lines.append(MCPPresentation.actionLine(action))
            if verbose {
                lines.append("action: \(action.command), route=\(action.route), completion=\(action.completion)"
                    + (action.outcome.map { ", outcome=\($0)" } ?? ""))
            }
        }
        if let readiness = response.readiness, verbose || readiness.state != "ready" {
            lines.append("readiness: \(readiness.state); blockers=\(readiness.blockers); visibility=\(readiness.visibility); presentation=unverified (fps=null)")
        }
        if let snapshot = response.snapshotID { lines.append("snapshot: \(snapshot)") }
        if let geometry = response.geometry, context.showsGeometry(isAction: response.action != nil) {
            lines.append("geometry: \(geometry.token), window=\(geometry.windowID), coordinateSpace=\(geometry.coordinateSpace)")
        }
        if let capture = response.capture, let data = try? Wire.encoder.encode(capture), let text = String(data: data, encoding: .utf8) { lines.append("capture: " + text) }
        if let assertion = response.verificationAssertion, let data = try? Wire.encoder.encode(assertion), let text = String(data: data, encoding: .utf8) { lines.append("verificationAssertion: " + text) }
        if response.windows != nil {
            for receipt in response.geometries ?? [] { lines.append("window \(receipt.windowID) geometry: \(receipt.token)") }
        }
        if let target = response.displayTarget, verbose || context.displayTargetChanged,
           let data = try? Wire.encoder.encode(target), let text = String(data: data, encoding: .utf8) {
            lines.append("displayTarget: " + text
                + (context.displayTargetChanged ? " (CHANGED since your last call: re-read windows before using coordinates)" : ""))
        }
        if let placement = response.placement, let data = try? Wire.encoder.encode(placement), let text = String(data: data, encoding: .utf8) { lines.append("placement: " + text) }
        if let summary = response.destroySummary {
            lines.append(MCPPresentation.destroySummary(summary, session: context.session ?? response.session?.id, verbose: verbose))
        }
        // A press reports what it pressed; its sibling items are only noise unless asked for.
        if let menu = response.menu, !context.menuPressed || verbose {
            let path = context.menuPressed ? context.menuPath.map { Array($0.dropLast()) } : context.menuPath
            lines += MCPPresentation.menu(menu, path: path)
        }
        if let point = response.resolvedPoint {
            var text = "resolved_point: (\(whole(point.x)),\(whole(point.y))) from \(point.source)"
            if let element = point.element { text += " \(element)" }
            if let toX = point.toX, let toY = point.toY { text += " to (\(whole(toX)),\(whole(toY)))" }
            lines.append(text)
        }
        if let wait = response.wait {
            lines.append("wait: \(wait.condition)\(wait.value.map { " '\($0)'" } ?? ""), outcome=\(wait.outcome), elapsed=\(String(format: "%.1f", wait.elapsedSeconds))s, probes=\(wait.probes)"
                + (wait.matchedIndex.map { ", element=\($0)" } ?? "") + (wait.matchedTitle.map { ", title=\"\($0)\"" } ?? ""))
        }
        if let navigation = response.navigation {
            lines.append("navigation: title=\"\(navigation.title)\" final_url=\(navigation.finalURL) target_id=\(navigation.targetID) load=\(navigation.load) reused_browser=\(navigation.reusedBrowser)")
        }
        if let paste = response.paste {
            lines.append("clipboard: inserted_via=\(paste.insertedVia), bytes=\(paste.bytes)" + (paste.note.map { "; \($0)" } ?? ""))
        }
        if response.reused == true { lines.append("reused: true") }
        if response.replaced == true || response.submitted == true {
            lines.append("typing: replaced=\(response.replaced ?? false), submitted=\(response.submitted ?? false)")
        }
        if let released = response.releasedHeldKeys, !released.isEmpty { lines.append("released_held_keys: \(released.joined(separator: ", "))") }
        // The destroy summary already says "destroyed 'x'", with what that did.
        if let message = response.message,
           !(response.destroySummary != nil && message.hasPrefix("destroyed ")) {
            lines.append(message)
        }
        // `menu` responses carry the same items structurally; rendering both doubled the list.
        if let outline = response.outline, response.menu == nil { lines.append(outline) }
        if let report = response.truncation, response.message?.contains(report.footer) != true {
            lines.append(report.footer)
        }
        if let steps = response.steps { lines += renderSteps(steps, firstFailureIndex: response.firstFailureIndex) }
        if let events = response.events {
            if events.isEmpty { lines.append("no events") }
            for event in events {
                var text = "event \(event.seq) \(event.at.ISO8601Format()) \(event.kind)"
                if let session = event.session { text += " session=\(session)" }
                if event.redacted == true { text += " [redacted]" }
                else if !event.detail.isEmpty {
                    text += " " + event.detail.keys.sorted().map { "\($0)=\(event.detail[$0] ?? "")" }.joined(separator: " ")
                }
                lines.append(text)
            }
            if let next = response.nextSeq { lines.append("next_seq: \(next)" + (response.resyncRequired == true ? " (resync_required: call spaceo_session_list)" : "")) }
        }
        if let bytes = response.clipboardBytes, response.paste == nil { lines.append("clipboard_bytes: \(bytes)") }
        if let reclaimed = response.reclaimedBytes { lines.append("reclaimed_bytes: \(reclaimed)") }

        if let session = response.session { lines.append(describe(session, owned: context.ownedSessions)) }
        if let sessions = response.sessions {
            if sessions.isEmpty { lines.append("no sessions") }
            for session in sessions { lines.append(describe(session, owned: context.ownedSessions)) }
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
            if let source = response.source {
                lines.append("text (\(source)\(response.truncated == true ? ", truncated" : "")):\n\(value)")
            } else if response.clipboardBytes != nil {
                lines.append("clipboard text:\n\(value)")
            } else {
                lines.append("window text now: \(value.prefix(400))")
            }
        }
        for finding in response.findings ?? [] { lines.append("issue: \(finding)") }

        if let isolation = response.isolation {
            lines.append(renderIsolation(isolation, verbose: verbose))
        } else if let drift = response.drift {
            lines.append(renderLegacyIsolation(drift))
        }
        // Ahead of ambient notes: an unconfirmed effect changes what the agent should do next,
        // where an ambient note is only context.
        for warning in response.warnings ?? [] { lines.append("UNCONFIRMED: \(warning)") }
        for change in response.ambient ?? [] { lines.append("note: \(change)") }
        return lines.isEmpty ? "ok" : lines.joined(separator: "\n")
    }

    private static func describe(_ session: SessionInfo, owned: Set<String> = [], now: Date = Date()) -> String {
        let tile = session.exclusiveDisplay
            ? "whole display \(session.displayID)"
            : "tile \(session.tileIndex + 1)/\(session.tileCapacity) of display \(session.displayID)"
        // An agent scanning a shared pool must tell its own sessions from everyone else's.
        let mine = owned.contains(session.id) ? "[yours] " : ""
        var text: String
        if session.runtimeAttached == false {
            text = mine + "session '\(session.id)' [detached recovery record; no live display target]"
            if session.displayID != 0, session.width > 0, session.height > 0 {
                text += "\n  last-known placement only: \(tile), "
                    + "\(whole(session.width))x\(whole(session.height)) "
                    + "at (\(whole(session.x)),\(whole(session.y)))"
            }
        } else {
            text = mine + "session '\(session.id)' on \(tile), "
                + "\(whole(session.width))x\(whole(session.height)) "
                + "at (\(whole(session.x)),\(whole(session.y)))"
        }
        let claimable = session.abandoned == true && !session.teardownPending
        if claimable {
            // An abandoned session is the one case where another connection may act: say how.
            text += " [abandoned: spaceo_session_claim"
                + (session.graceRemainingSeconds.map { " within \(MCPPresentation.duration(max(0, $0)))" } ?? "")
                + " keeps its apps]"
        } else if session.redacted == true {
            text += " [another controller; contents redacted]"
        }
        var timing: [String] = []
        if let idle = session.idleSeconds { timing.append("idle \(MCPPresentation.duration(idle))") }
        if let expiry = session.leaseExpiresAt, !claimable {
            let remaining = expiry.timeIntervalSince(now)
            timing.append(remaining > 0 ? "lease expires in \(MCPPresentation.duration(remaining))" : "lease expired")
        }
        if let grace = session.orphanGraceSeconds { timing.append("orphan grace \(MCPPresentation.duration(grace))") }
        if !timing.isEmpty { text += "\n  " + timing.joined(separator: "; ") }
        if let title = session.title, !title.isEmpty { text += "\n  title: \(title)" + (session.colorTag.map { " [\($0)]" } ?? "") }
        if session.inputPaused == true {
            text += "\n  input: PAUSED" + (session.agentPauseReason.map { " (agent: \($0))" } ?? " (operator has Control)")
        }
        if session.operatorHandoff != nil { text += "\n  operator handoff pending: it is delivered with the next command" }
        if let recording = session.recording { text += "\n  recording: \(recording)" }
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
        let exited = session.exitedApps ?? []
        for app in exited.prefix(8) {
            text += "\n  exited app \(app.name) (pid \(app.pid)"
                + (app.status.map { ", \($0)" } ?? "")
                + ", \(MCPPresentation.duration(now.timeIntervalSince(app.exitedAt))) ago)"
        }
        if exited.count > 8 { text += "\n  and \(exited.count - 8) more exited app(s)" }
        for window in session.windows { text += "\n  " + describe(window) }
        return text
    }

    /// The origin is load-bearing, not decoration. Converting a tile-screenshot pixel into a click
    /// is `pixel / scale + originX - windowX`, and this line is the only place the whole MCP
    /// surface ever emits `windowX`. Dropping it left an agent with two of the three terms and no
    /// way to finish the conversion, so it clicked raw pixels and missed by the window's inset.
    private static func describe(_ window: WindowInfo) -> String {
        "window \(window.windowID) \(whole(window.width))x\(whole(window.height))"
            + " at (\(whole(window.x)),\(whole(window.y)))"
            + (window.title.isEmpty ? "" : " \"\(window.title)\"")
            // Where keys go, what blocks the app, and what an omitted `window` means.
            + (window.focused == true ? " [focused]" : "")
            + (window.modal == true ? " [modal]" : "")
            + (window.defaultTarget == true ? " [default]" : "")
            + (window.onStage ? "" : "  [outside this session's tile]")
    }

    private static func whole(_ value: Double) -> String {
        guard value.isFinite,
              let integral = Int(exactly: value.rounded()) else {
            return "?"
        }
        return String(integral)
    }

    /// Every tool failure is echoed to stderr, which the MCP host retains in its own logs —
    /// so a failure the model shrugged off is still there for a person to investigate.
    /// The echo is one byte-bounded line; control characters are escaped.
    private static func toolError(_ message: String, tool: String? = nil) -> [String: Any] {
        note("tool \(MCPDiagnostic.name(tool ?? "call")) failed: \(MCPDiagnostic.preview(message))")
        return ["isError": true, "content": [["type": "text", "text": message]]]
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
    private static let reviewFields: [String: Set<String>] = [
        "spaceo_place_window": ["strict", "require_isolation"],
        "spaceo_scroll": ["strict", "require_isolation"],
        "spaceo_move": ["strict", "require_isolation"],
        "spaceo_type": ["strict", "require_isolation"],
        "spaceo_press_key": ["strict", "require_isolation"],
        "spaceo_select_text": ["strict", "require_isolation", "geometry"],
        "spaceo_open_app": ["allow_no_windows", "timeout", "arguments", "strict", "require_isolation"],
        "spaceo_session_destroy": ["keep_apps"],
        "spaceo_adopt_app": ["allow_no_windows", "strict", "require_isolation"],
        "spaceo_click": ["snapshot", "geometry", "strict", "label", "match", "role", "require_isolation"],
        "spaceo_drag": ["duration", "geometry", "strict", "require_isolation"],
        "spaceo_list_windows": ["timeout", "pid"],
        "spaceo_verify_isolation": ["require_window", "strict", "require_isolation"],
    ]
    /// Tools whose result carries no receipt worth expanding, so `verbose` is not offered.
    static let receiptlessTools: Set<String> = [
        "spaceo_session_list", "spaceo_pool_status", "spaceo_events", "spaceo_session_heartbeat",
    ]

    /// Accepted for compatibility but no longer advertised: they only relabel diagnostics, and
    /// every schema byte is paid for by every agent on every connection.
    /// `session` on create is a forgiven alias of `name`, not a second documented spelling.
    /// `require_isolation` is advertised once, on spaceo_verify_isolation, and documented in the
    /// playbook for the acting tools that also accept it; `strict` covers the common case.
    /// `verbose` is accepted by every tool with receipts but advertised only where the expanded
    /// receipt is worth reading (actions and observations), for the same reason.
    static func unadvertisedFields(for tool: String) -> Set<String> {
        switch tool {
        case "spaceo_session_create":
            return ["controller_id", "controller_label", "controller_kind", "session"]
        case "spaceo_verify_isolation":
            return []
        case "spaceo_session_pause", "spaceo_session_resume", "spaceo_session_set_title",
             "spaceo_clipboard_set", "spaceo_clipboard_get", "spaceo_list_targets",
             "spaceo_attach_target":
            return ["require_isolation", "verbose"]
        default:
            return ["require_isolation"]
        }
    }

    /// MCP-side presentation arguments (`verbose`, `observe`) a tool accepts. They shape the
    /// tool result and are never sent to the daemon.
    static func presentationFields(for tool: String) -> Set<String> {
        var fields: Set<String> = receiptlessTools.contains(tool) ? [] : ["verbose"]
        if observeTools.contains(tool) { fields.insert("observe") }
        return fields
    }

    static func presentationFieldSchema(_ key: String) -> [String: Any] {
        switch key {
        case "observe":
            return ["type": "string", "enum": MCPCallOptions.Observe.allCases.map(\.rawValue),
                    "description": "Append fresh indices after success (default diff)."]
        default:
            return ["type": "boolean", "description": "Full receipts."]
        }
    }

    private static func reviewFieldSchema(_ key: String) -> [String: Any] {
        switch key {
        case "pid": return ["type": "integer", "minimum": 1, "maximum": Int32.max, "description": "Only windows of this session-owned process."]
        case "label": return ["type": "string", "maxLength": 480, "description": "Press the one element with this exact accessible label."]
        case "match": return ["type": "string", "enum": ["exact", "contains"], "description": "With label: exact (default) or contains."]
        case "role": return ["type": "string", "maxLength": 64, "description": "With label: only this role, e.g. Button."]
        case "require_isolation": return ["type": "array", "minItems": 1, "maxItems": 6, "items": ["type": "string", "enum": IsolationDimension.allCases.map(\.rawValue)],
                                          "description": "Fail unless these checks are observable."]
        case "strict": return ["type": "boolean", "description": "Refuse unless every isolation check is observable."]
        case "allow_no_windows": return ["type": "boolean", "description": "Accept a confirmed zero window count."]
        case "require_window": return ["type": "boolean", "description": "Report a session with no window as unhealthy."]
        case "keep_apps": return ["type": "boolean", "description": "Leave the apps running instead of quitting them."]
        case "timeout": return ["type": "number", "minimum": 0.5, "maximum": 120, "description": "Seconds to wait for a window."]
        case "duration": return ["type": "number", "minimum": 0.05, "maximum": 30, "description": "Drag duration in seconds."]
        case "arguments": return ["type": "array", "maxItems": 128, "items": ["type": "string", "maxLength": 4096], "description": "Extra launch arguments."]
        default: return ["type": "string", "maxLength": 128, "description": "Receipt from your latest read; stale refuses."]
        }
    }

    static let maximumPromptArgumentCharacters = 4_096
    static let maximumPromptArgumentBytes = 16_384

    static func promptArgumentDescription(_ description: String) -> String {
        description + " Maximum \(maximumPromptArgumentCharacters) characters and "
            + "\(maximumPromptArgumentBytes) UTF-8 bytes."
    }

    /// Pure prompt expansion: reject malformed arguments before copying values into instructions.
    static func promptResult(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String,
              let prompt = Playbook.prompts.first(where: { $0.name == name }),
              let document = Playbook.documents.first(where: { $0.name == prompt.documentName }) else {
            throw MCPInputError.invalid("unknown prompt")
        }
        let arguments: [String: Any]
        if let supplied = params["arguments"] {
            guard let object = supplied as? [String: Any] else {
                throw MCPInputError.invalid("prompt arguments must be an object")
            }
            arguments = object
        } else {
            arguments = [:]
        }
        if let diagnostic = MCPDiagnostic.unexpected(arguments.keys, allowed: Set(prompt.arguments.map(\.name))) {
            throw MCPInputError.invalid(diagnostic)
        }
        var preamble = ""
        for argument in prompt.arguments {
            guard let supplied = arguments[argument.name] else {
                if argument.required {
                    throw MCPInputError.invalid("prompt '\(name)' needs argument '\(argument.name)'")
                }
                continue
            }
            guard let value = supplied as? String else {
                throw MCPInputError.invalid("prompt argument '\(argument.name)' must be a string")
            }
            guard value.utf8.count <= maximumPromptArgumentBytes,
                  value.count <= maximumPromptArgumentCharacters else {
                throw MCPInputError.invalid("prompt argument '\(argument.name)' is too long (maximum "
                    + "\(maximumPromptArgumentCharacters) characters and \(maximumPromptArgumentBytes) UTF-8 bytes)")
            }
            preamble += "\(argument.name): \(value)\n"
        }
        return [
            "description": prompt.description,
            "messages": [[
                "role": "user",
                "content": ["type": "text", "text": (preamble.isEmpty ? "" : preamble + "\n") + document.markdown],
            ]],
        ]
    }

    static func toolRequest(
        name: String,
        arguments: [String: Any],
        defaultControllerOwner: DurableSessionOwner? = nil
    ) throws -> Request {
        var allowed: Set<String>
        switch name {
        case "spaceo_session_create":
            allowed = [
                "name", "session", "controller_id", "controller_label", "controller_kind", "ttl_seconds",
                "app", "files", "preset", "title", "record", "mute_audio", "orphan_grace_seconds",
            ]
        case "spaceo_session_claim": allowed = ["session"]
        case "spaceo_place_window": allowed = ["session", "window", "placement"]
        case "spaceo_adopt_app": allowed = ["session", "pid"]
        case "spaceo_session_pause": allowed = ["session", "reason"]
        case "spaceo_session_resume": allowed = ["session"]
        case "spaceo_session_heartbeat": allowed = ["session"]
        case "spaceo_session_list", "spaceo_pool_status": allowed = []
        case "spaceo_session_destroy": allowed = ["session", "all"]
        case "spaceo_open_app": allowed = ["session", "app", "files", "new_instance", "mute_audio"]
        case "spaceo_open_url": allowed = ["session", "window", "url", "new_tab", "timeout", "mute_audio"]
        case "spaceo_wait_for": allowed = ["session", "window", "condition", "value", "timeout", "match", "role"]
        case "spaceo_menu": allowed = ["session", "window", "path", "press", "pid"]
        case "spaceo_find": allowed = ["session", "window", "query", "role"]
        case "spaceo_read_text": allowed = ["session", "window", "element", "max_chars"]
        case "spaceo_run_steps": allowed = ["session", "steps", "stop_on_failure"]
        case "spaceo_clipboard_set": allowed = ["session", "text"]
        case "spaceo_clipboard_get": allowed = ["session"]
        case "spaceo_session_set_title": allowed = ["session", "title"]
        case "spaceo_events": allowed = ["since_seq"]
        case "spaceo_read_screen": allowed = ["session", "window", "full", "since"]
        case "spaceo_list_targets": allowed = ["session", "window"]
        case "spaceo_attach_target": allowed = ["session", "window", "target"]
        case "spaceo_screenshot":
            allowed = ["session", "window", "full", "scale", "x", "y", "width", "height", "annotate"]
        case "spaceo_click":
            allowed = [
                "session", "window", "element", "x", "y", "button", "count", "modifiers", "web",
            ]
        case "spaceo_scroll":
            allowed = ["session", "window", "element", "x", "y", "dx", "dy", "ticks", "modifiers", "web"]
        case "spaceo_move":
            allowed = ["session", "window", "element", "x", "y", "modifiers", "web"]
        case "spaceo_drag":
            allowed = [
                "session", "window", "from_element", "to_element", "x", "y", "to_x", "to_y", "button", "modifiers", "web",
            ]
        case "spaceo_select_text":
            allowed = [
                "session", "window", "x", "y", "anchor_line", "anchor_character",
                "active_line", "active_character",
            ]
        case "spaceo_type": allowed = ["session", "window", "text", "web", "replace", "submit"]
        case "spaceo_press_key": allowed = ["session", "window", "key", "web", "hold_ms", "action"]
        case "spaceo_list_windows", "spaceo_verify_isolation": allowed = ["session"]
        default: throw MCPInputError.invalid("unknown tool '\(MCPDiagnostic.name(name))'")
        }
        allowed.formUnion(Self.reviewFields[name] ?? [])
        allowed.formUnion(Self.presentationFields(for: name))
        if let diagnostic = MCPPresentation.unexpectedArguments(
            arguments.keys, allowed: allowed, advertised: allowed.subtracting(Self.unadvertisedFields(for: name))) {
            throw MCPInputError.invalid(diagnostic)
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
            guard string.utf8.count <= byteLimit, string.count <= max else {
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
            guard trimmed.utf8.count <= SessionManager.maximumSessionIDBytes,
                  trimmed.count <= SessionManager.maximumSessionIDCharacters else {
                throw MCPInputError.invalid(
                    "'\(key)' must be at most \(SessionManager.maximumSessionIDCharacters) "
                    + "characters and \(SessionManager.maximumSessionIDBytes) UTF-8 bytes")
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
                      path.utf8.count <= 16_384,
                      path.count <= 4_096 else {
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
        // Presentation arguments never reach the daemon; validate them here so a typo is
        // refused like any other argument instead of silently changing nothing.
        _ = try flag("verbose")
        if let observe = try str("observe", max: 8), MCPCallOptions.Observe(rawValue: observe) == nil {
            throw MCPInputError.invalid("'observe' must be none, diff or full")
        }

        switch name {
        case "spaceo_session_create":
            request.cmd = "session.create"
            // `session` is what every other tool calls the id, so models reach for it here too.
            if supplied("name") != nil, supplied("session") != nil {
                throw MCPInputError.invalid("use either 'name' or 'session' for the new session id, not both")
            }
            request.session = try sessionID("name") ?? request.session
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
            request.app = try str("app")
            request.files = try files()
            if request.app == nil, request.files != nil {
                throw MCPInputError.invalid("'files' needs 'app'")
            }
            request.preset = try str("preset", max: 32)
            if let preset = request.preset, !["shared", "exclusive", "exclusive_1080p", "exclusive_1440p"].contains(preset) {
                throw MCPInputError.invalid("'preset' must be shared, exclusive, exclusive_1080p or exclusive_1440p")
            }
            request.title = try str("title", max: 120)
            request.record = try str("record", max: 16)
            if let record = request.record, !["actions", "actions+frames"].contains(record) {
                throw MCPInputError.invalid("'record' must be actions or actions+frames")
            }
            request.muteAudio = try flag("mute_audio")
            request.orphanGraceSeconds = try dbl("orphan_grace_seconds") ?? MCPServer.defaultOrphanGraceSeconds
            if let grace = request.orphanGraceSeconds, !(30...1_800).contains(grace) {
                throw MCPInputError.invalid("'orphan_grace_seconds' must be from 30 through 1800")
            }
        case "spaceo_session_claim":
            request.cmd = "session.claim"
            guard request.session != nil else {
                throw MCPInputError.invalid("'session' is required: claim never picks a session for you")
            }
            // The claimed session gets the same protection a session created here would have.
            request.orphanGraceSeconds = MCPServer.defaultOrphanGraceSeconds
        case "spaceo_session_list":
            request.cmd = "session.list"
        case "spaceo_session_heartbeat":
            request.cmd = "session.heartbeat"
        case "spaceo_session_destroy":
            request.cmd = "session.destroy"
            request.quitApps = try flag("keep_apps").map { !$0 }
            request.full = try flag("all")
            if request.session != nil, request.full == true {
                throw MCPInputError.invalid("use either 'session' or 'all', not both")
            }
        case "spaceo_place_window":
            request.cmd = "place"
            request.placement = try str("placement", max: 16)
        case "spaceo_adopt_app":
            request.cmd = "adopt"
            guard let pid = try int("pid"), pid > 0, let exact = Int32(exactly: pid) else {
                throw MCPInputError.invalid("pid must be a positive Int32")
            }
            request.pid = exact
        case "spaceo_session_pause", "spaceo_session_resume":
            request.cmd = "session.control"
            request.paused = name == "spaceo_session_pause"
            request.reason = try str("reason", max: 240)
        case "spaceo_open_app":
            request.cmd = "run"
            request.app = try str("app")
            request.files = try files()
            request.newInstance = try flag("new_instance")
            request.muteAudio = try flag("mute_audio")
            guard let app = request.app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPInputError.invalid("'app' is required")
            }
        case "spaceo_open_url":
            request.cmd = "open.url"
            request.url = try str("url", max: 8_192, maxBytes: 8_192)
            request.newTab = try flag("new_tab")
            request.muteAudio = try flag("mute_audio")
            guard let url = request.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
                  let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  ["http", "https", "file", "about"].contains(scheme) else {
                throw MCPInputError.invalid("'url' must be an http(s), file or about URL")
            }
        case "spaceo_wait_for":
            request.cmd = "wait"
            request.waitCondition = try str("condition", max: 32)
            request.waitValue = try str("value", max: 480)
            request.match = try str("match", max: 16)
            request.role = try str("role", max: 64)
            guard let condition = request.waitCondition,
                  WaitCondition.knownKinds.contains(condition) else {
                throw MCPInputError.invalid("'condition' must be one of " + WaitCondition.knownKinds.joined(separator: ", "))
            }
            if request.waitValue == nil, condition != "session_resumed" {
                throw MCPInputError.invalid("'value' is required for condition '\(condition)'")
            }
            if let match = request.match, !["exact", "contains"].contains(match) {
                throw MCPInputError.invalid("'match' must be exact or contains")
            }
        case "spaceo_menu":
            request.cmd = "menu"
            request.press = try flag("press")
            if let pid = try int("pid") {
                guard pid > 0, let exact = Int32(exactly: pid) else {
                    throw MCPInputError.invalid("'pid' must be a positive Int32")
                }
                request.pid = exact
            }
            if let raw = supplied("path") {
                guard let list = raw as? [Any], list.count <= 6 else {
                    throw MCPInputError.invalid("'path' must be an array of at most 6 menu titles")
                }
                request.menuPath = try list.map { item in
                    guard let title = item as? String, !title.isEmpty,
                          title.count <= 256, title.utf8.count <= 1_024 else {
                        throw MCPInputError.invalid("every 'path' entry must be a non-empty title of at most 256 characters")
                    }
                    return title
                }
            }
            if request.press == true, (request.menuPath ?? []).isEmpty {
                throw MCPInputError.invalid("press needs a 'path' naming one menu item, e.g. [\"File\", \"New\"]")
            }
        case "spaceo_find":
            request.cmd = "ax.find"
            request.query = try str("query", max: 480)
            request.role = try str("role", max: 64)
            guard let query = request.query, !query.isEmpty else { throw MCPInputError.invalid("'query' is required") }
        case "spaceo_read_text":
            request.cmd = "ax.text"
            request.element = try str("element", max: 32)
            request.maxChars = try int("max_chars")
            if let limit = request.maxChars, !(1...20_000).contains(limit) {
                throw MCPInputError.invalid("'max_chars' must be from 1 through 20000")
            }
        case "spaceo_run_steps":
            request.cmd = "steps.run"
            request.stopOnFailure = try flag("stop_on_failure")
            guard let rawSteps = supplied("steps") as? [Any], !rawSteps.isEmpty, rawSteps.count <= 16 else {
                throw MCPInputError.invalid("'steps' must be an array of 1 through 16 {tool, arguments} objects")
            }
            let stepTools: Set<String> = [
                "spaceo_click", "spaceo_type", "spaceo_press_key", "spaceo_scroll", "spaceo_move",
                "spaceo_drag", "spaceo_wait_for", "spaceo_find",
            ]
            request.steps = try rawSteps.enumerated().map { index, raw in
                guard let object = raw as? [String: Any], let tool = object["tool"] as? String else {
                    throw MCPInputError.invalid("step \(index) must be an object with a 'tool' string")
                }
                guard stepTools.contains(tool) else {
                    throw MCPInputError.invalid("step \(index): '\(MCPDiagnostic.name(tool))' cannot be batched; use " + stepTools.sorted().joined(separator: ", "))
                }
                if let unexpected = MCPDiagnostic.unexpected(object.keys, allowed: ["tool", "arguments"]) {
                    throw MCPInputError.invalid("step \(index): \(unexpected)")
                }
                var stepArguments: [String: Any] = [:]
                if let suppliedArguments = object["arguments"] {
                    guard let arguments = suppliedArguments as? [String: Any] else {
                        throw MCPInputError.invalid("step \(index): arguments must be an object")
                    }
                    stepArguments = arguments
                }
                if stepArguments["observe"] != nil || stepArguments["verbose"] != nil {
                    throw MCPInputError.invalid("step \(index): 'observe' and 'verbose' apply to the whole call; "
                        + "pass verbose on spaceo_run_steps and read the screen after the batch")
                }
                guard stepArguments["session"] == nil || (stepArguments["session"] as? String) == request.session else {
                    throw MCPInputError.invalid("step \(index) names a different session; a batch runs on one session")
                }
                stepArguments.removeValue(forKey: "session")
                return try toolRequest(name: tool, arguments: stepArguments, defaultControllerOwner: nil)
            }
        case "spaceo_clipboard_set":
            request.cmd = "clipboard.set"
            request.text = try str("text", max: 1_048_576, maxBytes: 1_048_576)
            guard request.text != nil else { throw MCPInputError.invalid("'text' is required") }
        case "spaceo_clipboard_get":
            request.cmd = "clipboard.get"
        case "spaceo_session_set_title":
            request.cmd = "session.annotate"
            request.title = try str("title", max: 120)
            guard request.title != nil else { throw MCPInputError.invalid("'title' is required") }
        case "spaceo_events":
            request.cmd = "events.poll"
            if let since = try int("since_seq") {
                guard since >= 0 else { throw MCPInputError.invalid("'since_seq' must be zero or greater") }
                request.sinceSeq = UInt64(since)
            }
        case "spaceo_read_screen":
            request.cmd = "ax"
            request.full = try flag("full")
            request.since = try str("since", max: 128)
        case "spaceo_list_targets":
            request.cmd = "targets"
        case "spaceo_attach_target":
            request.cmd = "target.attach"
            request.target = try str("target", max: 256, maxBytes: 1_024)
            guard let target = request.target, !target.isEmpty else {
                throw MCPInputError.invalid("'target' is required")
            }
        case "spaceo_screenshot":
            request.cmd = "screenshot"
            request.full = try flag("full")
            request.scale = try int("scale")
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.width = try int("width")
            request.height = try int("height")
            request.annotate = try flag("annotate")
            if let scale = request.scale, !(1...4).contains(scale) {
                throw MCPInputError.invalid("'scale' must be from 1 through 4")
            }
            if request.annotate == true, request.full == true || request.x != nil {
                throw MCPInputError.invalid("'annotate' works on a window capture; drop 'full' and the region")
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
            request.memory = true
        case "spaceo_click":
            request.cmd = "click"
            request.label = try str("label", max: 480)
            request.match = try str("match", max: 16)
            request.role = try str("role", max: 64)
            if (request.match != nil || request.role != nil), request.label == nil {
                throw MCPInputError.invalid("'match' and 'role' refine 'label'")
            }
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
            if request.element == nil && request.x == nil && request.label == nil {
                throw MCPInputError.invalid("click needs element, an exact label, or x/y coordinates")
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
        case "spaceo_select_text":
            request.cmd = "select"
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.anchorLine = try int("anchor_line")
            request.anchorCharacter = try int("anchor_character")
            request.activeLine = try int("active_line")
            request.activeCharacter = try int("active_character")
            guard request.x != nil, request.y != nil else {
                throw MCPInputError.invalid("'x' and 'y' are required")
            }
            guard request.anchorLine != nil, request.anchorCharacter != nil,
                  request.activeLine != nil, request.activeCharacter != nil else {
                throw MCPInputError.invalid(
                    "'anchor_line', 'anchor_character', 'active_line' and "
                        + "'active_character' are required")
            }
            for name in ["anchor_line", "anchor_character", "active_line",
                         "active_character"] where (try int(name) ?? 0) < 0 {
                throw MCPInputError.invalid("'\(name)' must be zero or greater")
            }

        case "spaceo_scroll", "spaceo_move", "spaceo_drag":
            request.cmd = String(name.dropFirst("spaceo_".count))
            request.x = try dbl("x")
            request.y = try dbl("y")
            request.modifiers = try modifiers()
            request.web = try flag("web")
            request.element = try str("element", max: 32)
            request.fromElement = try str("from_element", max: 32)
            request.toElement = try str("to_element", max: 32)
            let startReference = request.element ?? request.fromElement
            if startReference != nil, request.x != nil || request.y != nil {
                throw MCPInputError.invalid("use either an element reference or x/y, not both")
            }
            if startReference == nil, request.x == nil || request.y == nil {
                throw MCPInputError.invalid("'x' and 'y' are required unless an element reference is given")
            }
            if let reference = startReference, Int(reference.hasPrefix("w") ? String(reference.dropFirst()) : reference) == nil {
                throw MCPInputError.invalid("element references look like \"3\" or \"w3\"")
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
                if request.toElement != nil, request.toX != nil || request.toY != nil {
                    throw MCPInputError.invalid("use either 'to_element' or to_x/to_y, not both")
                }
                guard request.toElement != nil || (request.toX != nil && request.toY != nil) else {
                    throw MCPInputError.invalid("'to_x' and 'to_y' are required unless 'to_element' is given")
                }
            } else if request.fromElement != nil || request.toElement != nil {
                throw MCPInputError.invalid("from_element/to_element apply to spaceo_drag; use 'element'")
            }
        case "spaceo_type":
            request.cmd = "type"
            request.text = try str("text", max: 8_000, maxBytes: 32_000)
            request.web = try flag("web")
            request.replace = try flag("replace")
            request.submit = try flag("submit")
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
            request.holdMs = try int("hold_ms")
            request.keyAction = try str("action", max: 8)
            if let hold = request.holdMs, !(0...5_000).contains(hold) {
                throw MCPInputError.invalid("'hold_ms' must be from 0 through 5000")
            }
            if let action = request.keyAction, !["tap", "down", "up"].contains(action) {
                throw MCPInputError.invalid("'action' must be tap, down or up")
            }
            guard let key = request.key, !key.isEmpty else {
                throw MCPInputError.invalid("'key' is required")
            }
        case "spaceo_list_windows":
            request.cmd = "windows"
            request.pid = try int32("pid")
        case "spaceo_verify_isolation":
            request.cmd = "verify"
        case "spaceo_pool_status":
            request.cmd = "pool"
        default:
            // Exhaustive validation above keeps this unreachable.
            throw MCPInputError.invalid("unknown tool '\(MCPDiagnostic.name(name))'")
        }
        request.strictIsolation = try flag("strict")
        if let raw = arguments["require_isolation"], !(raw is NSNull) {
            guard let names = raw as? [String], !names.isEmpty, names.count <= 6 else { throw MCPInputError.invalid("require_isolation needs 1 through 6 dimension names") }
            request.requiredIsolation = try names.map {
                guard let value = IsolationDimension(rawValue: $0) else { throw MCPInputError.invalid("unknown isolation dimension") }
                return value
            }
        }
        request.requireWindow = try flag("require_window")
        request.allowNoWindows = try flag("allow_no_windows")
        request.timeout = try dbl("timeout")
        request.duration = try dbl("duration")
        request.snapshotID = try str("snapshot", max: 128)
        request.label = try str("label", max: 480)
        request.geometryToken = try str("geometry", max: 128)
        if let supplied = arguments["arguments"], !(supplied is NSNull) {
            guard let values = supplied as? [String] else { throw MCPInputError.invalid("arguments must be strings") }
            try LaunchOptions.validate(arguments: values, timeout: request.timeout ?? 15)
            request.arguments = values
        }
        return request
    }
}

/// Streaming, bounded newline reader for MCP stdio.
///
/// Foundation's global `readLine()` accumulates an arbitrarily large line. MCP arguments are
/// tiny by design, so accepting unbounded input only turns malformed clients into an OOM risk.
final class BoundedLineReader {
    enum ReaderError: Error, Equatable, CustomStringConvertible, LocalizedError {
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

        /// A malformed line says nothing about the next one. A failed `read()` says the
        /// descriptor is unusable, and it will keep saying so on every call.
        var isFatal: Bool {
            switch self {
            case .lineTooLong, .invalidUTF8: return false
            case .io: return true
            }
        }
    }

    private let handle: FileHandle
    private let maximumBytes: Int
    private var buffer = Data()
    /// Offset of the next unread line. Coalesced requests advance this cursor instead of
    /// shifting the entire remaining read buffer once per line.
    private var consumedBytes = 0
    /// Offset through which buffer bytes have been checked for the next terminator.
    private var scannedBytes = 0
    private var discardingOversizedLine = false
    private var descriptorFailure: ReaderError?

    init(handle: FileHandle, maximumBytes: Int = 1_048_576) {
        self.handle = handle
        self.maximumBytes = max(1, maximumBytes)
    }

    func next() throws -> String? {
        try next { data in
            guard let text = String(data: data, encoding: .utf8) else { throw ReaderError.invalidUTF8 }
            return text
        }
    }

    func nextInputLine() throws -> MCPInputLine? {
        try next { data in
            guard let line = MCPInputLine(data: data) else { throw ReaderError.invalidUTF8 }
            return line
        }
    }

    private func next<Value>(decode: (Data) throws -> Value) throws -> Value? {
        // A descriptor that failed once fails identically forever; re-reading it only burns CPU.
        if let descriptorFailure { throw descriptorFailure }
        // Allocate only when reading, and reuse across chunks of this message. Buffered lines
        // need no scratch allocation and idle readers retain no scratch storage.
        var bytes: [UInt8] = []
        while true {
            if let newline = buffer.dropFirst(scannedBytes).firstIndex(of: 0x0A) {
                let start = buffer.index(buffer.startIndex, offsetBy: consumedBytes)
                let next = buffer.distance(from: buffer.startIndex, to: newline) + 1
                defer {
                    consumedBytes = next
                    scannedBytes = next
                    if consumedBytes == buffer.count {
                        buffer.removeAll(keepingCapacity: false)
                        consumedBytes = 0
                        scannedBytes = 0
                    }
                }
                if discardingOversizedLine || buffer.distance(from: start, to: newline) > maximumBytes {
                    discardingOversizedLine = false
                    throw ReaderError.lineTooLong(maximumBytes)
                }
                return try decode(buffer[start..<newline])
            }

            scannedBytes = buffer.count
            // All buffered complete lines have been consumed. Compact only the partial tail
            // before reading more, and keep the scan offset relative to that tail.
            if consumedBytes > 0 {
                buffer = Data(buffer.dropFirst(consumedBytes))
                scannedBytes -= consumedBytes
                consumedBytes = 0
            }
            if discardingOversizedLine || buffer.count > maximumBytes {
                buffer.removeAll(keepingCapacity: false)
                scannedBytes = 0
                discardingOversizedLine = true
            }

            // Read through the descriptor into a fixed-size chunk. `availableData` can return
            // an unbounded amount when stdin is a regular file, defeating the line-size cap
            // before `buffer` gets a chance to inspect it.
            if bytes.isEmpty { bytes = [UInt8](repeating: 0, count: 65_536) }
            var count = 0
            while true {
                count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count >= 0 { break }
                let code = errno
                if code == EINTR { continue }
                // A client is free to hand us a nonblocking stdin, and then "no data yet"
                // arrives as an error. Waiting for readability is the difference between an
                // idle process and one pinned to a core.
                if code == EAGAIN {  // EWOULDBLOCK is the same value on Darwin.
                    var descriptor = pollfd(
                        fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    if poll(&descriptor, 1, -1) < 0 && errno != EINTR {
                        throw recordFailure(.io(errno))
                    }
                    continue
                }
                throw recordFailure(.io(code))
            }
            guard count > 0 else {
                guard !buffer.isEmpty || discardingOversizedLine else { return nil }
                scannedBytes = 0
                if discardingOversizedLine {
                    buffer.removeAll(keepingCapacity: false)
                    discardingOversizedLine = false
                    throw ReaderError.lineTooLong(maximumBytes)
                }
                let tail = buffer
                buffer.removeAll(keepingCapacity: false)
                return try decode(tail)
            }
            let incoming = bytes.prefix(count)
            // The buffer holds only the partial current line here. Refuse an oversized
            // prefix before extending it, and scan discarded chunks without retaining them.
            // Ordinary chunks fit without this extra scan; next iteration finds their newline.
            if discardingOversizedLine || count > maximumBytes - buffer.count {
                let newline = incoming.firstIndex(of: 0x0A)
                if discardingOversizedLine || (newline ?? count) > maximumBytes - buffer.count {
                    buffer.removeAll(keepingCapacity: false)
                    consumedBytes = 0
                    scannedBytes = 0
                    if let newline {
                        // Preserve coalesced following lines, but never copy the rejected prefix.
                        buffer.append(contentsOf: bytes[(newline + 1)..<count])
                        discardingOversizedLine = false
                        throw ReaderError.lineTooLong(maximumBytes)
                    }
                    discardingOversizedLine = true
                    continue
                }
                if let newline {
                    // A valid boundary-sized line need not grow just to store its terminator
                    // or coalesced next message. Decode its body and retain only the tail.
                    buffer.append(contentsOf: bytes[0..<newline])
                    let line = buffer
                    buffer = Data(bytes[(newline + 1)..<count])
                    consumedBytes = 0
                    scannedBytes = 0
                    return try decode(line)
                }
            }
            buffer.append(contentsOf: incoming)
        }
    }

    private func recordFailure(_ error: ReaderError) -> ReaderError {
        descriptorFailure = error
        return error
    }
}
