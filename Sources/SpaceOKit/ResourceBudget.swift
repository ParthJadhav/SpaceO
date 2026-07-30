import Foundation
import CoreGraphics

/// What SpaceO is willing to ask of the WindowServer.
///
/// A virtual display is a framebuffer composited in the user's graphical login session. Admission
/// therefore happens before a `Stage` exists: callers receive a bounded, actionable refusal
/// instead of discovering the limit by destabilising WindowServer.
public struct ResourceBudget: Sendable, Equatable {

    /// Live sessions across the whole daemon.
    public var maximumSessions: Int
    /// Virtual displays attached at once.
    public var maximumDisplays: Int
    /// Total framebuffer area across every SpaceO display, in pixels.
    ///
    /// The standing aggregate limit is separate from the per-display edge limit.
    public var maximumTotalPixels: Int
    /// Total framebuffer memory across every SpaceO display, in bytes, at 4 bytes per pixel.
    public var maximumTotalBytes: Int
    /// Displays that may be created in one rolling minute, so a crash-loop cannot churn the
    /// WindowServer even while staying under the standing limits.
    public var maximumCreationsPerMinute: Int
    /// The smallest tile a session can be given and still be usable. A tile below this is not a
    /// small workspace, it is a successful-looking allocation an agent can do nothing with.
    public var minimumTileSize: CGSize
    /// Largest single display edge, in pixels. Well under `UInt32.max`, which is the only bound
    /// the previous code had and is not a bound in any meaningful sense.
    public var maximumDisplayEdge: Int

    public static let bytesPerPixel = 4

    /// Conservative defaults for an interactive login session. Four 4K framebuffers fit under
    /// the aggregate pixel limit, but retry loops hit the creation-rate gate after four attaches.
    public static let `default` = ResourceBudget(
        maximumSessions: 16,
        maximumDisplays: 4,
        maximumTotalPixels: 33_554_432,
        maximumTotalBytes: 33_554_432 * bytesPerPixel,
        maximumCreationsPerMinute: 4,
        minimumTileSize: CGSize(width: 640, height: 480),
        maximumDisplayEdge: 8_192)

    /// Explicit operator override for unusually dense, controlled workloads.
    ///
    /// This remains finite and only raises resource ceilings. It never bypasses display-graph
    /// safety checks, because mirroring, inactive user displays, overlap, and phantom SpaceO
    /// displays are evidence that another attachment could lock the user out.
    public static let unsafeOperator = ResourceBudget(
        maximumSessions: 32,
        maximumDisplays: 8,
        maximumTotalPixels: 67_108_864,
        maximumTotalBytes: 67_108_864 * bytesPerPixel,
        maximumCreationsPerMinute: 8,
        minimumTileSize: CGSize(width: 320, height: 240),
        maximumDisplayEdge: 16_384)

    public init(maximumSessions: Int,
                maximumDisplays: Int,
                maximumTotalPixels: Int,
                maximumTotalBytes: Int,
                maximumCreationsPerMinute: Int,
                minimumTileSize: CGSize,
                maximumDisplayEdge: Int) {
        self.maximumSessions = maximumSessions
        self.maximumDisplays = maximumDisplays
        self.maximumTotalPixels = maximumTotalPixels
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumCreationsPerMinute = maximumCreationsPerMinute
        self.minimumTileSize = minimumTileSize
        self.maximumDisplayEdge = maximumDisplayEdge
    }

    /// The override is process-start configuration, not a request field an agent can set.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResourceBudget {
        let raw = environment["SPACEO_UNSAFE_RESOURCE_LIMITS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (raw == "1" || raw == "true" || raw == "yes") ? .unsafeOperator : .default
    }

    public var isUnsafe: Bool { self == .unsafeOperator }

    // MARK: - Geometry admission

    /// Check a display size before anything is created from it.
    ///
    /// Called by the daemon at startup on CLI/environment geometry, so a typo fails at the
    /// command line with a readable message instead of at the first `session.create`.
    public func validateDisplaySize(_ size: CGSize, capacity: Int) throws -> (width: UInt32, height: UInt32) {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width == size.width.rounded(), size.height == size.height.rounded(),
              let width = UInt32(exactly: size.width),
              let height = UInt32(exactly: size.height) else {
            throw SpaceOError.badRequest(
                "display size must use positive whole pixels representable by UInt32 "
                + "(got \(size.width)x\(size.height))")
        }
        guard Int(width) <= maximumDisplayEdge, Int(height) <= maximumDisplayEdge else {
            throw SpaceOError.badRequest(
                "display size \(width)x\(height) exceeds the \(maximumDisplayEdge)px per-edge "
                + "limit. Use a smaller display"
                + (isUnsafe
                   ? "; the bounded operator override is already active"
                   : ", or set SPACEO_UNSAFE_RESOURCE_LIMITS=1 when starting the daemon "
                     + "if you accept the additional resource risk"))
        }
        let pixels = Int(width).multipliedReportingOverflow(by: Int(height))
        guard !pixels.overflow, pixels.partialValue <= maximumTotalPixels else {
            throw SpaceOError.badRequest(
                "a single \(width)x\(height) display is "
                + "\(pixels.overflow ? Int.max : pixels.partialValue) pixels, over the "
                + "\(maximumTotalPixels)-pixel aggregate framebuffer budget")
        }
        guard let tile = TileLayout.rect(in: CGRect(origin: .zero, size: size),
                                         capacity: capacity, index: 0),
              tile.width >= minimumTileSize.width,
              tile.height >= minimumTileSize.height else {
            let (columns, rows) = TileLayout.grid(for: capacity)
            let needed = CGSize(width: minimumTileSize.width * CGFloat(columns),
                                height: minimumTileSize.height * CGFloat(rows))
            throw SpaceOError.badRequest(
                "\(capacity) session(s) on a \(Int(size.width))x\(Int(size.height)) display "
                + "gives each one a tile smaller than the "
                + "\(Int(minimumTileSize.width))x\(Int(minimumTileSize.height)) minimum. "
                + "Use at least \(Int(needed.width))x\(Int(needed.height)), or fewer sessions "
                + "per display")
        }
        return (width, height)
    }

    // MARK: - Usage admission

    /// Everything the pool currently holds, for admission and for reporting.
    public struct Usage: Codable, Sendable, Equatable {
        public var sessions: Int
        public var displays: Int
        public var pixels: Int
        public var bytes: Int
        public var creationsInLastMinute: Int

        public init(sessions: Int = 0, displays: Int = 0, pixels: Int = 0,
                    bytes: Int = 0, creationsInLastMinute: Int = 0) {
            self.sessions = sessions
            self.displays = displays
            self.pixels = pixels
            self.bytes = bytes
            self.creationsInLastMinute = creationsInLastMinute
        }
    }

    /// Admit one more session on an existing display.
    public func admitSession(usage: Usage) throws {
        guard usage.sessions < maximumSessions else {
            throw SpaceOError.badRequest(
                refusal("live sessions", requested: addingOne(to: usage.sessions),
                        limit: maximumSessions, current: usage.sessions,
                        remedy: "destroy a session first"))
        }
    }

    /// Admit one new session and its display, checking standing and rolling limits.
    public func admitDisplay(size: CGSize, capacity: Int, usage: Usage) throws {
        try admitSession(usage: usage)
        let dimensions = try validateDisplaySize(size, capacity: capacity)

        guard usage.displays < maximumDisplays else {
            throw SpaceOError.badRequest(
                refusal("virtual displays", requested: addingOne(to: usage.displays),
                        limit: maximumDisplays, current: usage.displays,
                        remedy: "destroy a session so an empty display can retire, or raise "
                              + "sessions-per-display so agents share one"))
        }

        let addedPixels = Int(dimensions.width).multipliedReportingOverflow(
            by: Int(dimensions.height))
        let totalPixels = usage.pixels.addingReportingOverflow(addedPixels.partialValue)
        guard !addedPixels.overflow, !totalPixels.overflow,
              totalPixels.partialValue <= maximumTotalPixels else {
            throw SpaceOError.badRequest(
                refusal("framebuffer pixels",
                        requested: addedPixels.overflow || totalPixels.overflow
                            ? Int.max : totalPixels.partialValue,
                        limit: maximumTotalPixels, current: usage.pixels,
                        remedy: "use a smaller --display-size, or destroy a session"))
        }

        let addedBytes = addedPixels.partialValue.multipliedReportingOverflow(
            by: Self.bytesPerPixel)
        let totalBytes = usage.bytes.addingReportingOverflow(addedBytes.partialValue)
        guard !addedBytes.overflow, !totalBytes.overflow,
              totalBytes.partialValue <= maximumTotalBytes else {
            throw SpaceOError.badRequest(
                refusal("framebuffer bytes",
                        requested: addedBytes.overflow || totalBytes.overflow
                            ? Int.max : totalBytes.partialValue,
                        limit: maximumTotalBytes, current: usage.bytes,
                        remedy: "use a smaller --display-size, or destroy a session"))
        }

        guard usage.creationsInLastMinute < maximumCreationsPerMinute else {
            throw SpaceOError.badRequest(
                refusal("display creations per minute",
                        requested: addingOne(to: usage.creationsInLastMinute),
                        limit: maximumCreationsPerMinute,
                        current: usage.creationsInLastMinute,
                        remedy: "a caller may be creating displays in a loop — wait one minute "
                              + "and inspect the retrying agent"))
        }
    }

    private func addingOne(to value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    private func refusal(_ resource: String, requested: Int, limit: Int,
                         current: Int, remedy: String) -> String {
        "\(resource) budget exceeded: requested \(requested), limit \(limit), "
        + "currently \(current). \(remedy). "
        + (isUnsafe
           ? "The bounded operator override is already active."
           : "Set SPACEO_UNSAFE_RESOURCE_LIMITS=1 when starting the daemon to select the "
             + "higher bounded budget; display-graph safety checks cannot be overridden.")
    }
}
