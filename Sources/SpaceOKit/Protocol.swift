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
    /// Optional controller metadata for `session.create`.
    public var controllerOwner: DurableSessionOwner?
    /// Current lease credential for `session.heartbeat` and owner-scoped mutations.
    public var controllerLeaseID: UUID?
    /// Requested create-time lease duration. The daemon bounds client values.
    public var controllerTTLSeconds: Double?

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

    public init(_ app: DurableSessionApp) {
        self.pid = app.identity.pid
        self.name = app.name
        self.bundleID = app.bundleIdentifier
        self.startedByUs = app.provenance == .launched
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
    public var teardownPending: Bool
    /// `false` for diagnostic records recovered from a prior daemon. Their persisted display
    /// and tile coordinates are never authority to target a current WindowServer object.
    ///
    /// Optional for wire compatibility with older daemons, whose session lists contained only
    /// attached runtime sessions.
    public var runtimeAttached: Bool?
    public var controllerOwner: DurableSessionOwner?
    public var ageSeconds: Double?
    public var lastActivityAt: Date?
    public var leaseExpiresAt: Date?
    public var abandoned: Bool?
    public var reclaimable: Bool?
    public var recoveryBlockers: [DurableRecoveryBlocker]?

    public init(_ session: AgentSession) {
        let bounds = session.frame
        let controller = session.controllerSnapshot()
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
        self.teardownPending = session.teardownPending
        self.runtimeAttached = true
        self.controllerOwner = controller?.owner
        self.ageSeconds = controller?.ageSeconds
        self.lastActivityAt = controller?.lastActivityAt
        self.leaseExpiresAt = controller?.lease.expiresAt
        self.abandoned = controller?.abandoned
        self.reclaimable = controller?.reclaimable
        self.recoveryBlockers = nil
    }

    /// Observer-only representation of a session recovered from a prior daemon.
    ///
    /// Placement is included so operators can diagnose what the old daemon owned, but
    /// `runtimeAttached == false` is the load-bearing instruction that no current display,
    /// window, Space, or input route may be inferred from those numbers.
    public init(_ record: DurableSessionRecord, now: Date = Date()) {
        let placement = record.lastKnownPlacement
        self.id = record.id
        self.displayID = placement?.displayID ?? 0
        self.x = placement?.x ?? 0
        self.y = placement?.y ?? 0
        self.width = placement?.width ?? 0
        self.height = placement?.height ?? 0
        self.tileIndex = placement?.tileIndex ?? 0
        self.tileCapacity = placement?.tileCapacity ?? 0
        self.exclusiveDisplay = placement?.exclusiveDisplay ?? false
        self.spaces = []
        self.hasOwnSpace = false
        self.apps = record.apps.map(AppInfo.init)
        self.windows = []
        self.createdAt = record.createdAt
        self.teardownPending = record.operationState != .ready
        self.runtimeAttached = false
        self.controllerOwner = record.owner
        self.ageSeconds = max(0, now.timeIntervalSince(record.createdAt))
        self.lastActivityAt = record.lastActivityAt
        self.leaseExpiresAt = nil
        self.abandoned = record.ownershipState == .abandoned
        self.reclaimable = record.recoveryState == .reclaimable
        self.recoveryBlockers =
            record.recoveryBlockers.isEmpty ? nil : record.recoveryBlockers
    }
}

/// Runtime representation bounds, flattened for wire compatibility.
public struct ResourceLimitsReport: Codable, Sendable, Equatable {
    public var maximumSessions: Int
    public var maximumDisplays: Int
    public var maximumTotalPixels: Int
    public var maximumTotalBytes: Int
    public var maximumCreationsPerMinute: Int
    public var minimumTileWidth: Int
    public var minimumTileHeight: Int
    public var maximumDisplayEdge: Int
    /// Whether the higher, still-bounded process-start operator budget is active.
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

/// A process that was still alive after every requested graceful and forced quit attempt.
public struct SurvivingProcessInfo: Codable, Sendable, Equatable {
    public var identity: ProcessIdentity
    public var pid: Int32
    public var name: String

    public init(_ app: LaunchedApp) {
        identity = app.identity
        pid = app.pid
        name = app.name
    }
}

/// Structured outcome of a session or daemon teardown.
///
/// An incomplete report is deliberately retryable. Pending sessions and displays remain owned
/// by the daemon until a later cleanup attempt proves their resources are gone.
public struct TeardownReport: Codable, Sendable, Equatable {
    public var survivingProcesses: [SurvivingProcessInfo]
    public var stillAttachedDisplayIDs: [UInt32]
    public var pendingSessionIDs: [String]

    public init(
        survivingProcesses: [SurvivingProcessInfo] = [],
        stillAttachedDisplayIDs: [UInt32] = [],
        pendingSessionIDs: [String] = []
    ) {
        self.survivingProcesses = survivingProcesses
        self.stillAttachedDisplayIDs = Array(Set(stillAttachedDisplayIDs)).sorted()
        self.pendingSessionIDs = Array(Set(pendingSessionIDs)).sorted()
    }

    public var isComplete: Bool {
        survivingProcesses.isEmpty
            && stillAttachedDisplayIDs.isEmpty
            && pendingSessionIDs.isEmpty
    }

    public mutating func merge(_ other: TeardownReport) {
        let processes = Dictionary(
            (survivingProcesses + other.survivingProcesses).map {
                ($0.identity, $0)
            },
            uniquingKeysWith: { current, _ in current })
        survivingProcesses = processes.values.sorted {
            ($0.pid, $0.identity.startedAtMicroseconds)
                < ($1.pid, $1.identity.startedAtMicroseconds)
        }
        stillAttachedDisplayIDs = Array(
            Set(stillAttachedDisplayIDs).union(other.stillAttachedDisplayIDs)
        ).sorted()
        pendingSessionIDs = Array(
            Set(pendingSessionIDs).union(other.pendingSessionIDs)
        ).sorted()
    }

    public var recoveryDescription: String {
        var lines = ["teardown incomplete; SpaceO kept ownership so cleanup can be retried."]
        if !survivingProcesses.isEmpty {
            let listed = survivingProcesses.map {
                "\($0.name) pid \($0.pid) "
                    + "(started \($0.identity.startedAtMicroseconds))"
            }.joined(separator: ", ")
            lines.append("  Processes still alive: \(listed).")
            lines.append(
                "  Close any save dialogs or quit those exact processes, then retry cleanup.")
        }
        if !stillAttachedDisplayIDs.isEmpty {
            lines.append(
                "  Virtual displays still attached: "
                    + stillAttachedDisplayIDs.map(String.init).joined(separator: ", ")
                    + ".")
        }
        if pendingSessionIDs.isEmpty {
            lines.append("  Retry with `spaceo session destroy --all` or `spaceo daemon stop`.")
        } else {
            lines.append(
                "  Pending sessions: \(pendingSessionIDs.joined(separator: ", ")). "
                    + "Retry their destroy command, `spaceo session destroy --all`, "
                    + "or `spaceo daemon stop`.")
        }
        lines.append(
            "  If a display remains after its processes exit, retry once more; "
                + "run `spaceo doctor` before restarting the login session.")
        return lines.joined(separator: "\n")
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
    /// Returned only to the controller by create/heartbeat; never included in SessionInfo lists.
    public var controllerLeaseID: UUID?
    /// Present on every incomplete teardown failure, including daemon stop.
    public var teardown: TeardownReport?

    public init(ok: Bool) { self.ok = ok }

    public static func failure(_ error: Error) -> Response {
        var response = Response(ok: false)
        // The package's own error types conform to LocalizedError (their errorDescription is
        // their description), so this single call renders deliberate messages for them and
        // still gives Cocoa errors their proper localized text. No per-type casts needed here.
        response.error = error.localizedDescription
        if case .teardownIncomplete(let report) = error as? SpaceOError {
            response.teardown = report
        }
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
