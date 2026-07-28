import Foundation
import AppKit
import CoreGraphics

/// Drives Chromium web content through the DevTools Protocol.
///
/// Why this exists: measured against Google Chrome on macOS 27, synthetic input reaches a
/// Chromium browser's *chrome* but not its *web content*.
///
///   keyboard via CGEventPostToPid  → works (the address bar receives text)
///   AXPress on a toolbar control   → works
///   AXPress on a DOM button        → no DOM click
///   synthetic mouse at coordinates → no DOM click, even stamped with the window id
///
/// The renderer validates event provenance and drops anything the WindowServer did not vouch
/// for. Rather than pretend a click landed, SpaceO talks to the browser the way browsers expect
/// to be automated. This only works for browsers SpaceO launched itself, because the debugging
/// port has to be set at launch — an adopted browser gets an honest refusal instead.
public actor ChromiumBridge {

    public struct Target: Sendable {
        public let id: String
        public let title: String
        public let url: String
        let webSocketURL: URL
    }

    /// Largest `/json/list` body we will read. Enforced *while* reading, not after.
    static let maximumTargetListBytes = 1_048_576

    public let port: Int
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var nextID = 0
    /// The page this bridge is bound to. Every command belongs to this target and nothing else;
    /// once set it is never silently re-pointed at whatever happens to be first in a later
    /// target list.
    private var attachedTargetID: String?

    /// The page this bridge drives, or nil when it is not attached.
    public var boundTargetID: String? { attachedTargetID }

    /// FIFO of callers waiting for the single in-flight DevTools command to finish.
    ///
    /// The protocol here is strictly request/reply on one WebSocket, but actor reentrancy means
    /// a second command can start while the first is suspended in `await socket.receive()`.
    /// Interleaved receivers would each consume — and drop — the other's reply, turning
    /// concurrent commands into spurious timeouts.
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandInFlight = false

    public init(port: Int) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        // A URLSession keeps its delegate machinery alive until it is invalidated; without this,
        // every browser launch leaks a session for the daemon's lifetime. The explicit cancel
        // first sends a graceful close frame; invalidateAndCancel alone drops the socket cold.
        // (deinit cannot call the actor-isolated detach().)
        socket?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    // MARK: - Discovery

    /// Page targets the browser is currently showing.
    ///
    /// The body is read incrementally and abandoned the moment it crosses the size limit. The
    /// previous version buffered the whole response and *then* checked its length, which means a
    /// DevTools endpoint that is wedged, compromised, or simply broken could stream unbounded
    /// data into the daemon's memory before the check ever ran — the check was a report, not a
    /// limit.
    public func targets() async throws -> [Target] {
        guard (1...65_535).contains(port) else {
            throw SpaceOError.badRequest("DevTools port is invalid")
        }
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let data = try await boundedBody(from: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SpaceOError.badRequest("DevTools returned an unexpected target list")
        }
        return raw.compactMap { entry in
            guard entry["type"] as? String == "page",
                  let id = entry["id"] as? String,
                  let ws = entry["webSocketDebuggerUrl"] as? String,
                  let wsURL = Self.validatedWebSocketURL(ws, port: port) else { return nil }
            return Target(id: id,
                          title: entry["title"] as? String ?? "",
                          url: entry["url"] as? String ?? "",
                          webSocketURL: wsURL)
        }
    }

    /// Read an HTTP body, cancelling the transfer as soon as it exceeds the limit.
    func boundedBody(from url: URL) async throws -> Data {
        let (stream, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            stream.task.cancel()
            throw SpaceOError.badRequest("DevTools returned an invalid target-list response")
        }
        // A declared length over the limit is refused before a single byte of body is read.
        if http.expectedContentLength > Int64(Self.maximumTargetListBytes) {
            stream.task.cancel()
            throw SpaceOError.badRequest(
                "DevTools target list declares \(http.expectedContentLength) bytes, over the "
                + "\(Self.maximumTargetListBytes)-byte limit")
        }
        var data = Data()
        data.reserveCapacity(min(64 * 1024, Self.maximumTargetListBytes))
        for try await byte in stream {
            data.append(byte)
            if data.count > Self.maximumTargetListBytes {
                // Cancelling the task is what actually stops the transfer; leaving it running
                // and merely throwing would keep the socket draining in the background.
                stream.task.cancel()
                throw SpaceOError.badRequest(
                    "DevTools target list exceeded the \(Self.maximumTargetListBytes)-byte limit")
            }
        }
        return data
    }

    /// Wait for the browser to start serving DevTools. Chrome takes a moment after launch.
    public func waitUntilReady(timeout: TimeInterval = 15) async -> Bool {
        let safeTimeout = timeout.isFinite ? min(max(timeout, 0), 120) : 15
        let deadline = Date().addingTimeInterval(safeTimeout)
        while Date() < deadline {
            if let found = try? await targets(), !found.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    // MARK: - Connection

    private func connect(to target: Target) async throws {
        if socket != nil { return }
        guard Self.validatedWebSocketURL(target.webSocketURL.absoluteString, port: port) != nil else {
            throw SpaceOError.badRequest(
                "DevTools tried to redirect automation away from its private loopback port")
        }
        let task = session.webSocketTask(with: target.webSocketURL)
        task.maximumMessageSize = 32 * 1_048_576
        task.resume()
        socket = task
        attachedTargetID = target.id
    }

    /// Bind to the single page of a browser SpaceO just launched.
    ///
    /// A private-profile browser we started ourselves has exactly one page, so "exactly one" is a
    /// contract we can actually check — unlike the old `targets().first`, which took DevTools'
    /// list order as evidence of which page is in front. That order is not documented to mean
    /// anything, so when a second page existed the bridge could type into, click, and screenshot
    /// a page nobody asked about while reporting success.
    ///
    /// Ambiguity fails closed and names the candidates, so the caller can pick one with
    /// `attach(toTargetID:)`.
    @discardableResult
    public func attachToLaunchedTarget() async throws -> Target {
        let found = try await targets()
        guard !found.isEmpty else {
            throw SpaceOError.badRequest("browser has no page targets on port \(port)")
        }
        guard found.count == 1, let only = found.first else {
            let listed = found
                .prefix(8)
                .map { "\($0.id) — \($0.title.isEmpty ? $0.url : $0.title)" }
                .joined(separator: "\n    ")
            throw SpaceOError.badRequest(
                "browser on port \(port) has \(found.count) page targets, so SpaceO cannot tell "
                + "which one you mean. Attach to one explicitly:\n    \(listed)")
        }
        try await connect(to: only)
        return only
    }

    /// Bind to a caller-chosen page. The explicit form of `attachToLaunchedTarget`.
    @discardableResult
    public func attach(toTargetID id: String) async throws -> Target {
        guard !id.isEmpty, id.count <= 256, id.utf8.count <= 1_024 else {
            throw SpaceOError.badRequest("target id must be 1 through 256 characters")
        }
        let found = try await targets()
        guard let target = found.first(where: { $0.id == id }) else {
            throw SpaceOError.badRequest(
                "no page target '\(id)' on port \(port); it may have been closed")
        }
        try await connect(to: target)
        return target
    }

    /// Confirm the bound page is still the one we attached to.
    ///
    /// Navigation keeps a target id; closure and replacement do not. Checking before an action
    /// is what turns "the page went away" into an error instead of a command silently delivered
    /// nowhere — or, worse, a reconnect to a different page.
    public func verifyBoundTarget() async throws {
        guard let attachedTargetID, socket != nil else {
            throw SpaceOError.badRequest("not attached to a DevTools target")
        }
        let found = try await targets()
        guard found.contains(where: { $0.id == attachedTargetID }) else {
            detach()
            throw SpaceOError.badRequest(
                "the page SpaceO was driving (target \(attachedTargetID)) is gone; "
                + "attach again before sending more commands")
        }
    }

    public func detach() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        attachedTargetID = nil
    }

    @discardableResult
    private func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        await acquireCommandSlot()
        defer { releaseCommandSlot() }
        return try await performCommand(method, params)
    }

    private func acquireCommandSlot() async {
        guard commandInFlight else {
            commandInFlight = true
            return
        }
        await withCheckedContinuation { commandWaiters.append($0) }
    }

    private func releaseCommandSlot() {
        guard commandWaiters.isEmpty else {
            commandWaiters.removeFirst().resume()
            return
        }
        commandInFlight = false
    }

    private func performCommand(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        // Fail closed on both halves of the binding. A socket without a target id would mean
        // the bridge reconnected to something it never chose, which must never happen silently.
        guard let socket, attachedTargetID != nil else {
            throw SpaceOError.badRequest("not attached to a DevTools target")
        }
        nextID = nextID == Int.max ? 1 : nextID + 1
        let id = nextID
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= 1_048_576 else {
            throw SpaceOError.badRequest("DevTools command exceeds the 1 MiB limit")
        }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))

        // DevTools interleaves events with replies; read until our id comes back.
        let replyDeadline = Date().addingTimeInterval(10)
        for _ in 0..<64 {
            let remaining = replyDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                detach()
                throw SpaceOError.badRequest("DevTools \(method): reply timed out")
            }
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await Self.receive(from: socket, within: remaining)
            } catch {
                detach()
                throw error
            }
            guard case .string(let text) = message,
                  text.utf8.count <= 32 * 1_048_576,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }
            if let replyID = object["id"] as? Int, replyID == id {
                if let error = object["error"] as? [String: Any] {
                    throw SpaceOError.badRequest("DevTools \(method): \(error["message"] as? String ?? "failed")")
                }
                return object["result"] as? [String: Any] ?? [:]
            }
        }
        detach()
        throw SpaceOError.badRequest("DevTools \(method): no reply")
    }

    private static func receive(
        from socket: URLSessionWebSocketTask,
        within timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000))
                socket.cancel(with: .goingAway, reason: nil)
                throw SpaceOError.badRequest("DevTools reply timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SpaceOError.badRequest("DevTools connection ended without a reply")
            }
            return first
        }
    }

    // MARK: - Geometry

    /// Where the page viewport sits on screen, and how big it is.
    ///
    /// Needed to turn the window-relative coordinates an agent reads off a screenshot into the
    /// viewport coordinates the DevTools input domain expects.
    public func viewportOnScreen() async throws -> CGRect {
        let result = try await send("Runtime.evaluate", [
            "expression": """
                JSON.stringify({x: window.screenX, y: window.screenY,
                                w: window.innerWidth, h: window.innerHeight,
                                dpr: window.devicePixelRatio})
                """,
            "returnByValue": true,
        ])
        guard let wrapper = result["result"] as? [String: Any],
              let json = wrapper["value"] as? String,
              let box = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let x = box["x"] as? Double, let y = box["y"] as? Double,
              let w = box["w"] as? Double, let h = box["h"] as? Double,
              x.isFinite, y.isFinite, w.isFinite, h.isFinite,
              w > 0, h > 0
        else { throw SpaceOError.badRequest("could not read the page viewport") }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Input

    /// Click at a point in *viewport* coordinates.
    public func click(x: Double, y: Double, button: MouseButton = .left, clickCount: Int = 1) async throws {
        guard x.isFinite, y.isFinite else {
            throw SpaceOError.badRequest("click coordinates must be finite")
        }
        guard (1...3).contains(clickCount) else {
            throw SpaceOError.badRequest("click count must be from 1 through 3")
        }
        let name = button == .right ? "right" : "left"
        try await send("Input.dispatchMouseEvent",
                       ["type": "mouseMoved", "x": x, "y": y, "button": "none"])
        try await send("Input.dispatchMouseEvent",
                       ["type": "mousePressed", "x": x, "y": y,
                        "button": name, "buttons": button == .right ? 2 : 1,
                        "clickCount": clickCount])
        try await send("Input.dispatchMouseEvent",
                       ["type": "mouseReleased", "x": x, "y": y,
                        "button": name, "buttons": 0,
                        "clickCount": clickCount])
    }

    public func type(_ text: String) async throws {
        guard text.count <= 8_000, text.unicodeScalars.count <= 8_000,
              text.utf8.count <= 32_000 else {
            throw SpaceOError.badRequest(
                "text is too long (maximum 8000 characters/scalars "
                + "and 32000 UTF-8 bytes)")
        }
        try await send("Input.insertText", ["text": text])
    }

    public func key(_ text: String) async throws {
        try await key(KeyCombo.parse(text))
    }

    public func key(_ combo: KeyCombo) async throws {
        try await Self.deliverKey(combo, pasteboard: .general) { params in
            try await self.send("Input.dispatchKeyEvent", params)
        }
    }

    struct DevToolsKey {
        let windowsVirtualKeyCode: Int
        let key: String
        let code: String
        let modifiers: Int
    }

    /// Builds and dispatches both CDP key events. Clipboard-mutating shortcuts are refused
    /// before this helper constructs or sends either event.
    static func deliverKey(
        _ combo: KeyCombo,
        pasteboard: NSPasteboard,
        dispatch: ([String: Any]) async throws -> Void
    ) async throws {
        // CDP offers no isolated macOS pasteboard transaction either. Refuse before sending
        // rawKeyDown, including modified Command-C/X variants that an application may bind.
        _ = pasteboard
        try combo.requireClipboardSafeRoute()
        let key = try devToolsKey(for: combo)

        func sendEvents() async throws {
            let down: [String: Any] = [
                "type": "rawKeyDown",
                "windowsVirtualKeyCode": key.windowsVirtualKeyCode,
                "nativeVirtualKeyCode": Int(combo.keyCode),
                "key": key.key,
                "code": key.code,
                "modifiers": key.modifiers,
            ]
            try await dispatch(down)
            try await dispatch([
                "type": "keyUp",
                "windowsVirtualKeyCode": key.windowsVirtualKeyCode,
                "nativeVirtualKeyCode": Int(combo.keyCode),
                "key": key.key,
                "code": key.code,
                "modifiers": key.modifiers,
            ])
        }

        try await sendEvents()
    }

    static func devToolsKey(for combo: KeyCombo) throws -> DevToolsKey {
        let map: [CGKeyCode: (windows: Int, key: String, code: String)] = [
            8: (67, "c", "KeyC"),
            7: (88, "x", "KeyX"),
            36: (13, "Enter", "Enter"),
            48: (9, "Tab", "Tab"),
            51: (8, "Backspace", "Backspace"),
            53: (27, "Escape", "Escape"),
            123: (37, "ArrowLeft", "ArrowLeft"),
            124: (39, "ArrowRight", "ArrowRight"),
            125: (40, "ArrowDown", "ArrowDown"),
            126: (38, "ArrowUp", "ArrowUp"),
        ]
        guard let mapped = map[combo.keyCode] else {
            throw SpaceOError.badRequest(
                "that key is not one the browser bridge knows")
        }

        var modifiers = 0
        if combo.flags.contains(.maskAlternate) { modifiers |= 1 }
        if combo.flags.contains(.maskControl) { modifiers |= 2 }
        if combo.flags.contains(.maskCommand) { modifiers |= 4 }
        if combo.flags.contains(.maskShift) { modifiers |= 8 }
        let supported: CGEventFlags = [
            .maskAlternate, .maskControl, .maskCommand, .maskShift,
        ]
        guard combo.flags.subtracting(supported).isEmpty else {
            throw SpaceOError.badRequest(
                "that modifier is not supported by the browser bridge")
        }

        let renderedKey = combo.flags.contains(.maskShift)
            && mapped.key.count == 1
            ? mapped.key.uppercased() : mapped.key
        return DevToolsKey(
            windowsVirtualKeyCode: mapped.windows,
            key: renderedKey,
            code: mapped.code,
            modifiers: modifiers)
    }

    /// Evaluate JavaScript in the page and return the result as a string.
    /// The honest way for an agent to confirm that an action actually did something.
    public func evaluate(_ expression: String) async throws -> String {
        guard expression.count <= 262_144, expression.utf8.count <= 1_048_576 else {
            throw SpaceOError.badRequest("JavaScript expression exceeds the 1 MiB limit")
        }
        let result = try await send("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true])
        guard let wrapper = result["result"] as? [String: Any] else { return "" }
        if let value = wrapper["value"] as? String { return value }
        if let value = wrapper["value"] as? Int { return String(value) }
        if let value = wrapper["value"] as? Double { return String(value) }
        if let value = wrapper["value"] as? Bool { return String(value) }
        return wrapper["description"] as? String ?? ""
    }

    // MARK: - Reading

    /// PNG of the page viewport, in the same coordinate space as `click`.
    public func screenshot() async throws -> Data {
        let result = try await send("Page.captureScreenshot", ["format": "png"])
        guard let base64 = result["data"] as? String,
              base64.utf8.count <= 32 * 1_048_576,
              let data = Data(base64Encoded: base64),
              data.count <= 24 * 1_048_576 else {
            throw SpaceOError.captureFailed("DevTools returned no screenshot data")
        }
        return data
    }

    /// Interactive elements with their viewport rects — the web-content equivalent of an AX walk.
    public func interactiveElements(limit: Int = 200) async throws -> String {
        guard (1...1_000).contains(limit) else {
            throw SpaceOError.badRequest("page element limit must be from 1 through 1000")
        }
        let expression = """
        (() => {
          const sel = 'a,button,input,select,textarea,[role=button],[role=link],[role=tab],[onclick],[contenteditable=true]';
          const out = [];
          for (const el of document.querySelectorAll(sel)) {
            const r = el.getBoundingClientRect();
            if (r.width < 2 || r.height < 2) continue;
            const style = getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none') continue;
            const label = (el.getAttribute('aria-label') || el.innerText || el.value ||
                           el.getAttribute('placeholder') || el.getAttribute('title') || '')
                          .trim().replace(/\\s+/g, ' ').slice(0, 80);
            out.push({t: el.tagName.toLowerCase(), l: label,
                      x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2),
                      d: el.disabled === true});
            if (out.length >= \(limit)) break;
          }
          return JSON.stringify(out);
        })()
        """
        let result = try await send("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true])
        guard let wrapper = result["result"] as? [String: Any],
              let json = wrapper["value"] as? String,
              let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        else { return "(could not read the page)" }

        if items.isEmpty { return "(no interactive elements on this page)" }
        return items.enumerated().map { index, item in
            let tag = item["t"] as? String ?? "?"
            let label = item["l"] as? String ?? ""
            let x = item["x"] as? Int ?? 0
            let y = item["y"] as? Int ?? 0
            let disabled = (item["d"] as? Bool ?? false) ? "  (disabled)" : ""
            return "  [w\(index)] \(tag)\(label.isEmpty ? "" : " — \(label)")  at (\(x),\(y))\(disabled)"
        }.joined(separator: "\n")
    }

    /// Click the nth element from `interactiveElements`.
    public func clickElement(index: Int, button: MouseButton = .left, clickCount: Int = 1) async throws {
        guard (0..<1_000).contains(index) else {
            throw SpaceOError.badRequest("web element index must be from 0 through 999")
        }
        let expression = """
        (() => {
          const sel = 'a,button,input,select,textarea,[role=button],[role=link],[role=tab],[onclick],[contenteditable=true]';
          const out = [];
          for (const el of document.querySelectorAll(sel)) {
            const r = el.getBoundingClientRect();
            if (r.width < 2 || r.height < 2) continue;
            const style = getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none') continue;
            out.push(el);
          }
          const el = out[\(index)];
          if (!el) return 'missing';
          const r = el.getBoundingClientRect();
          return JSON.stringify({x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)});
        })()
        """
        let result = try await send("Runtime.evaluate",
                                    ["expression": expression, "returnByValue": true])
        guard let wrapper = result["result"] as? [String: Any],
              let json = wrapper["value"] as? String, json != "missing",
              let point = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let x = point["x"] as? Double ?? (point["x"] as? Int).map(Double.init),
              let y = point["y"] as? Double ?? (point["y"] as? Int).map(Double.init)
        else { throw SpaceOError.badRequest("no web element [w\(index)] on this page") }
        try await click(x: x, y: y, button: button, clickCount: clickCount)
    }

    // MARK: - Endpoint validation

    static func validatedWebSocketURL(_ raw: String, port: Int) -> URL? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "ws",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              components.port == port,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }
}
