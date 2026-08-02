import Foundation
import AppKit
import CoreGraphics
import Darwin
import SpaceOKit
import SpaceOMCP

// The argument parser and its flag table live in SpaceOKit (`CLIArguments.swift`) so they can be
// unit tested; this target is top-level code and cannot be imported by the test bundle.

// MARK: - Output

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func printWindows(_ windows: [WindowInfo], indent: String = "") {
    for window in windows {
        print(String(format: "%@win  %-6u pid %-6d %@%.0fx%.0f at (%.0f,%.0f)  %@",
                     indent, window.windowID, window.pid,
                     window.onStage ? "" : "OFF-STAGE ",
                     window.width, window.height, window.x, window.y,
                     window.title.isEmpty ? "" : "\"\(window.title)\""))
    }
}

func printSession(_ session: SessionInfo) {
    let tile = session.exclusiveDisplay
        ? "whole display"
        : "tile \(session.tileIndex + 1)/\(session.tileCapacity)"
    if session.runtimeAttached == false {
        print("session \(session.id)  DETACHED RECOVERY RECORD")
        if session.displayID != 0, session.width > 0, session.height > 0 {
            print(String(
                format: "   last-known placement only: display %u (%@) %.0fx%.0f "
                    + "at (%.0f,%.0f); not a live target",
                session.displayID, tile,
                session.width, session.height, session.x, session.y))
        }
    } else {
        print(String(
            format: "session %@  display %u (%@)  %.0fx%.0f at (%.0f,%.0f)  "
                + "spaces=%@ ownSpace=%@",
            session.id, session.displayID, tile,
            session.width, session.height, session.x, session.y,
            session.spaces.map(String.init).joined(separator: ","),
            session.hasOwnSpace ? "yes" : "no"))
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
        print("   lifecycle: \(lifecycleStatus)")
    }
    if let owner = session.controllerOwner {
        print("   owner: \(owner.label) (\(owner.kind.rawValue), id \(owner.id))")
    }
    if let lastActivityAt = session.lastActivityAt {
        print("   last activity: \(lastActivityAt.ISO8601Format())")
    }
    if let age = session.ageSeconds, age.isFinite {
        print("   age: \(Int(max(0, age).rounded(.down)))s")
    }
    if session.teardownPending {
        print("   ! cleanup pending; retry session destroy after resolving surviving resources")
    }
    for blocker in session.recoveryBlockers ?? [] {
        print("   ! \(blocker.code): \(blocker.message)")
    }
    for app in session.apps {
        let prefix = session.runtimeAttached == false ? "recorded app" : "app"
        print("   \(prefix)  pid \(app.pid)  \(app.name)"
            + "\(app.startedByUs ? "" : "  (adopted)")")
    }
    printWindows(session.windows, indent: "   ")
}

func printIsolation(_ report: IsolationReport) {
    switch report.verdict {
    case .intact:
        print("  isolation: intact (every required check has usable coverage)")
    case .partial:
        print("  isolation: partial (no covered breach; required checks remain unknown)")
    case .breached:
        print("  ISOLATION BREACH:")
    }

    for check in report.checks {
        print("    - \(check.dimension.rawValue): \(check.status.rawValue) "
            + "[\(check.coverage.rawValue)] — \(check.evidence)")
        for failure in check.failures {
            print("      ! \(failure)")
        }
    }
}

func printLegacyIsolation(_ drift: [String]) {
    if drift.isEmpty {
        print("  isolation: coverage unavailable (daemon returned no per-check report)")
    } else {
        print("  ISOLATION BREACH:")
        for item in drift { print("    - \(item)") }
    }
}

func emit(_ response: Response, json: Bool) -> Never {
    if json {
        if let data = try? Wire.encoder.encode(response),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(response.ok ? 0 : 1)
    }

    if !response.ok {
        if let isolation = response.isolation {
            printIsolation(isolation)
        } else if let drift = response.drift {
            printLegacyIsolation(drift)
        }
        let error = response.error ?? "unknown failure"
        if error.localizedCaseInsensitiveContains("controller lease") {
            fail(error + "\nPass the session's current credential with --lease <UUID>. "
                + "Lease credentials are returned only by create and heartbeat, never by list.")
        }
        fail(error)
    }

    if let message = response.message { print(message) }
    if let session = response.session { printSession(session) }
    if let sessions = response.sessions {
        if sessions.isEmpty { print("no sessions") }
        for session in sessions { printSession(session) }
    }
    if let windows = response.windows { printWindows(windows) }
    if let outline = response.outline { print(outline) }
    if let path = response.path { print(path) }
    if let displays = response.displays {
        if displays.isEmpty { print("no agent displays") }
        for display in displays {
            print(String(format: "display %-4u %.0fx%.0f at (%.0f,%.0f)  %d/%d tiles used  spaces=%@",
                         display.displayID, display.width, display.height, display.x, display.y,
                         display.used, display.capacity,
                         display.spaces.map(String.init).joined(separator: ",")))
        }
    }
    if let findings = response.findings {
        for finding in findings { print("  ! \(finding)") }
    }
    if let value = response.value, !value.isEmpty {
        let oneLine = value.replacingOccurrences(of: "\n", with: "\\n")
        print("  focused value: \(oneLine.count > 160 ? String(oneLine.prefix(160)) + "…" : oneLine)")
    }
    if let isolation = response.isolation {
        printIsolation(isolation)
    } else if let drift = response.drift {
        printLegacyIsolation(drift)
    }
    if let warnings = response.warnings, !warnings.isEmpty {
        for item in warnings { print("  unconfirmed: \(item)") }
    }
    if let ambient = response.ambient, !ambient.isEmpty {
        for item in ambient { print("  note: \(item)") }
    }
    if let lease = response.controllerLeaseID {
        print("controller lease: \(lease.uuidString.lowercased())")
        print("  Keep this credential secret. Pass it as --lease <UUID> to heartbeat "
            + "and session mutations; it cannot be recovered from `session list`.")
    }
    exit(0)
}

let usage = """
spaceo — give each agent its own screen, and leave the user's alone.

  spaceo doctor                          check capabilities and permissions
  spaceo version                         print the installed version
  spaceo mcp                             MCP server over stdio, for Claude Code / Codex / Cursor
  spaceo daemon [--socket P] [--sessions-per-display N] [--display-size WxH]
                                         run the session host (keep this alive)
  spaceo daemon stop                     stop the shared daemon and clean up its sessions

  spaceo session create [--session ID] [--controller-ttl SECONDS]
                                         take a tile and receive its controller lease
  spaceo session list
  spaceo session heartbeat [--session ID] --lease UUID
  spaceo session destroy [--session ID] [--all] [--keep-apps]

  spaceo pool                            displays, capacity and occupancy
  spaceo pool set <N>                    sessions per display for new displays

  spaceo run <app> [files...]            launch an app onto a session, no activation
  spaceo adopt --pid N                   move an already-running app onto a session
  spaceo windows                         list the session's windows
  spaceo ax [--window W] [--full]        indexed accessibility tree
  spaceo click (--element N | --element wN | --x X --y Y)
               [--button left|right|middle] [--count 2] [--modifiers cmd,shift]
                                         N = accessibility index, wN = page element
  spaceo move --x X --y Y                hover without pressing, to reveal hover-only UI
  spaceo drag --x X --y Y --to-x X --to-y Y [--button B] [--modifiers M]
  spaceo scroll --x X --y Y [--dy -600] [--dx 0] [--ticks 3]
                                         positive --dy scrolls content up
  spaceo type "text" [--web]             --web types into the page, not the app chrome
  spaceo key cmd+s [--web]
  spaceo screenshot [-o out.png] [--window W] [--full] [--scale 1|2]
                    [--x X --y Y --width W --height H]
                                         coordinates are window-local points at scale 1
  spaceo verify                          audit the session's isolation
  spaceo repark                          pull escaped windows back

  spaceo demo [--app TextEdit] [--keep] [--sessions N]
                                         self-contained end-to-end proof, no daemon needed

Controller create: --controller-id ID   --controller-label LABEL
                   --controller-kind cli|mcp|viewer|other   --controller-ttl 30...3600
Session mutations: --lease UUID
Global: --session ID   --socket PATH   --json
Env:    SPACEO_SOCKET   SPACEO_SESSIONS_PER_DISPLAY   SPACEO_DISPLAY_SIZE (WxH)
"""

// MARK: - Dispatch

/// File-scope so the atexit handler (a C function pointer, which cannot capture) can reach it.
var daemonServer: Transport.Server?
/// Signal sources must remain strongly retained for the daemon's whole optimized lifetime.
/// A local whose last use precedes `RunLoop.run()` is released by production builds.
var daemonShutdownSources: [DispatchSourceSignal] = []

/// Bind the daemon socket before touching durable state, then install the manager. This preserves
/// the socket's single-writer contract when two MCP clients race to auto-start a daemon.
final class DaemonManagerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var manager: SessionManager?

    func install(_ manager: SessionManager) {
        lock.withLock { self.manager = manager }
    }

    func handle(_ request: Request) async -> Response {
        guard let manager = lock.withLock({ manager }) else {
            return .failure(
                Transport.TransportError.socketFailed(
                    "the daemon is still fencing durable session state"))
        }
        return await manager.handle(request)
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
let args = CLIArguments(Array(argv.dropFirst()))

func stringArgument(_ name: String, _ alt: String? = nil) -> String? {
    if let value = args.string(name, alt) { return value }
    if args.wasSupplied(name) || alt.map(args.wasSupplied) == true {
        fail("--\(name) needs a value")
    }
    return nil
}

func intArgument(_ name: String) -> Int? {
    guard let raw = stringArgument(name) else { return nil }
    guard let value = Int(raw) else { fail("--\(name) must be an integer") }
    return value
}

func doubleArgument(_ name: String) -> Double? {
    guard let raw = stringArgument(name) else { return nil }
    guard let value = Double(raw), value.isFinite else {
        fail("--\(name) must be a finite number")
    }
    return value
}

/// `command` keys into `CLISpec.allowedFlags` — `"type"`, `"session.destroy"` — so the flags a
/// command accepts and how each one parses stay in one table.
func validateFlags(_ command: String) {
    guard let allowed = CLISpec.allowedFlags[command] else {
        fail("internal error: no flag spec for '\(command)'")
    }
    let unexpected = args.suppliedNames.subtracting(allowed)
    guard unexpected.isEmpty else {
        fail("unknown option(s): "
             + unexpected.sorted().map { "--\($0)" }.joined(separator: ", "))
    }
    guard args.malformedBooleanValues.isEmpty else {
        fail(args.malformedBooleanValues.sorted()
            .map { "--\($0) is a switch: pass it bare, or as --\($0)=true / --\($0)=false" }
            .joined(separator: "\n"))
    }
}

let socketPath = Wire.socketPath(stringArgument("socket"))

func remote(_ build: (inout Request) -> Void) -> Never {
    var request = Request(cmd: "")
    build(&request)
    do {
        let response = try Transport.send(request, to: socketPath, timeout: 120)
        emit(response, json: args.hasJSON)
    } catch {
        fail("\(error)")
    }
}

func int32Argument(_ name: String) -> Int32? {
    guard let raw = intArgument(name) else { return nil }
    guard let value = Int32(exactly: raw) else {
        fail("--\(name) must be an integer from \(Int32.min) through \(Int32.max)")
    }
    return value
}

/// `--modifiers cmd,shift`. Comma-separated so one flag carries the whole held set, which is
/// what a modifier-held click actually is.
func modifiersArgument() -> [String]? {
    guard let raw = stringArgument("modifiers") else { return nil }
    let names = raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !names.isEmpty else { fail("--modifiers needs at least one modifier name") }
    return names
}

func windowArgument() -> UInt32? {
    guard let raw = intArgument("window") else { return nil }
    guard raw > 0, let value = UInt32(exactly: raw) else {
        fail("--window must be an integer from 1 through \(UInt32.max)")
    }
    return value
}

func pidArgument() -> Int32? {
    guard let raw = intArgument("pid") else { return nil }
    guard raw > 0, let value = Int32(exactly: raw) else {
        fail("--pid must be an integer from 1 through \(Int32.max)")
    }
    return value
}

func leaseArgument(required: Bool = false) -> UUID? {
    guard let raw = stringArgument("lease") else {
        if required {
            fail("--lease UUID is required. Use the credential returned by session create "
                + "or the most recent session heartbeat.")
        }
        return nil
    }
    guard let lease = UUID(uuidString: raw) else {
        fail("--lease must be a UUID returned by session create or session heartbeat")
    }
    return lease
}

func controllerOwnerArgument() -> DurableSessionOwner {
    let id = stringArgument("controller-id")
        ?? "cli-\(getpid())-\(UUID().uuidString.lowercased())"
    let label = stringArgument("controller-label") ?? "spaceo CLI"
    let kind: DurableSessionOwnerKind
    if let rawKind = stringArgument("controller-kind") {
        guard let parsed = DurableSessionOwnerKind(rawValue: rawKind) else {
            fail("--controller-kind must be cli, mcp, viewer, or other")
        }
        kind = parsed
    } else {
        kind = .cli
    }

    func validate(_ value: String, flag: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed,
              !trimmed.isEmpty,
              value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            fail("--\(flag) must be trimmed, non-empty, control-free, "
                + "and at most 256 UTF-8 bytes")
        }
    }
    validate(id, flag: "controller-id")
    validate(label, flag: "controller-label")

    // The CLI is intentionally short-lived. Its PID exiting must not immediately abandon a
    // session that another invocation will continue; the requested TTL is the liveness signal.
    return DurableSessionOwner(
        id: id,
        kind: kind,
        label: label,
        processIdentity: nil
    )
}

switch command {

case "version", "--version":
    validateFlags("version")
    print(
        args.hasJSON
            ? #"{"version":"\#(SpaceOVersion.current)"}"#
            : "spaceo \(SpaceOVersion.current)")
    exit(0)

case "doctor":
    validateFlags("doctor")
    let capabilities = Capabilities()
    let poolRequest = Request(cmd: "pool")
    let daemonResponse = try? Transport.send(poolRequest, to: socketPath, timeout: 2)
    let daemonIsRunning = daemonResponse?.ok == true
    let daemonDisplayIDs = Set(
        daemonResponse?.displays?.map(\.displayID) ?? []
    )
    let attachedSpaceODisplays = Stage.spaceODisplayIDs()
    let attachedDescription = attachedSpaceODisplays.isEmpty
        ? "none"
        : attachedSpaceODisplays.map(String.init).joined(separator: ", ")
    let userOnline = Stage.nonSpaceOOnlineDisplayIDs()
    let userActive = Stage.nonSpaceOActiveDisplayIDs()
    let mirrored = Stage.mirroredNonSpaceODisplayIDs()
    let onlineDescription = userOnline.isEmpty
        ? "none" : userOnline.map(String.init).joined(separator: ", ")
    let activeDescription = userActive.isEmpty
        ? "none" : userActive.map(String.init).joined(separator: ", ")
    let mirrorDescription = mirrored.isEmpty
        ? "off"
        : "on (display ids \(mirrored.map(String.init).joined(separator: ", ")))"
    let orphanedDisplayIDs = attachedSpaceODisplays.filter {
        !daemonDisplayIDs.contains($0)
    }

    if args.hasJSON {
        let payload: [String: Any] = [
            "ok": capabilities.canDrive,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "capabilities": capabilities.items.map {
                [
                    "name": $0.name,
                    "available": $0.available,
                    "detail": $0.detail,
                    "unavailableReason":
                        $0.unavailableReason.map { $0 as Any } ?? NSNull(),
                ]
            },
            "missingSymbols": capabilities.missingSymbols,
            "canDrive": capabilities.canDrive,
            "canCapture": capabilities.canCapture,
            "builtWithARC": capabilities.builtWithARC,
            "daemon": ["socket": socketPath, "running": daemonIsRunning],
            "displays": [
                "spaceO": attachedSpaceODisplays,
                "orphanedSpaceO": orphanedDisplayIDs,
                "userOnline": userOnline,
                "userActive": userActive,
                "mirroredUser": mirrored,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            fail("could not encode doctor report")
        }
        print(text)
    } else {
        print("SpaceO capability report")
        print("  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")
        print(capabilities.report)
        print("")
        print("  daemon socket      : \(socketPath)")
        print("  daemon running     : \(daemonIsRunning ? "yes" : "no")")
        print("  SpaceO displays    : \(attachedDescription)")
        print("  user displays      : online \(onlineDescription); active \(activeDescription)")
        print("  display mirroring  : \(mirrorDescription)")
        if !orphanedDisplayIDs.isEmpty {
            print("  orphaned displays  : "
                  + orphanedDisplayIDs.map(String.init).joined(separator: ", "))
        }
        print("  resource policy    : no product limits; runtime geometry checks only")
    }
    exit(capabilities.canDrive ? 0 : 1)

case "daemon":
    if args.positional.first == "stop" {
        validateFlags("daemon.stop")
        remote { $0.cmd = "daemon.stop" }
    }
    validateFlags("daemon")

    let budget = ResourceBudget.fromEnvironment()
    var displaySize = CGSize(width: 1920, height: 1080)
    var sizeWasPinned = false
    if let raw = stringArgument("display-size")
        ?? ProcessInfo.processInfo.environment["SPACEO_DISPLAY_SIZE"] {
        sizeWasPinned = true
        let parts = raw.lowercased().split(
            separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0, height > 0,
              width <= budget.maximumDisplayEdge, height <= budget.maximumDisplayEdge else {
            fail("--display-size wants WxH in whole pixels up to "
                 + "\(budget.maximumDisplayEdge) per edge, e.g. 2560x1440")
        }
        displaySize = CGSize(width: width, height: height)
    }
    // The env var matters because an MCP client launches `spaceo mcp` with no arguments, and
    // that path auto-starts the daemon — so a flag alone would leave MCP users stuck at 1.
    let perDisplayRaw = stringArgument("sessions-per-display")
        ?? ProcessInfo.processInfo.environment["SPACEO_SESSIONS_PER_DISPLAY"]
    let perDisplay: Int
    if let perDisplayRaw {
        guard let parsed = Int(perDisplayRaw) else {
            fail("sessions per display must be a positive integer")
        }
        perDisplay = parsed
    } else {
        perDisplay = 1
    }

    // If the size was not pinned, grow the canvas to fit the requested density instead of
    // refusing it. A virtual display is not a panel someone has to buy — asking for four agents
    // should give you a bigger one, not an error.
    if !sizeWasPinned, perDisplay > 1 {
        displaySize = TileLayout.displaySize(forCapacity: perDisplay)
    }

    // Validate technical geometry before starting the daemon.
    do {
        _ = try budget.validateDisplaySize(displaySize, capacity: perDisplay)
    } catch {
        fail("\(error.localizedDescription)")
    }

    let pool = DisplayPool(sessionsPerDisplay: 1, displaySize: displaySize, budget: budget)
    do { try pool.setSessionsPerDisplay(perDisplay) } catch { fail("\(error)") }
    let holder = DaemonManagerHolder()
    let server = Transport.Server(path: socketPath) { request in
        let response = await holder.handle(request)
        if request.cmd == "daemon.stop", response.ok {
            // Give the socket response a moment to flush before ending the process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                daemonServer?.stop()
                exit(0)
            }
        }
        return response
    }
    do { try server.start() } catch { fail("\(error)") }
    daemonServer = server

    let daemonInstanceID = UUID()
    let manager: SessionManager
    let recoveryStartup: SessionRecoveryStartupResult
    do {
        let store = try SessionStore(socketPath: socketPath)
        let recovery = try DetachedSessionRecovery.live(
            daemonInstanceID: daemonInstanceID)
        let coordinator = SessionRecoveryCoordinator(
            store: store,
            recovery: recovery)
        recoveryStartup = try coordinator.startup()
        manager = try SessionManager(
            pool: pool,
            sessionStore: store,
            recoveryCoordinator: coordinator,
            daemonInstanceID: daemonInstanceID)
        holder.install(manager)
    } catch {
        server.stop()
        daemonServer = nil
        fail("could not recover durable session state: \(error.localizedDescription)")
    }

    print("spaceo daemon listening on \(socketPath)")
    print("  \(perDisplay) session(s) per \(Int(displaySize.width))x\(Int(displaySize.height)) display")
    if !recoveryStartup.ledger.sessions.isEmpty {
        print("  fenced \(recoveryStartup.ledger.sessions.count) detached session record(s)")
    }
    for blocked in recoveryStartup.blockedRecords {
        let reasons = blocked.blockers.map(\.message).joined(separator: "; ")
        print("  recovery pending for '\(blocked.sessionID)': \(reasons)")
    }
    print("(ctrl-c to stop; sessions are destroyed and their apps quit on the way out)")

    // Shut down through Dispatch, not a bare signal handler.
    //
    // Virtual displays die with the process for free, but the *apps* a session started do not:
    // a plain exit(0) leaves an invisible browser or editor running forever. So the handler has
    // to actually destroy the sessions, which means running async work — something a C signal
    // handler cannot do, but a DispatchSourceSignal can.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    daemonShutdownSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            Task {
                let response = await manager.handle(Request(cmd: "daemon.stop"))
                guard response.ok else {
                    let recovery = response.teardown?.recoveryDescription
                        ?? response.error
                        ?? "daemon teardown failed; retry `spaceo daemon stop`"
                    FileHandle.standardError.write(
                        Data(("error: " + recovery + "\n").utf8))
                    return
                }
                daemonServer?.stop()
                exit(0)
            }
        }
        source.resume()
        return source
    }
    atexit { daemonServer?.stop() }

    // Dispatch signal sources above are delivered on the main queue.
    RunLoop.main.run()

case "session":
    guard let sub = args.positional.first else {
        fail("session needs: create | list | heartbeat | destroy")
    }
    switch sub {
    case "create":
        validateFlags("session.create")
        let owner = controllerOwnerArgument()
        let ttl = doubleArgument("controller-ttl")
        if let ttl, !(30...3_600).contains(ttl) {
            fail("--controller-ttl must be from 30 through 3600 seconds")
        }
        let requestedLease = leaseArgument()
        remote { request in
            request.cmd = "session.create"
            request.session = stringArgument("session", "name")
            request.controllerOwner = owner
            request.controllerTTLSeconds = ttl
            request.controllerLeaseID = requestedLease
        }
    case "list":
        validateFlags("session.list")
        remote { $0.cmd = "session.list" }
    case "heartbeat":
        validateFlags("session.heartbeat")
        let lease = leaseArgument(required: true)
        remote { request in
            request.cmd = "session.heartbeat"
            request.session = stringArgument("session")
            request.controllerLeaseID = lease
        }
    case "destroy":
        validateFlags("session.destroy")
        remote { request in
            request.cmd = "session.destroy"
            request.session = stringArgument("session")
            request.full = args.bool("all")
            request.quitApps = !args.bool("keep-apps")
            request.controllerLeaseID = leaseArgument()
        }
    default:
        fail("unknown session subcommand '\(sub)'")
    }

case "pool":
    validateFlags("pool")
    if args.positional.first == "set" {
        guard let value = args.positional.dropFirst().first.flatMap({ Int($0) }) else {
            fail("pool set needs a number, e.g. `spaceo pool set 4`")
        }
        remote { request in
            request.cmd = "pool.configure"
            request.count = value
        }
    }
    remote { $0.cmd = "pool" }

case "run":
    validateFlags("run")
    guard let app = args.positional.first else { fail("run needs an application name or path") }
    remote { request in
        request.cmd = "run"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
        request.app = app
        request.files = Array(args.positional.dropFirst())
    }

case "adopt":
    validateFlags("adopt")
    guard let pid = pidArgument() else { fail("adopt needs --pid N") }
    remote { request in
        request.cmd = "adopt"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
        request.pid = pid
    }

case "windows":
    validateFlags("windows")
    remote { request in
        request.cmd = "windows"
        request.session = stringArgument("session")
    }

case "ax":
    validateFlags("ax")
    remote { request in
            request.cmd = "ax"
            request.session = stringArgument("session")
            request.window = windowArgument()
        request.full = args.bool("full")
    }

case "click":
    validateFlags("click")
    remote { request in
            request.cmd = "click"
            request.session = stringArgument("session")
            request.controllerLeaseID = leaseArgument()
            request.window = windowArgument()
        request.element = stringArgument("element")
        request.web = args.bool("web") ? true : nil
        request.x = doubleArgument("x")
        request.y = doubleArgument("y")
        request.button = stringArgument("button")
        request.count = intArgument("count")
        request.modifiers = modifiersArgument()
    }

case "scroll":
    validateFlags("scroll")
    remote { request in
        request.cmd = "scroll"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
        request.window = windowArgument()
        request.x = doubleArgument("x")
        request.y = doubleArgument("y")
        request.dx = int32Argument("dx")
        request.dy = int32Argument("dy")
        request.ticks = intArgument("ticks")
        request.modifiers = modifiersArgument()
        request.web = args.bool("web") ? true : nil
    }

case "move":
    validateFlags("move")
    remote { request in
        request.cmd = "move"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
        request.window = windowArgument()
        request.x = doubleArgument("x")
        request.y = doubleArgument("y")
        request.modifiers = modifiersArgument()
        request.web = args.bool("web") ? true : nil
    }

case "drag":
    validateFlags("drag")
    remote { request in
        request.cmd = "drag"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
        request.window = windowArgument()
        request.x = doubleArgument("x")
        request.y = doubleArgument("y")
        request.toX = doubleArgument("to-x")
        request.toY = doubleArgument("to-y")
        request.button = stringArgument("button")
        request.modifiers = modifiersArgument()
    }

case "type":
    validateFlags("type")
    guard let text = args.positional.first else { fail("type needs a string") }
    remote { request in
            request.cmd = "type"
            request.session = stringArgument("session")
            request.controllerLeaseID = leaseArgument()
            request.window = windowArgument()
        request.text = text
        request.web = args.bool("web") ? true : nil
    }

case "key":
    validateFlags("key")
    guard let combo = args.positional.first else { fail("key needs a combo like cmd+s") }
    remote { request in
            request.cmd = "key"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
        request.window = windowArgument()
        request.key = combo
        request.web = args.bool("web") ? true : nil
    }

case "screenshot":
    validateFlags("screenshot")
    remote { request in
            request.cmd = "screenshot"
            request.session = stringArgument("session")
            request.window = windowArgument()
        request.output = stringArgument("output", "o")
        request.full = args.bool("full")
        request.scale = intArgument("scale")
        request.x = doubleArgument("x")
        request.y = doubleArgument("y")
        request.width = intArgument("width")
        request.height = intArgument("height")
    }

case "verify":
    validateFlags("verify")
    remote { request in
        request.cmd = "verify"
        request.session = stringArgument("session")
    }

case "repark":
    validateFlags("repark")
    remote { request in
        request.cmd = "repark"
        request.session = stringArgument("session")
        request.controllerLeaseID = leaseArgument()
    }

case "mcp":
    validateFlags("mcp")
    MCPServer.run(socketPath: socketPath)

case "demo":
    validateFlags("demo")
    Demo.run(appName: stringArgument("app") ?? "TextEdit",
             keep: args.bool("keep"),
             capture: !args.bool("no-capture"),
             perDisplay: intArgument("sessions") ?? 1)

case "help", "--help", "-h":
    validateFlags("help")
    print(usage)
    exit(0)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
