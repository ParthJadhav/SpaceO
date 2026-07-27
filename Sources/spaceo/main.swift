import Foundation
import AppKit
import CoreGraphics
import SpaceOKit
import SpaceOMCP

// MARK: - Tiny argument parser

struct Args {
    private(set) var positional: [String] = []
    private var flags: [String: String] = [:]
    private var bools: Set<String> = []

    init(_ argv: [String]) {
        var index = 0
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                positional.append(contentsOf: argv[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if index + 1 < argv.count
                    && (!argv[index + 1].hasPrefix("-")
                        || Double(argv[index + 1]) != nil) {
                    flags[name] = argv[index + 1]
                    index += 2
                    continue
                }
                bools.insert(name)
            } else if token.hasPrefix("-") && token.count == 2 {
                let name = String(token.dropFirst())
                if index + 1 < argv.count {
                    flags[name] = argv[index + 1]
                    index += 2
                    continue
                }
                bools.insert(name)
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func string(_ name: String, _ alt: String? = nil) -> String? {
        flags[name] ?? alt.flatMap { flags[$0] }
    }
    func int(_ name: String) -> Int? { flags[name].flatMap { Int($0) } }
    func double(_ name: String) -> Double? { flags[name].flatMap { Double($0) } }
    func bool(_ name: String) -> Bool { bools.contains(name) || flags[name] == "true" }
    func wasSupplied(_ name: String) -> Bool {
        flags[name] != nil || bools.contains(name)
    }
    var suppliedNames: Set<String> {
        Set(flags.keys).union(bools)
    }
    var hasJSON: Bool { bool("json") }
}

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
    print(String(format: "session %@  display %u (%@)  %.0fx%.0f at (%.0f,%.0f)  spaces=%@ ownSpace=%@",
                 session.id, session.displayID, tile,
                 session.width, session.height, session.x, session.y,
                 session.spaces.map(String.init).joined(separator: ","),
                 session.hasOwnSpace ? "yes" : "no"))
    for app in session.apps {
        print("   app  pid \(app.pid)  \(app.name)\(app.startedByUs ? "" : "  (adopted)")")
    }
    printWindows(session.windows, indent: "   ")
}

func emit(_ response: Response, json: Bool) -> Never {
    if json {
        if let data = try? Wire.encoder.encode(response),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(response.ok ? 0 : 1)
    }

    if !response.ok { fail(response.error ?? "unknown failure") }

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
    if let drift = response.drift {
        if drift.isEmpty {
            print("  isolation: intact (user undisturbed)")
        } else {
            print("  ISOLATION BREACH:")
            for item in drift { print("    - \(item)") }
        }
    }
    if let ambient = response.ambient, !ambient.isEmpty {
        for item in ambient { print("  note: \(item)") }
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

  spaceo session create [--session ID]    take a tile on a shared agent display
  spaceo session list
  spaceo session destroy [--session ID] [--all] [--keep-apps]

  spaceo pool                            displays, capacity and occupancy
  spaceo pool set <N>                    sessions per display for new displays

  spaceo run <app> [files...]            launch an app onto a session, no activation
  spaceo adopt --pid N                   move an already-running app onto a session
  spaceo windows                         list the session's windows
  spaceo ax [--window W] [--full]        indexed accessibility tree
  spaceo click (--element N | --element wN | --x X --y Y) [--button right] [--count 2]
                                         N = accessibility index, wN = page element
  spaceo type "text" [--web]             --web types into the page, not the app chrome
  spaceo key cmd+s [--web]
  spaceo screenshot [-o out.png] [--window W] [--full]
  spaceo verify                          audit the session's isolation
  spaceo repark                          pull escaped windows back

  spaceo demo [--app TextEdit] [--keep] [--sessions N]
                                         self-contained end-to-end proof, no daemon needed

Global: --session ID   --socket PATH   --json
Env:    SPACEO_SOCKET   SPACEO_SESSIONS_PER_DISPLAY   SPACEO_DISPLAY_SIZE (WxH)
"""

// MARK: - Dispatch

/// File-scope so the atexit handler (a C function pointer, which cannot capture) can reach it.
var daemonServer: Transport.Server?
/// Signal sources must remain strongly retained for the daemon's whole optimized lifetime.
/// A local whose last use precedes `RunLoop.run()` is released by production builds.
var daemonShutdownSources: [DispatchSourceSignal] = []

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
let args = Args(Array(argv.dropFirst()))

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

func validateFlags(_ allowed: Set<String>) {
    let unexpected = args.suppliedNames.subtracting(allowed)
    guard unexpected.isEmpty else {
        fail("unknown option(s): "
             + unexpected.sorted().map { "--\($0)" }.joined(separator: ", "))
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

switch command {

case "version", "--version":
    validateFlags(["json"])
    print(args.hasJSON ? #"{"version":"1.0.0"}"# : "spaceo 1.0.0")
    exit(0)

case "doctor":
    validateFlags(["socket", "json"])
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
                ["name": $0.name, "available": $0.available, "detail": $0.detail]
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
    }
    exit(capabilities.canDrive ? 0 : 1)

case "daemon":
    validateFlags(["socket", "display-size", "sessions-per-display"])
    if args.positional.first == "stop" {
        remote { $0.cmd = "daemon.stop" }
    }

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
              width > 0, height > 0 else {
            fail("--display-size wants WxH, e.g. 2560x1440")
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

    let pool = DisplayPool(sessionsPerDisplay: 1, displaySize: displaySize)
    do { try pool.setSessionsPerDisplay(perDisplay) } catch { fail("\(error)") }
    let manager = SessionManager(pool: pool)
    let server = Transport.Server(path: socketPath) { request in
        let response = await manager.handle(request)
        if request.cmd == "daemon.stop" {
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
    print("spaceo daemon listening on \(socketPath)")
    print("  \(perDisplay) session(s) per \(Int(displaySize.width))x\(Int(displaySize.height)) display")
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
                await manager.destroyAll(quitApps: true)
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
    guard let sub = args.positional.first else { fail("session needs: create | list | destroy") }
    switch sub {
    case "create":
        validateFlags(["socket", "json", "session", "name"])
        remote { request in
            request.cmd = "session.create"
            request.session = stringArgument("session", "name")
        }
    case "list":
        validateFlags(["socket", "json"])
        remote { $0.cmd = "session.list" }
    case "destroy":
        validateFlags(["socket", "json", "session", "all", "keep-apps"])
        remote { request in
            request.cmd = "session.destroy"
            request.session = stringArgument("session")
            request.full = args.bool("all")
            request.quitApps = !args.bool("keep-apps")
        }
    default:
        fail("unknown session subcommand '\(sub)'")
    }

case "pool":
    validateFlags(["socket", "json"])
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
    validateFlags(["socket", "json", "session"])
    guard let app = args.positional.first else { fail("run needs an application name or path") }
    remote { request in
        request.cmd = "run"
        request.session = stringArgument("session")
        request.app = app
        request.files = Array(args.positional.dropFirst())
    }

case "adopt":
    validateFlags(["socket", "json", "session", "pid"])
    guard let pid = pidArgument() else { fail("adopt needs --pid N") }
    remote { request in
        request.cmd = "adopt"
        request.session = stringArgument("session")
        request.pid = pid
    }

case "windows":
    validateFlags(["socket", "json", "session"])
    remote { request in
        request.cmd = "windows"
        request.session = stringArgument("session")
    }

case "ax":
    validateFlags(["socket", "json", "session", "window", "full"])
    remote { request in
            request.cmd = "ax"
            request.session = stringArgument("session")
            request.window = windowArgument()
        request.full = args.bool("full")
    }

case "click":
    validateFlags([
        "socket", "json", "session", "window", "element", "web",
        "x", "y", "button", "count",
    ])
    remote { request in
            request.cmd = "click"
            request.session = stringArgument("session")
            request.window = windowArgument()
        request.element = stringArgument("element")
        request.web = args.bool("web") ? true : nil
        request.x = doubleArgument("x")
        request.y = doubleArgument("y")
        request.button = stringArgument("button")
        request.count = intArgument("count")
    }

case "type":
    validateFlags(["socket", "json", "session", "window", "web"])
    guard let text = args.positional.first else { fail("type needs a string") }
    remote { request in
            request.cmd = "type"
            request.session = stringArgument("session")
            request.window = windowArgument()
        request.text = text
        request.web = args.bool("web") ? true : nil
    }

case "key":
    validateFlags(["socket", "json", "session", "window", "web"])
    guard let combo = args.positional.first else { fail("key needs a combo like cmd+s") }
    remote { request in
            request.cmd = "key"
        request.session = stringArgument("session")
        request.window = windowArgument()
        request.key = combo
        request.web = args.bool("web") ? true : nil
    }

case "screenshot":
    validateFlags(["socket", "json", "session", "window", "output", "o", "full"])
    remote { request in
            request.cmd = "screenshot"
            request.session = stringArgument("session")
            request.window = windowArgument()
        request.output = stringArgument("output", "o")
        request.full = args.bool("full")
    }

case "verify":
    validateFlags(["socket", "json", "session"])
    remote { request in
        request.cmd = "verify"
        request.session = stringArgument("session")
    }

case "repark":
    validateFlags(["socket", "json", "session"])
    remote { request in
        request.cmd = "repark"
        request.session = stringArgument("session")
    }

case "mcp":
    validateFlags(["socket"])
    MCPServer.run(socketPath: socketPath)

case "demo":
    validateFlags(["app", "keep", "no-capture", "sessions"])
    Demo.run(appName: stringArgument("app") ?? "TextEdit",
             keep: args.bool("keep"),
             capture: !args.bool("no-capture"),
             perDisplay: intArgument("sessions") ?? 1)

case "help", "--help", "-h":
    validateFlags([])
    print(usage)
    exit(0)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
