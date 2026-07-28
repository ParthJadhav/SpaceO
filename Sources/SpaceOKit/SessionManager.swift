import Foundation
import AppKit
import CoreGraphics
import SpaceOPrivate

/// Owns every live session and executes commands against them.
///
/// An actor because sessions touch the WindowServer and AX, and interleaving two agents'
/// window moves would produce exactly the kind of flakiness that is miserable to debug.
public actor SessionManager {

    private var sessions: [String: AgentSession] = [:]
    private var counter = 0
    private let pool: DisplayPool
    /// Actor isolation does not serialize across `await`; this gate deliberately does. It is
    /// process-wide rather than per-session because display allocation, user input routing, and
    /// shutdown all mutate shared host resources, so ordering only same-session commands would
    /// still allow cross-session lifecycle races.
    private let operationGate = SessionOperationGate()
    private var isShuttingDown = false
    private var idleDisplayRetirement: Task<Void, Never>?
    private let idleDisplayGraceNanoseconds: UInt64 = 15_000_000_000
    private var displayLifecycleFailures: Set<CGDirectDisplayID> = []
    private var janitor: Task<Void, Never>?
    private let janitorIntervalNanoseconds: UInt64 = 3_000_000_000

    public init(pool: DisplayPool = DisplayPool(), runJanitor: Bool = true) {
        self.pool = pool
        guard runJanitor else { return }
        Task { [weak self] in await self?.startJanitor() }
    }

    // MARK: - Janitor

    /// The runtime janitor the architecture always promised.
    ///
    /// Per-app `WindowWatcher`s handle containment; this loop covers what they structurally
    /// cannot — an app that exited (nothing left to notify us), and a session whose watchers
    /// all failed to register. It is bounded (one pass per interval, no concurrency) and
    /// cancellable, so daemon shutdown leaves no task behind.
    private func startJanitor() {
        janitor?.cancel()
        let interval = janitorIntervalNanoseconds
        janitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.runJanitorPass()
            }
        }
    }

    /// One pass over every session. Exposed so a test can drive the janitor deterministically
    /// instead of sleeping on a timer.
    @discardableResult
    public func runJanitorPass() async -> Int {
        let commandLease = await operationGate.enter()
        defer { commandLease.finish() }
        guard !isShuttingDown else { return 0 }
        return runJanitorPassNow()
    }

    private func runJanitorPassNow() -> Int {
        sessions.values.reduce(0) { count, session in
            guard let lifecycleLease = try? session.beginOperation() else { return count }
            defer { lifecycleLease.finish() }
            return count + session.runJanitorPass()
        }
    }

    public func stopJanitor() {
        janitor?.cancel()
        janitor = nil
    }

    public var isEmpty: Bool { sessions.isEmpty }
    public var count: Int { sessions.count }
    public var displayCount: Int { pool.displayCount }
    public var sessionsPerDisplay: Int { pool.sessionsPerDisplay }

    public func setSessionsPerDisplay(_ value: Int) throws {
        try pool.setSessionsPerDisplay(value)
    }

    public func poolReport() -> [DisplayPool.DisplayReport] { pool.report() }

    // MARK: - Lifecycle

    @discardableResult
    public func create(name: String?) async throws -> AgentSession {
        let commandLease = await operationGate.enter()
        defer { commandLease.finish() }
        guard !isShuttingDown else {
            throw SpaceOError.badRequest("the daemon is shutting down")
        }
        return try createNow(name: name)
    }

    private func createNow(name: String?) throws -> AgentSession {
        let namedID: String?
        if let name {
            let trimmed = try Self.canonicalSessionID(name)
            guard sessions[trimmed] == nil else {
                throw SpaceOError.badRequest("session '\(trimmed)' already exists")
            }
            namedID = trimmed
        } else {
            namedID = nil
        }
        var nextCounter: Int?
        let id: String
        if let namedID {
            id = namedID
        } else {
            var candidateNumber = counter
            var candidateID: String
            repeat {
                guard candidateNumber < Int.max else {
                    throw SpaceOError.badRequest("automatic session id space is exhausted")
                }
                candidateNumber += 1
                candidateID = "agent-\(candidateNumber)"
            } while sessions[candidateID] != nil
            id = candidateID
            nextCounter = candidateNumber
        }
        // The pool reuses a display that still has a free tile, and only builds a new one
        // when they are all full.
        let slot = try pool.allocate()
        let session = AgentSession(id: id, slot: slot)
        sessions[id] = session
        if let nextCounter { counter = nextCounter }
        return session
    }

    static func canonicalSessionID(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw SpaceOError.badRequest(
                "session id must not be empty or contain control characters "
                + "or path separators")
        }
        return trimmed
    }

    public func session(_ id: String) throws -> AgentSession {
        let canonical = try Self.canonicalSessionID(id)
        guard let session = sessions[canonical] else {
            throw SpaceOError.unknownSession(canonical)
        }
        return session
    }

    /// The session to act on when the caller did not name one — valid only when exactly
    /// one exists, so a multi-agent setup can never be ambiguous by accident.
    public func resolve(_ id: String?) throws -> AgentSession {
        if let id { return try session(id) }
        guard sessions.count == 1, let only = sessions.values.first else {
            throw SpaceOError.badRequest(
                sessions.isEmpty
                ? "no sessions — create one with `spaceo session create`"
                : "\(sessions.count) sessions exist; name one explicitly")
        }
        return only
    }

    public func destroy(_ id: String, quitApps: Bool) async throws {
        let commandLease = await operationGate.enter()
        defer { commandLease.finish() }
        try destroyNow(id, quitApps: quitApps)
    }

    private func destroyNow(_ id: String, quitApps: Bool) throws {
        let canonical = try Self.canonicalSessionID(id)
        guard let session = sessions.removeValue(forKey: canonical) else {
            throw SpaceOError.unknownSession(canonical)
        }
        session.destroy(quitApps: quitApps)      // empties the tile
        pool.release(session.slot, retainEmpty: true)
        scheduleIdleDisplayRetirement()
    }

    @discardableResult
    public func destroyAll(quitApps: Bool) async -> [CGDirectDisplayID] {
        let commandLease = await operationGate.enter()
        defer { commandLease.finish() }
        return destroyAllNow(quitApps: quitApps)
    }

    private func destroyAllNow(quitApps: Bool) -> [CGDirectDisplayID] {
        idleDisplayRetirement?.cancel()
        idleDisplayRetirement = nil
        stopJanitor()
        let destroying = Array(sessions.values)
        sessions.removeAll()
        for session in destroying {
            session.destroy(quitApps: quitApps)
        }
        let failed = pool.releaseAll()
        displayLifecycleFailures.formUnion(failed)
        return failed
    }

    private func scheduleIdleDisplayRetirement() {
        idleDisplayRetirement?.cancel()
        let delay = idleDisplayGraceNanoseconds
        idleDisplayRetirement = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.retireIdleDisplays()
        }
    }

    private func retireIdleDisplays() {
        // Keep one stable warm display for the daemon's lifetime. This avoids an attach/detach
        // cycle for every short-lived MCP session while still retiring excess peak capacity.
        displayLifecycleFailures.formUnion(pool.retireEmptyDisplays(keeping: 1))
        idleDisplayRetirement = nil
    }

    /// Recorded teardown failures, pruned against the live display inventory. A teardown that
    /// timed out may still have completed later; keep reporting and refusing only while the
    /// display is genuinely attached, because claiming a detached display "remains attached"
    /// forever would be false. Every reader must come through here so they agree.
    private func liveDisplayLifecycleFailures() -> Set<CGDirectDisplayID> {
        guard !displayLifecycleFailures.isEmpty else { return [] }
        displayLifecycleFailures.formIntersection(Stage.onlineDisplayIDs())
        return displayLifecycleFailures
    }

    public func infos() async -> [SessionInfo] {
        let commandLease = await operationGate.enter()
        defer { commandLease.finish() }
        return infosNow()
    }

    private func infosNow() -> [SessionInfo] {
        sessions.values
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { session in
                guard let lifecycleLease = try? session.beginOperation() else { return nil }
                defer { lifecycleLease.finish() }
                session.refreshWindows()
                return SessionInfo(session)
            }
    }

    // MARK: - Command dispatch

    public func handle(_ request: Request) async -> Response {
        let commandLease = await operationGate.enter()
        defer { commandLease.finish() }
        do {
            if isShuttingDown, request.cmd != "daemon.stop" {
                throw SpaceOError.badRequest("the daemon is shutting down")
            }
            return try await execute(request)
        } catch {
            return .failure(error)
        }
    }

    private func execute(_ request: Request) async throws -> Response {
        switch request.cmd {

        case "ping":
            let failures = liveDisplayLifecycleFailures()
            let suffix = failures.isEmpty
                ? ""
                : ", failed display teardown: \(failures.sorted())"
            return .success(
                "spaceo daemon alive, \(sessions.count) session(s)\(suffix)")

        case "daemon.stop":
            isShuttingDown = true
            let failed = destroyAllNow(quitApps: true)
            let suffix = failed.isEmpty
                ? ""
                : "; display id(s) \(failed.sorted()) are still detaching"
            return .success("stopping SpaceO daemon\(suffix)")

        case "session.create":
            let session = try createNow(name: request.session)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.message = session.hasExclusiveDisplay
                ? "created '\(session.id)' with exclusive display \(session.stage.displayID)"
                : "created '\(session.id)' on display \(session.stage.displayID), tile \(session.slot.index + 1)/\(session.slot.capacity)"
            return response

        case "session.list":
            var response = Response(ok: true)
            response.sessions = infosNow()
            return response

        case "session.destroy":
            if request.session == nil && (request.full ?? false) {
                let failed = destroyAllNow(quitApps: request.quitApps ?? true)
                let suffix = failed.isEmpty
                    ? ""
                    : "; display id(s) \(failed.sorted()) are still detaching"
                return .success("destroyed all sessions\(suffix)")
            }
            let session = try resolve(request.session)
            let id = session.id
            try destroyNow(id, quitApps: request.quitApps ?? true)
            return .success("destroyed '\(id)'")

        case "run":
            guard let appName = request.app else { throw SpaceOError.badRequest("run needs an app") }
            let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAppName.isEmpty, appName.count <= 4_096,
                  appName.utf8.count <= 16_384 else {
                throw SpaceOError.badRequest(
                    "app must be 1 through 4096 characters and at most 16384 UTF-8 bytes")
            }
            let filePaths = request.files ?? []
            guard filePaths.count <= 256 else {
                throw SpaceOError.badRequest("run accepts at most 256 file paths")
            }
            guard filePaths.allSatisfy({
                $0.count <= 4_096 && $0.utf8.count <= 16_384
            }) else {
                throw SpaceOError.badRequest(
                    "every file path must be at most 4096 characters and 16384 UTF-8 bytes")
            }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            guard let appURL = AppLauncher.resolve(trimmedAppName) else {
                throw SpaceOError.launchFailed(
                    "could not find an application named '\(trimmedAppName)'")
            }
            let files = filePaths.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            }
            let before = IsolationSnapshot.capture()
            let app = try await session.launch(app: appURL, opening: files)
            let after = IsolationSnapshot.capture()

            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.isolation = after.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = after.ambientChanges(from: before)
            var message = "launched \(app.name) (pid \(app.pid)) onto '\(session.id)'"
            if let restored = session.lastLaunchRestoredFocus {
                message += "\n  note: \(app.name) grabbed focus on startup; handed it back to \(restored)"
            }
            response.message = message
            failOnIsolationBreach(&response, action: "launch")
            return response

        case "adopt":
            guard let pid = request.pid, pid > 0 else {
                throw SpaceOError.badRequest("adopt needs a positive --pid")
            }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let app = try session.adopt(pid: pid)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.message = "adopted \(app.name) (pid \(pid))"
            return response

        case "windows":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            session.sweepStrayWindows()
            session.refreshWindows()
            var response = Response(ok: true)
            response.windows = session.windows.map { WindowInfo($0, session: session) }
            return response

        case "pool":
            var response = Response(ok: true)
            response.displays = pool.report()
            let usage = pool.usage()
            response.usage = usage
            response.limits = ResourceLimitsReport(pool.budget)
            response.message = Self.poolSummary(displays: pool.displayCount,
                                                sessions: pool.sessionCount,
                                                perDisplay: pool.sessionsPerDisplay,
                                                usage: usage,
                                                budget: pool.budget)
            return response

        case "pool.configure":
            guard let value = request.count else {
                throw SpaceOError.badRequest("pool.configure needs a session count")
            }
            try setSessionsPerDisplay(value)
            var response = Response(ok: true)
            response.message = "new displays will host \(value) session(s) each"
            response.displays = pool.report()
            response.usage = pool.usage()
            response.limits = ResourceLimitsReport(pool.budget)
            return response

        case "ax":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            let snapshot = try session.snapshotAX(window: window)
            var outline = snapshot.outline(includeNonActionable: request.full ?? false)
            var message = "\(snapshot.actionableCount) actionable element(s) in window \(window.windowID)"

            // For a browser we launched, the AX tree only covers the browser's own chrome.
            // The page itself has to come from DevTools, so append it under its own indices.
            if let bridge = session.webBridge(for: window.pid) {
                do {
                    let page = try await bridge.interactiveElements()
                    outline += "\n\npage content (click these with --element wN):\n" + page
                    message += ", plus page elements"
                } catch {
                    // Silence here would read as "the page has no elements", which is a lie.
                    outline += "\n\n(page content unavailable: \(error))"
                }
            }
            var response = Response(ok: true)
            response.outline = outline
            response.message = message
            return response

        case "click":
            let clickCount = request.count ?? 1
            guard (1...3).contains(clickCount) else {
                throw SpaceOError.badRequest("click count must be from 1 through 3")
            }
            guard request.button == nil || request.button == "left"
                    || request.button == "right" else {
                throw SpaceOError.badRequest("button must be 'left' or 'right'")
            }
            if let x = request.x, !x.isFinite {
                throw SpaceOError.badRequest("x must be a finite number")
            }
            if let y = request.y, !y.isFinite {
                throw SpaceOError.badRequest("y must be a finite number")
            }
            if let element = request.element,
               element.count > 32 || element.utf8.count > 128 {
                throw SpaceOError.badRequest(
                    "element reference must be at most 32 characters and 128 UTF-8 bytes")
            }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let before = IsolationSnapshot.capture()
            let window = try session.resolveWindow(request.window)
            let button: MouseButton = (request.button == "right") ? .right : .left

            if let reference = request.element, reference.hasPrefix("w") {
                // Page element: only DevTools can dispatch a real DOM click.
                guard let index = Int(reference.dropFirst()) else {
                    throw SpaceOError.badRequest("'\(reference)' is not a web element reference")
                }
                guard index >= 0 else {
                    throw SpaceOError.badRequest("web element indices cannot be negative")
                }
                guard let bridge = session.webBridge(for: window.pid) else {
                    throw SpaceOError.badRequest(
                        "this session has no DevTools element map; click by native element "
                        + "or coordinates instead")
                }
                try await bridge.clickElement(index: index, button: button,
                                              clickCount: clickCount)
            } else if let reference = request.element {
                guard let index = Int(reference) else {
                    throw SpaceOError.badRequest("'\(reference)' is not an element index")
                }
                guard index >= 0 else {
                    throw SpaceOError.badRequest("element indices cannot be negative")
                }
                let element = try session.element(at: index)
                try InputRouter.press(element)
            } else if let x = request.x, let y = request.y {
                if let bridge = session.webBridge(for: window.pid) {
                    // Coordinates inside a browser window belong to the page, and synthetic
                    // mouse events never arrive there. Translate into viewport space and let
                    // DevTools dispatch it.
                    let bounds = try WindowPlacement.liveBounds(of: window.windowID)
                    let viewport = try await bridge.viewportOnScreen()
                    try await bridge.click(x: bounds.origin.x + x - viewport.origin.x,
                                           y: bounds.origin.y + y - viewport.origin.y,
                                           button: button, clickCount: clickCount)
                } else {
                    try InputRouter.click(window, at: CGPoint(x: x, y: y),
                                          button: button, clickCount: clickCount)
                }
            } else {
                throw SpaceOError.badRequest("click needs --element N (or wN for page elements) or --x X --y Y")
            }
            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            failOnIsolationBreach(&response, action: "click")
            return response

        case "type":
            guard let text = request.text else { throw SpaceOError.badRequest("type needs text") }
            guard text.count <= 8_000, text.unicodeScalars.count <= 8_000,
                  text.utf8.count <= 32_000 else {
                throw SpaceOError.badRequest(
                    "text is too long (maximum 8000 characters/scalars "
                    + "and 32000 UTF-8 bytes)")
            }
            if request.web != true { try InputRouter.validateTyping(text) }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            let before = IsolationSnapshot.capture()
            if request.web == true {
                if let bridge = session.webBridge(for: window.pid) {
                    try await bridge.type(text)
                } else {
                    try InputRouter.prepareForInput(window)
                    try InputRouter.type(text, to: window.pid)
                }
            } else {
                try InputRouter.prepareForInput(window)
                try InputRouter.type(text, to: window.pid)
            }
            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            response.value = AXTree.focusedValue(pid: window.pid)
            failOnIsolationBreach(&response, action: "typing")
            return response

        case "key":
            guard let combo = request.key else { throw SpaceOError.badRequest("key needs a combo") }
            guard !combo.isEmpty, combo.count <= 64, combo.utf8.count <= 256 else {
                throw SpaceOError.badRequest(
                    "key combo must be 1 through 64 characters and at most 256 UTF-8 bytes")
            }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let window = try session.resolveWindow(request.window)
            // Parse once before choosing native versus DevTools delivery. In particular this
            // keeps Command-C/X recognition identical on both guarded production routes.
            let parsedCombo = try KeyCombo.parse(combo)
            let before = IsolationSnapshot.capture()
            if request.web == true {
                if let bridge = session.webBridge(for: window.pid) {
                    try await bridge.key(parsedCombo)
                } else {
                    try InputRouter.prepareForInput(window)
                    try InputRouter.key(parsedCombo, to: window.pid)
                }
            } else {
                try InputRouter.prepareForInput(window)
                try InputRouter.key(parsedCombo, to: window.pid)
            }
            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.isolation = now.report(comparedTo: before)
            response.drift = response.isolation?.legacyDrift
            response.ambient = now.ambientChanges(from: before)
            failOnIsolationBreach(&response, action: "key press")
            return response

        case "screenshot":
            if let output = request.output,
               output.count > 4_096 || output.utf8.count > 16_384 {
                throw SpaceOError.badRequest(
                    "screenshot output path must be at most 4096 characters "
                    + "and 16384 UTF-8 bytes")
            }
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            try Capabilities().requireCapture()
            let image: CGImage
            let label: String
            if let windowID = request.window {
                let window = try session.resolveWindow(windowID)
                image = try await Capture.window(window)
                label = "window \(windowID)"
            } else if request.full ?? false {
                // "the whole screen" means this session's tile — never a neighbour's.
                image = try await Capture.region(session.stage, session.frame)
                label = session.hasExclusiveDisplay
                    ? "display \(session.stage.displayID)"
                    : "tile \(session.slot.index + 1)/\(session.slot.capacity) of display \(session.stage.displayID)"
            } else if let window = session.primaryWindow {
                image = try await Capture.window(window)
                label = "window \(window.windowID)"
            } else {
                image = try await Capture.region(session.stage, session.frame)
                label = "tile of display \(session.stage.displayID)"
            }
            let path = request.output
                ?? NSTemporaryDirectory() + "spaceo-\(UUID().uuidString).png"
            try Capture.write(image, to: URL(fileURLWithPath: path))
            var response = Response(ok: true)
            response.path = path
            response.message = "captured \(label) (\(image.width)x\(image.height), rendered=\(Capture.looksRendered(image)))"
            return response

        case "verify":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            session.sweepStrayWindows()
            let snapshot = IsolationSnapshot.capture()
            var response = Response(ok: true)
            response.findings = session.audit()
            response.session = SessionInfo(session)
            // A point-in-time audit exposes current covered state without inventing historical
            // input-route evidence that macOS did not make observable.
            response.isolation = snapshot.currentReport()
            response.drift = response.isolation?.legacyDrift
            let auditFailures = response.findings! + (response.isolation?.failures ?? [])
            if auditFailures.isEmpty {
                response.message = response.isolation?.verdict == .partial
                    ? "session '\(session.id)' has no covered audit failures; "
                        + "isolation coverage is partial"
                    : "session '\(session.id)' passed its covered isolation audit"
            } else {
                response.message = "\(auditFailures.count) issue(s)"
            }
            if !auditFailures.isEmpty {
                response.ok = false
                response.error = "session '\(session.id)' failed its isolation audit:\n  - "
                    + auditFailures.joined(separator: "\n  - ")
            }
            return response

        case "repark":
            let session = try resolve(request.session)
            let lifecycleLease = try session.beginOperation()
            defer { lifecycleLease.finish() }
            let moved = session.reparkEscapedWindows()
            return .success("re-parked \(moved) window(s)")

        default:
            throw SpaceOError.badRequest("unknown command '\(request.cmd)'")
        }
    }

    /// The `pool` message: what is allocated, and how close that is to the limits.
    static func poolSummary(displays: Int,
                            sessions: Int,
                            perDisplay: Int,
                            usage: ResourceBudget.Usage,
                            budget: ResourceBudget) -> String {
        var lines = ["\(displays) display(s), \(sessions) session(s), \(perDisplay) per display"]
        let parts = [
            "sessions \(usage.sessions)/\(budget.maximumSessions)",
            "displays \(usage.displays)/\(budget.maximumDisplays)",
            "pixels \(usage.pixels)/\(budget.maximumTotalPixels)",
            "new displays this minute \(usage.creationsInLastMinute)/\(budget.maximumCreationsPerMinute)",
        ]
        lines.append("  budget: " + parts.joined(separator: ", "))
        if budget.isUnsafe {
            lines.append("  (unsafe operator limits are in force — "
                       + "SPACEO_UNSAFE_RESOURCE_LIMITS is set)")
        }
        return lines.joined(separator: "\n")
    }

    private func failOnIsolationBreach(_ response: inout Response, action: String) {
        let failures = response.isolation?.failures ?? response.drift ?? []
        guard !failures.isEmpty else { return }
        response.ok = false
        response.error = "isolation breach during \(action): "
            + failures.joined(separator: "; ")
    }
}
