import Foundation
import CoreGraphics

/// Runtime usage accounting and technical geometry validation.
///
/// SpaceO does not impose product-policy ceilings on sessions, displays, framebuffer totals, or
/// creation rate. The remaining bounds express Swift/CoreGraphics representation limits and keep
/// layout materialization finite.
public struct ResourceBudget: Sendable, Equatable {

    /// Live sessions across the whole daemon.
    public var maximumSessions: Int
    /// Virtual displays attached at once.
    public var maximumDisplays: Int
    /// Total framebuffer area across every SpaceO display, in pixels.
    ///
    /// 64 megapixels is roughly eight 1080p displays or two 8K ones — generous for real agent
    /// work, and far below where compositing starts to hurt.
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

    private static let representablePixels = Int.max / bytesPerPixel
    private static let representableEdge = Int(Double(representablePixels).squareRoot())

    public static let `default` = ResourceBudget(
        maximumSessions: Int.max,
        maximumDisplays: Int.max,
        maximumTotalPixels: representablePixels,
        maximumTotalBytes: Int.max,
        maximumCreationsPerMinute: Int.max,
        minimumTileSize: CGSize(width: 1, height: 1),
        maximumDisplayEdge: representableEdge)

    /// Retained as source/API compatibility with earlier callers; there is no privileged mode.
    public static let unsafeOperator = ResourceBudget.default

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

    /// Environment-independent: normal use receives the same runtime limits in every process.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResourceBudget {
        _ = environment
        return .default
    }

    public var isUnsafe: Bool { false }

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
        let pixels = Int(width).multipliedReportingOverflow(by: Int(height))
        guard !pixels.overflow, pixels.partialValue <= maximumTotalPixels else {
            throw SpaceOError.badRequest(
                "display size \(width)x\(height) cannot be represented safely by this process")
        }
        guard let tile = TileLayout.rect(in: CGRect(origin: .zero, size: size),
                                         capacity: capacity, index: 0),
              tile.width >= 1, tile.height >= 1 else {
            throw SpaceOError.badRequest(
                "sessions per display must be between 1 and \(TileLayout.maximumCapacity), "
                + "with at least one pixel per tile")
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

    /// Compatibility hook. SpaceO does not impose a session-count policy.
    public func admitSession(usage: Usage) throws {
        _ = usage
    }

    /// Validate only the new display's technical geometry.
    public func admitDisplay(size: CGSize, capacity: Int, usage: Usage) throws {
        _ = usage
        _ = try validateDisplaySize(size, capacity: capacity)
    }
}
