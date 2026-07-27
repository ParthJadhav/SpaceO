import AppKit
import CoreMedia
import CoreVideo
import SpaceOKit
import SwiftUI

/// The console surface: paints stream frames into an aspect-fit layer and, while Control is on,
/// swallows local mouse and keyboard events and hands them to the input controller.
///
/// Rendering assigns each frame's IOSurface straight to the layer — zero-copy — and keeps the
/// sample buffer alive until the next frame replaces it. Input mapping uses the same aspect-fit
/// math (`MirrorInput.ViewportMapping`), so pixels and clicks cannot drift apart.
final class VMSurfaceView: NSView {

    weak var input: ViewerInputController?
    var interactionEnabled = false {
        didSet {
            guard oldValue != interactionEnabled else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    private let contentLayer = CALayer()
    private var lastSample: CMSampleBuffer?
    private var activeTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        contentLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("VMSurfaceView is code-only")
    }

    override func layout() {
        super.layout()
        withoutImplicitAnimation { contentLayer.frame = bounds }
    }

    override func resetCursorRects() {
        if interactionEnabled {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - Frames

    func present(_ sample: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        lastSample = sample
        withoutImplicitAnimation { contentLayer.contents = surface }
    }

    func clearFrame() {
        lastSample = nil
        withoutImplicitAnimation { contentLayer.contents = nil }
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - Pointer events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let activeTrackingArea { removeTrackingArea(activeTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        activeTrackingArea = area
    }

    private func viewPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)   // flipped view: top-left origin
    }

    private func forwardPointer(_ phase: MirrorInput.PointerPhase,
                                _ button: MouseButton,
                                _ event: NSEvent) {
        guard interactionEnabled else { return }
        input?.pointer(phase, button: button,
                       viewPoint: viewPoint(for: event),
                       viewSize: bounds.size,
                       clickCount: max(1, min(3, event.clickCount)),
                       template: event.cgEvent?.copy())
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardPointer(.down, .left, event)
    }
    override func mouseDragged(with event: NSEvent) { forwardPointer(.drag, .left, event) }
    override func mouseUp(with event: NSEvent) { forwardPointer(.up, .left, event) }
    override func rightMouseDown(with event: NSEvent) { forwardPointer(.down, .right, event) }
    override func rightMouseDragged(with event: NSEvent) { forwardPointer(.drag, .right, event) }
    override func rightMouseUp(with event: NSEvent) { forwardPointer(.up, .right, event) }
    override func mouseMoved(with event: NSEvent) { forwardPointer(.move, .left, event) }

    override func scrollWheel(with event: NSEvent) {
        guard interactionEnabled else { return }
        input?.scroll(deltaX: event.scrollingDeltaX,
                      deltaY: event.scrollingDeltaY,
                      viewPoint: viewPoint(for: event),
                      viewSize: bounds.size)
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        guard interactionEnabled else { return super.keyDown(with: event) }
        input?.key(down: true, keyCode: event.keyCode,
                   modifiers: event.modifierFlags, characters: event.characters)
    }

    override func keyUp(with event: NSEvent) {
        guard interactionEnabled else { return super.keyUp(with: event) }
        input?.key(down: false, keyCode: event.keyCode,
                   modifiers: event.modifierFlags, characters: event.characters)
    }

    /// While Control is on, every command shortcut belongs to the selected display.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard interactionEnabled, window?.isKeyWindow == true else {
            return super.performKeyEquivalent(with: event)
        }
        input?.key(down: true, keyCode: event.keyCode,
                   modifiers: event.modifierFlags, characters: event.characters)
        return true
    }
}

/// SwiftUI wrapper for the console surface.
struct StreamSurface: NSViewRepresentable {
    @EnvironmentObject private var model: ViewerModel

    func makeNSView(context: Context) -> VMSurfaceView {
        let view = VMSurfaceView(frame: .zero)
        view.input = model.input
        model.stream.onFrame = { [weak view] sample in
            DispatchQueue.main.async { view?.present(sample) }
        }
        return view
    }

    func updateNSView(_ view: VMSurfaceView, context: Context) {
        let interactive = model.interactionEnabled && model.selected != nil
        view.interactionEnabled = interactive
        if interactive, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
        if model.selected == nil {
            view.clearFrame()
        }
    }
}
