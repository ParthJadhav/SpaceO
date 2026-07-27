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
    private var idleDisplayRetirement: Task<Void, Never>?
    private let idleDisplayGraceNanoseconds: UInt64 = 15_000_000_000
    private var displayLifecycleFailures: Set<CGDirectDisplayID> = []

    public init(pool: DisplayPool = DisplayPool()) {
        self.pool = pool
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
    public func create(name: String?) throws -> AgentSession {
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

    public func destroy(_ id: String, quitApps: Bool) throws {
        let canonical = try Self.canonicalSessionID(id)
        guard let session = sessions.removeValue(forKey: canonical) else {
            throw SpaceOError.unknownSession(canonical)
        }
        session.destroy(quitApps: quitApps)      // empties the tile
        pool.release(session.slot, retainEmpty: true)
        scheduleIdleDisplayRetirement()
    }

    @discardableResult
    public func destroyAll(quitApps: Bool) -> [CGDirectDisplayID] {
        idleDisplayRetirement?.cancel()
        idleDisplayRetirement = nil
        for (_, session) in sessions {
            session.destroy(quitApps: quitApps)
        }
        sessions.removeAll()
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

    public func infos() -> [SessionInfo] {
        sessions.values
            .sorted { $0.createdAt < $1.createdAt }
            .map { session in
                session.refreshWindows()
                return SessionInfo(session)
            }
    }

    // MARK: - Command dispatch

    public func handle(_ request: Request) async -> Response {
        do {
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
            let failed = destroyAll(quitApps: true)
            let suffix = failed.isEmpty
                ? ""
                : "; display id(s) \(failed.sorted()) are still detaching"
            return .success("stopping SpaceO daemon\(suffix)")

        case "session.create":
            let session = try create(name: request.session)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.message = session.hasExclusiveDisplay
                ? "created '\(session.id)' with exclusive display \(session.stage.displayID)"
                : "created '\(session.id)' on display \(session.stage.displayID), tile \(session.slot.index + 1)/\(session.slot.capacity)"
            return response

        case "session.list":
            var response = Response(ok: true)
            response.sessions = infos()
            return response

        case "session.destroy":
            if request.session == nil && (request.full ?? false) {
                let failed = destroyAll(quitApps: request.quitApps ?? true)
                let suffix = failed.isEmpty
                    ? ""
                    : "; display id(s) \(failed.sorted()) are still detaching"
                return .success("destroyed all sessions\(suffix)")
            }
            let session = try resolve(request.session)
            let id = session.id
            try destroy(id, quitApps: request.quitApps ?? true)
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
            response.drift = after.breaches(from: before)
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
            let app = try session.adopt(pid: pid)
            var response = Response(ok: true)
            response.session = SessionInfo(session)
            response.message = "adopted \(app.name) (pid \(pid))"
            return response

        case "windows":
            let session = try resolve(request.session)
            session.sweepStrayWindows()
            session.refreshWindows()
            var response = Response(ok: true)
            response.windows = session.windows.map { WindowInfo($0, session: session) }
            return response

        case "pool":
            var response = Response(ok: true)
            response.displays = pool.report()
            response.message = "\(pool.displayCount) display(s), \(pool.sessionCount) session(s), "
                             + "\(pool.sessionsPerDisplay) per display"
            return response

        case "pool.configure":
            guard let value = request.count else {
                throw SpaceOError.badRequest("pool.configure needs a session count")
            }
            try setSessionsPerDisplay(value)
            var response = Response(ok: true)
            response.message = "new displays will host \(value) session(s) each"
            response.displays = pool.report()
            return response

        case "ax":
            let session = try resolve(request.session)
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
            response.drift = now.breaches(from: before)
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
            response.drift = now.breaches(from: before)
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
            let window = try session.resolveWindow(request.window)
            let before = IsolationSnapshot.capture()
            if request.web == true {
                if let bridge = session.webBridge(for: window.pid) {
                    try await bridge.key(combo)
                } else {
                    try InputRouter.prepareForInput(window)
                    try InputRouter.key(KeyCombo.parse(combo), to: window.pid)
                }
            } else {
                try InputRouter.prepareForInput(window)
                try InputRouter.key(KeyCombo.parse(combo), to: window.pid)
            }
            var response = Response(ok: true)
            let now = IsolationSnapshot.capture()
            response.drift = now.breaches(from: before)
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
            session.sweepStrayWindows()
            var response = Response(ok: true)
            response.findings = session.audit()
            response.session = SessionInfo(session)
            response.message = response.findings!.isEmpty
                ? "session '\(session.id)' is healthy"
                : "\(response.findings!.count) issue(s)"
            if let findings = response.findings, !findings.isEmpty {
                response.ok = false
                response.error = "session '\(session.id)' failed its isolation audit:\n  - "
                    + findings.joined(separator: "\n  - ")
            }
            return response

        case "repark":
            let session = try resolve(request.session)
            let moved = session.reparkEscapedWindows()
            return .success("re-parked \(moved) window(s)")

        default:
            throw SpaceOError.badRequest("unknown command '\(request.cmd)'")
        }
    }

    private func failOnIsolationBreach(_ response: inout Response, action: String) {
        guard let drift = response.drift, !drift.isEmpty else { return }
        response.ok = false
        response.error = "isolation breach during \(action): " + drift.joined(separator: "; ")
    }
}
