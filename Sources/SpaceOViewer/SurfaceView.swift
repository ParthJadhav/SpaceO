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
    var onKey: ((_ down: Bool, _ keyCode: UInt16,
                 _ modifiers: NSEvent.ModifierFlags, _ characters: String?) -> Void)?
    var onExitControl: (() -> Void)?
    var displayName = "No display selected" {
        didSet { updateAccessibilityMetadata() }
    }
    var streamRunning = false {
        didSet { updateAccessibilityMetadata() }
    }
    var interactionEnabled = false {
        didSet {
            guard oldValue != interactionEnabled else { return }
            if interactionEnabled {
                // A new Control session cannot be a repeat of an exit sequence whose key-up was
                // lost while the previous session was closing.
                localExitKeyIsDown = false
            }
            window?.invalidateCursorRects(for: self)
            updateAccessibilityMetadata()
        }
    }

    private let contentLayer = CALayer()
    private var lastSample: CMSampleBuffer?
    private var activeTrackingArea: NSTrackingArea?
    /// Control turns off during the reserved key-down callback. Remember that sequence so its
    /// matching key-up (and any repeat generated before release) remains local as well.
    private var localExitKeyIsDown = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        contentLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(contentLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibilityMetadata()
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
        guard handleKeyEvent(event, down: true) else {
            return super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard handleKeyEvent(event, down: false) else {
            return super.keyUp(with: event)
        }
    }

    /// While Control is on, command shortcuts belong to the selected display except for the
    /// Viewer's documented local exit. The exit is consumed here and never reaches `onKey`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard interactionEnabled, window?.isKeyWindow == true else {
            return super.performKeyEquivalent(with: event)
        }
        return handleKeyEvent(event, down: true)
    }

    /// Shared by the AppKit responder methods and regression tests. Returning true means the
    /// Viewer consumed the event; `.exitControl` deliberately never calls the forwarding closure,
    /// for key-down, key-up, or a key-equivalent path.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent, down: Bool) -> Bool {
        if event.keyCode == ViewerControlPolicy.localExitKeyCode, localExitKeyIsDown {
            if !down {
                localExitKeyIsDown = false
                return true
            }
            if ViewerControlPolicy.isLocalExitChord(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) {
                return true
            }
            // A different Escape key-down means the original key-up was lost. End that stale
            // sequence and route this fresh event according to the current Control state.
            localExitKeyIsDown = false
        }
        switch ViewerControlPolicy.keyDisposition(
            interactionEnabled: interactionEnabled,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
        case .local:
            return false
        case .forward:
            onKey?(down, event.keyCode, event.modifierFlags, event.characters)
            return true
        case .exitControl:
            if down {
                localExitKeyIsDown = true
                onExitControl?()
            }
            return true
        }
    }

    private func updateAccessibilityMetadata() {
        setAccessibilityLabel(ViewerAccessibility.surfaceLabel(displayName: displayName))
        setAccessibilityValue(
            ViewerAccessibility.surfaceValue(
                streamRunning: streamRunning,
                controlEnabled: interactionEnabled
            )
        )
        setAccessibilityHelp(
            ViewerAccessibility.surfaceHelp(
                streamRunning: streamRunning,
                controlEnabled: interactionEnabled
            )
        )
    }
}

/// SwiftUI wrapper for the console surface.
struct StreamSurface: NSViewRepresentable {
    @EnvironmentObject private var model: ViewerModel

    func makeNSView(context: Context) -> VMSurfaceView {
        let view = VMSurfaceView(frame: .zero)
        view.input = model.input
        view.onKey = { [weak input = model.input] down, keyCode, modifiers, characters in
            input?.key(down: down, keyCode: keyCode,
                       modifiers: modifiers, characters: characters)
        }
        view.onExitControl = { [weak model] in
            model?.setInteractionEnabled(false)
        }
        model.stream.onFrame = { [weak view] sample in
            DispatchQueue.main.async { view?.present(sample) }
        }
        return view
    }

    func updateNSView(_ view: VMSurfaceView, context: Context) {
        let interactive = model.interactionEnabled
            && model.selected != nil
            && model.streamRunning
        view.displayName = model.selected?.name ?? "No display selected"
        view.streamRunning = model.streamRunning
        view.interactionEnabled = interactive
        if interactive, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
        if model.selected == nil {
            view.clearFrame()
        }
    }
}
