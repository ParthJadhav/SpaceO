import Foundation
import CoreGraphics

/// Wire format between the `spaceo` CLI and the daemon.
///
/// Deliberately one flat struct rather than a per-command type: it keeps the socket protocol
/// trivially inspectable with `nc`, which matters a lot when debugging something that talks to
/// the WindowServer.
public struct Request: Codable, Sendable {
    public var cmd: String
    public var session: String?
    public var width: Int?
    public var height: Int?
    public var app: String?
    public var files: [String]?
    public var pid: Int32?
    public var window: UInt32?
    public var text: String?
    public var key: String?
    /// Either an AX index ("7") or a web-content index ("w7").
    public var element: String?
    /// Target the page rather than the app chrome.
    public var web: Bool?
    public var x: Double?
    public var y: Double?
    public var button: String?
    public var count: Int?
    public var output: String?
    public var quitApps: Bool?
    public var full: Bool?

    public init(cmd: String) { self.cmd = cmd }
}

public struct WindowInfo: Codable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var title: String
    public var x: Double, y: Double, width: Double, height: Double
    public var onStage: Bool
    public var spaces: [UInt64]

    public init(_ window: WindowRef, session: AgentSession) {
        self.windowID = window.windowID
        self.pid = window.pid
        self.title = window.title
        self.x = window.frame.origin.x
        self.y = window.frame.origin.y
        self.width = window.frame.width
        self.height = window.frame.height
        self.onStage = WindowPlacement.isInRegion(window, session.frame)
        self.spaces = WindowPlacement.spaces(of: window)
    }
}

public struct AppInfo: Codable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var startedByUs: Bool

    public init(_ app: LaunchedApp) {
        self.pid = app.pid
        self.name = app.name
        self.bundleID = app.bundleIdentifier
        self.startedByUs = app.startedByUs
    }
}

public struct SessionInfo: Codable, Sendable {
    public var id: String
    public var displayID: UInt32
    /// The session's tile, not the whole display.
    public var x: Double, y: Double, width: Double, height: Double
    public var tileIndex: Int
    public var tileCapacity: Int
    public var exclusiveDisplay: Bool
    public var spaces: [UInt64]
    public var hasOwnSpace: Bool
    public var apps: [AppInfo]
    public var windows: [WindowInfo]
    public var createdAt: Date

    public init(_ session: AgentSession) {
        let bounds = session.frame
        self.id = session.id
        self.displayID = session.stage.displayID
        self.x = bounds.origin.x
        self.y = bounds.origin.y
        self.width = bounds.width
        self.height = bounds.height
        self.tileIndex = session.slot.index
        self.tileCapacity = session.slot.capacity
        self.exclusiveDisplay = session.hasExclusiveDisplay
        self.spaces = session.stage.spaces
        self.hasOwnSpace = session.stage.hasOwnSpace
        self.apps = session.apps.map(AppInfo.init)
        self.windows = session.windows.map { WindowInfo($0, session: session) }
        self.createdAt = session.createdAt
    }
}

/// The active resource budget, flattened for the wire.
public struct ResourceLimitsReport: Codable, Sendable, Equatable {
    public var maximumSessions: Int
    public var maximumDisplays: Int
    public var maximumTotalPixels: Int
    public var maximumTotalBytes: Int
    public var maximumCreationsPerMinute: Int
    public var minimumTileWidth: Int
    public var minimumTileHeight: Int
    public var maximumDisplayEdge: Int
    /// True when the operator started the daemon with the unsafe budget, so a reader is never
    /// left guessing why the numbers look generous.
    public var unsafeOperatorMode: Bool

    public init(_ budget: ResourceBudget) {
        maximumSessions = budget.maximumSessions
        maximumDisplays = budget.maximumDisplays
        maximumTotalPixels = budget.maximumTotalPixels
        maximumTotalBytes = budget.maximumTotalBytes
        maximumCreationsPerMinute = budget.maximumCreationsPerMinute
        minimumTileWidth = Int(budget.minimumTileSize.width)
        minimumTileHeight = Int(budget.minimumTileSize.height)
        maximumDisplayEdge = budget.maximumDisplayEdge
        unsafeOperatorMode = budget.isUnsafe
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var message: String?
    public var session: SessionInfo?
    public var sessions: [SessionInfo]?
    public var windows: [WindowInfo]?
    public var outline: String?
    public var path: String?
    /// Structured isolation coverage and verdict.
    public var isolation: IsolationReport?
    /// Legacy isolation failures. Omitted for a partial report so `[]` cannot be read as clean.
    public var drift: [String]?
    public var ambient: [String]?
    public var findings: [String]?
    public var displays: [DisplayPool.DisplayReport]?
    /// What the pool is holding right now, against the limits it will refuse at. Reported by
    /// `pool` so an operator can see how close they are before an allocation is denied.
    public var usage: ResourceBudget.Usage?
    public var limits: ResourceLimitsReport?
    public var value: String?

    public init(ok: Bool) { self.ok = ok }

    public static func failure(_ error: Error) -> Response {
        var response = Response(ok: false)
        // The package's own error types conform to LocalizedError (their errorDescription is
        // their description), so this single call renders deliberate messages for them and
        // still gives Cocoa errors their proper localized text. No per-type casts needed here.
        response.error = error.localizedDescription
        return response
    }

    public static func success(_ message: String? = nil) -> Response {
        var response = Response(ok: true)
        response.message = message
        return response
    }
}

public enum Wire {
    /// Where the daemon listens. Overridable for tests so a test run never collides with a
    /// daemon the user is actually using.
    public static func socketPath(_ override: String? = nil) -> String {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment["SPACEO_SOCKET"] { return env }
        return NSTemporaryDirectory() + "spaceo-\(getuid()).sock"
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
