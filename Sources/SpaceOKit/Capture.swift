import Foundation
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Screenshots of the agent's screen.
///
/// The stage's Space is always the current Space *of that display*, so its windows are genuinely
/// composited and capture returns real pixels — no occlusion workarounds needed. Per-window
/// capture uses `desktopIndependentWindow`, which is documented display- and Space-independent.
public enum Capture {

    /// Everything on the agent's screen.
    public static func display(_ stage: Stage) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw SpaceOError.screenRecordingDenied }
        let content = try await shareableContent()
        guard let target = content.displays.first(where: { $0.displayID == stage.displayID }) else {
            throw SpaceOError.captureFailed("display \(stage.displayID) is not shareable")
        }
        let filter = SCContentFilter(display: target, excludingWindows: [])
        let config = SCStreamConfiguration()
        let dimensions = try validatedDimensions(
            width: Double(target.width), height: Double(target.height))
        config.width = dimensions.width
        config.height = dimensions.height
        config.showsCursor = false
        config.captureResolution = .best
        return try await capture(filter: filter, config: config,
                                 what: "display \(stage.displayID)")
    }

    /// The scale every agent-facing capture uses unless the caller asks for more detail.
    ///
    /// 1 makes an image pixel and a click coordinate the same number. The previous asymmetry —
    /// window captures hard-coded to 2× while tile captures stayed at 1× — meant an agent reading
    /// a coordinate off the default screenshot clicked at half the intended position, with no
    /// field in the response it could have used to tell the difference.
    public static let defaultScale: Double = 1

    /// Validate an agent-requested capture scale.
    public static func validatedScale(_ requested: Int?) throws -> Double {
        guard let requested else { return defaultScale }
        guard (1...4).contains(requested) else {
            throw SpaceOError.badRequest("capture scale must be from 1 through 4")
        }
        return Double(requested)
    }

    /// A region of one session's tile of a shared agent display.
    ///
    /// Sessions share a display, so "screenshot the screen" has to mean *this session's* screen.
    /// Capturing the whole display and cropping would leak a neighbouring agent's work into
    /// this agent's context, so the crop happens in the capture itself via `sourceRect`.
    ///
    /// `subRect` is tile-local and clamped to the tile, so a caller asking to zoom into a
    /// sub-region can never widen its view past its own tile by passing a larger rect.
    public static func region(
        _ stage: Stage,
        _ rect: CGRect,
        subRect: CGRect? = nil,
        scale: Double = defaultScale
    ) async throws -> (image: CGImage, geometry: ImageGeometry) {
        guard CGPreflightScreenCaptureAccess() else { throw SpaceOError.screenRecordingDenied }
        let content = try await shareableContent()
        guard let target = content.displays.first(where: { $0.displayID == stage.displayID }) else {
            throw SpaceOError.captureFailed("display \(stage.displayID) is not shareable")
        }

        var captured = rect
        if let subRect {
            guard subRect.width >= 1, subRect.height >= 1,
                  subRect.origin.x.isFinite, subRect.origin.y.isFinite,
                  subRect.width.isFinite, subRect.height.isFinite else {
                throw SpaceOError.badRequest("capture region must be finite and at least 1x1")
            }
            captured = CGRect(x: rect.minX + subRect.minX, y: rect.minY + subRect.minY,
                              width: subRect.width, height: subRect.height)
                .intersection(rect)
            guard !captured.isNull, captured.width >= 1, captured.height >= 1 else {
                throw SpaceOError.badRequest(
                    "capture region \(subRect) lies outside this session's tile")
            }
        }

        // sourceRect is display-local; our rects are in global coordinates.
        let bounds = stage.bounds
        let local = CGRect(x: captured.minX - bounds.minX, y: captured.minY - bounds.minY,
                           width: captured.width, height: captured.height)
            .intersection(CGRect(origin: .zero, size: bounds.size))
        guard !local.isNull, local.width >= 1, local.height >= 1 else {
            throw SpaceOError.captureFailed("tile \(rect) is not inside display \(stage.displayID)")
        }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = local
        let dimensions = try validatedDimensions(
            width: local.width, height: local.height, scale: scale)
        config.width = dimensions.width
        config.height = dimensions.height
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await capture(filter: filter, config: config,
                                      what: "tile of display \(stage.displayID)")
        return (image, ImageGeometry(
            origin: "tile",
            scale: scale,
            pixelWidth: image.width,
            pixelHeight: image.height,
            pointWidth: local.width,
            pointHeight: local.height,
            originX: captured.minX,
            originY: captured.minY))
    }

    /// A single window, wherever it lives.
    public static func window(
        _ window: WindowRef,
        scale: Double = defaultScale
    ) async throws -> (image: CGImage, geometry: ImageGeometry) {
        guard CGPreflightScreenCaptureAccess() else { throw SpaceOError.screenRecordingDenied }
        let content = try await shareableContent()
        guard let target = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw SpaceOError.captureFailed("window \(window.windowID) is not shareable")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let dimensions = try validatedDimensions(
            width: target.frame.width, height: target.frame.height, scale: scale)
        config.width = dimensions.width
        config.height = dimensions.height
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await capture(filter: filter, config: config,
                                      what: "window \(window.windowID)")
        return (image, ImageGeometry(
            origin: "window",
            scale: scale,
            pixelWidth: image.width,
            pixelHeight: image.height,
            pointWidth: target.frame.width,
            pointHeight: target.frame.height,
            originX: target.frame.origin.x,
            originY: target.frame.origin.y,
            windowID: window.windowID))
    }

    /// Validate before converting untrusted/window-server floating-point geometry to `Int` or
    /// asking ScreenCaptureKit to allocate a framebuffer.
    static func validatedDimensions(
        width: Double,
        height: Double,
        scale: Double = 1
    ) throws -> (width: Int, height: Int) {
        guard width.isFinite, height.isFinite, scale.isFinite,
              width >= 1, height >= 1, scale > 0 else {
            throw SpaceOError.captureFailed("capture dimensions must be finite and positive")
        }
        let scaledWidth = width * scale
        let scaledHeight = height * scale
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth < Double(Int.max),
              scaledHeight < Double(Int.max) else {
            throw SpaceOError.captureFailed("capture dimensions exceed this process's integer range")
        }
        return (max(1, Int(scaledWidth.rounded(.up))),
                max(1, Int(scaledHeight.rounded(.up))))
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false,
                                                                        onScreenWindowsOnly: false)
        } catch {
            throw SpaceOError.captureFailed("could not enumerate shareable content: \(error.localizedDescription)")
        }
    }

    private static func capture(filter: SCContentFilter,
                                config: SCStreamConfiguration,
                                what: String) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            throw SpaceOError.captureFailed("\(what): \(error.localizedDescription)")
        }
    }

    // MARK: - Encoding and inspection

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw SpaceOError.captureFailed("could not create PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SpaceOError.captureFailed("PNG encoding failed")
        }
        return data as Data
    }

    @discardableResult
    public static func write(_ image: CGImage, to url: URL) throws -> URL {
        try pngData(image).write(to: url)
        return url
    }

    /// How much visual variety the image contains, 0...1.
    ///
    /// This exists so tests can assert "the window actually rendered" rather than trusting that
    /// a non-zero byte count means real content. A blank or single-colour frame scores ~0.
    public static func visualEntropy(_ image: CGImage, samples: Int = 4096) -> Double {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let length = CFDataGetLength(data)
        guard length > 4 else { return 0 }

        var histogram = [Int](repeating: 0, count: 256)
        let stride = max(4, (length / max(1, samples)) & ~3)
        var offset = 0
        var counted = 0
        while offset + 2 < length {
            // Luminance-ish: average of the first three channels at this pixel.
            let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
            histogram[luma] += 1
            counted += 1
            offset += stride
        }
        guard counted > 0 else { return 0 }

        var entropy = 0.0
        for count in histogram where count > 0 {
            let p = Double(count) / Double(counted)
            entropy -= p * log2(p)
        }
        return entropy / 8.0     // normalise against the 8-bit maximum
    }

    /// True when the image plausibly contains rendered UI rather than a blank surface.
    public static func looksRendered(_ image: CGImage) -> Bool {
        image.width > 8 && image.height > 8 && visualEntropy(image) > 0.02
    }
}
