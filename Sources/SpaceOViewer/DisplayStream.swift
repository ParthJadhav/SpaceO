import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SpaceOKit

/// A live ScreenCaptureKit stream of one display, delivering complete BGRA frames.
///
/// Frames are handed over as their `CMSampleBuffer` so the presenting view can keep the buffer
/// (and therefore its IOSurface) alive for exactly as long as it is on screen.
final class DisplayStream: NSObject, SCStreamDelegate, SCStreamOutput {

    /// Called on the stream's sample queue; the receiver marshals to the main thread.
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// Called when the stream ends for any reason other than an explicit `stop()`.
    var onStopped: ((Error?) -> Void)?

    private let sampleQueue = DispatchQueue(label: "spaceo.viewer.frames")
    private let stateLock = NSLock()
    private var stream: SCStream?

    func start(displayID: CGDirectDisplayID, pointSize: CGSize) async throws {
        await stop()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw SpaceOError.captureFailed(
                "could not enumerate shareable content: \(error.localizedDescription)")
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SpaceOError.captureFailed("display \(displayID) is not shareable")
        }

        let config = SCStreamConfiguration()
        let dimensions = Self.frameDimensions(
            pixelWidth: display.width,
            pixelHeight: display.height,
            fallbackPointSize: pointSize)
        config.width = dimensions.width
        config.height = dimensions.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        stateLock.withLock { self.stream = stream }
    }

    func stop() async {
        let running: SCStream? = stateLock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let running else { return }
        try? await running.stopCapture()
    }

    /// ScreenCaptureKit reports the display's real pixel dimensions. Use those verbatim: a
    /// virtual display can be 1x even when the Viewer window lives on a Retina display, so
    /// deriving pixels from AppKit points creates an oversized frame with black padding.
    static func frameDimensions(
        pixelWidth: Int,
        pixelHeight: Int,
        fallbackPointSize: CGSize
    ) -> (width: Int, height: Int) {
        if pixelWidth > 0, pixelHeight > 0 {
            return (pixelWidth, pixelHeight)
        }
        guard fallbackPointSize.width.isFinite, fallbackPointSize.height.isFinite,
              fallbackPointSize.width > 0, fallbackPointSize.height > 0,
              fallbackPointSize.width < Double(Int.max),
              fallbackPointSize.height < Double(Int.max) else {
            return (1_920, 1_080)
        }
        return (Int(fallbackPointSize.width.rounded()),
                Int(fallbackPointSize.height.rounded()))
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              statusValue == SCFrameStatus.complete.rawValue,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        onFrame?(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasCurrent = stateLock.withLock {
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        guard wasCurrent else { return }
        onStopped?(error)
    }
}
