import Foundation
import CoreGraphics

/// What SpaceO is willing to ask of the WindowServer.
///
/// A virtual display is not a cheap object. It is a framebuffer the WindowServer composites every
/// frame, backed by GPU and wired memory, in the *user's own graphical login session*. Nothing
/// downstream of `session.create` used to bound how many of those a caller could ask for: an
/// agent in a retry loop, a prompt-injected tool call, or a typo in `SPACEO_DISPLAY_SIZE` could
/// walk the machine into a WindowServer the user has to reboot out of.
///
/// So admission happens here, before a `Stage` exists — a refusal costs a caller one error, while
/// an unbounded allocation costs the user their session. Every limit reports the requested value,
/// the limit, current usage, and what to do about it, because "denied" without a number is a
/// support ticket.
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

    public static let `default` = ResourceBudget(
        maximumSessions: 16,
        maximumDisplays: 8,
        maximumTotalPixels: 64_000_000,
        maximumTotalBytes: 64_000_000 * bytesPerPixel,
        maximumCreationsPerMinute: 12,
        minimumTileSize: CGSize(width: 320, height: 240),
        maximumDisplayEdge: 16_384)

    /// The operator escape hatch. Still bounded — by what the platform can represent and what a
    /// tile needs to be usable — because "unlimited" here would just move the crash.
    ///
    /// Reached only through an explicit unsafe mode, never by a request over the wire.
    public static let unsafeOperator = ResourceBudget(
        maximumSessions: 256,
        maximumDisplays: 64,
        maximumTotalPixels: 4_000_000_000,
        maximumTotalBytes: Int.max,
        maximumCreationsPerMinute: 240,
        minimumTileSize: CGSize(width: 64, height: 64),
        maximumDisplayEdge: 65_536)

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

    /// Whether the unsafe operator budget was requested for this process.
    ///
    /// An environment variable rather than a request field on purpose: this must be a decision by
    /// whoever starts the daemon, not something an agent can ask for mid-conversation.
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
                + "limit. Ask for a smaller display, or start the daemon with "
                + "SPACEO_UNSAFE_RESOURCE_LIMITS=1 if you accept the risk to your login session")
        }
        let pixels = Int(width) * Int(height)
        guard pixels <= maximumTotalPixels else {
            throw SpaceOError.badRequest(
                "a single \(width)x\(height) display is \(pixels) pixels, over the "
                + "\(maximumTotalPixels)-pixel budget for all SpaceO displays combined")
        }
        // A "successful" allocation that hands an agent a 40x30 tile is a bug that reports
        // success, which is worse than a refusal.
        guard let tile = TileLayout.rect(in: CGRect(origin: .zero, size: size),
                                         capacity: capacity, index: 0),
              tile.width >= minimumTileSize.width, tile.height >= minimumTileSize.height else {
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

    /// Admit one more session on an existing display — no new framebuffer, so only the session
    /// count is at stake.
    public func admitSession(usage: Usage) throws {
        guard usage.sessions < maximumSessions else {
            throw SpaceOError.badRequest(
                refusal("live sessions", requested: usage.sessions + 1,
                        limit: maximumSessions, current: usage.sessions,
                        remedy: "destroy a session first"))
        }
    }

    /// Admit a new display of `size`. Checks every standing limit *and* the rate limit, so a
    /// caller cannot stay under the totals by churning create/destroy.
    public func admitDisplay(size: CGSize, capacity: Int, usage: Usage) throws {
        try admitSession(usage: usage)
        _ = try validateDisplaySize(size, capacity: capacity)

        guard usage.displays < maximumDisplays else {
            throw SpaceOError.badRequest(
                refusal("virtual displays", requested: usage.displays + 1,
                        limit: maximumDisplays, current: usage.displays,
                        remedy: "destroy a session so an empty display can retire, or raise "
                              + "sessions-per-display so agents share one"))
        }
        let addedPixels = Int(size.width) * Int(size.height)
        let totalPixels = usage.pixels + addedPixels
        guard totalPixels <= maximumTotalPixels else {
            throw SpaceOError.badRequest(
                refusal("framebuffer pixels", requested: totalPixels,
                        limit: maximumTotalPixels, current: usage.pixels,
                        remedy: "use a smaller --display-size, or destroy a session"))
        }
        let totalBytes = totalPixels.multipliedReportingOverflow(by: Self.bytesPerPixel)
        guard !totalBytes.overflow, totalBytes.partialValue <= maximumTotalBytes else {
            throw SpaceOError.badRequest(
                refusal("framebuffer bytes", requested: totalBytes.overflow ? Int.max : totalBytes.partialValue,
                        limit: maximumTotalBytes, current: usage.bytes,
                        remedy: "use a smaller --display-size, or destroy a session"))
        }
        guard usage.creationsInLastMinute < maximumCreationsPerMinute else {
            throw SpaceOError.badRequest(
                refusal("display creations per minute", requested: usage.creationsInLastMinute + 1,
                        limit: maximumCreationsPerMinute, current: usage.creationsInLastMinute,
                        remedy: "something is creating displays in a loop — wait a minute, and "
                              + "check for a retrying agent"))
        }
    }

    private func refusal(_ what: String, requested: Int, limit: Int,
                         current: Int, remedy: String) -> String {
        "\(what) budget exceeded: requested \(requested), limit \(limit), currently \(current). "
        + "\(remedy). "
        + (isUnsafe
           ? "This is already the unsafe operator budget."
           : "Set SPACEO_UNSAFE_RESOURCE_LIMITS=1 to raise the limits if you accept the risk "
             + "of destabilising your graphical login session.")
    }
}
