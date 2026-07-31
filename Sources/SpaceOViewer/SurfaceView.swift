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
    var onCaptureRequest: (() -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var displayBounds = CGRect.zero {
        didSet { needsLayout = true }
    }
    var zoom: CGFloat = 1 {
        didSet { needsLayout = true }
    }
    var pan = CGPoint.zero {
        didSet { needsLayout = true }
    }
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
                beginHostInputCapture()
            } else {
                endHostInputCapture()
            }
            window?.invalidateCursorRects(for: self)
            updateAccessibilityMetadata()
        }
    }

    private let contentLayer = CALayer()
    private let virtualPointerLayer = CAShapeLayer()
    private var lastSample: CMSampleBuffer?
    private var activeTrackingArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var hostCaptureActive = false
    private var savedHostCursorPosition: CGPoint?
    private var virtualPointer = CGPoint.zero
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
        virtualPointerLayer.path = CGPath(
            ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8),
            transform: nil
        )
        virtualPointerLayer.fillColor = NSColor.controlAccentColor.cgColor
        virtualPointerLayer.strokeColor = NSColor.white.cgColor
        virtualPointerLayer.lineWidth = 1.5
        virtualPointerLayer.shadowColor = NSColor.black.cgColor
        virtualPointerLayer.shadowOpacity = 0.45
        virtualPointerLayer.shadowRadius = 2
        virtualPointerLayer.isHidden = true
        layer?.addSublayer(virtualPointerLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibilityMetadata()
    }

    required init?(coder: NSCoder) {
        fatalError("VMSurfaceView is code-only")
    }

    deinit {
        endHostInputCapture()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else {
            endHostInputCapture()
            return
        }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onExitControl?()
        })
        windowObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.onExitControl?()
        })
        if interactionEnabled { beginHostInputCapture() }
    }

    override func layout() {
        super.layout()
        let mapping = MirrorInput.ViewportMapping(
            displayBounds: displayBounds,
            viewSize: bounds.size,
            zoom: zoom,
            pan: pan
        )
        withoutImplicitAnimation {
            contentLayer.frame = mapping.contentRect
            contentLayer.contentsGravity = .resize
            updateVirtualPointerLayer(mapping: mapping)
        }
    }

    override func resetCursorRects() {
        if !interactionEnabled {
            addCursorRect(bounds, cursor: zoom > 1 ? .openHand : .arrow)
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
        guard hostCaptureActive else {
            return convert(event.locationInWindow, from: nil)
        }
        if event.type == .mouseMoved
            || event.type == .leftMouseDragged
            || event.type == .rightMouseDragged {
            virtualPointer.x += event.deltaX
            virtualPointer.y += event.deltaY
            clampVirtualPointer()
            updateVirtualPointerLayer()
        }
        return virtualPointer
    }

    private func forwardPointer(_ phase: MirrorInput.PointerPhase,
                                _ button: MouseButton,
                                _ event: NSEvent) {
        guard interactionEnabled else { return }
        input?.pointer(phase, button: button,
                       viewPoint: viewPoint(for: event),
                       viewSize: bounds.size,
                       clickCount: max(1, min(3, event.clickCount)),
                       template: event.cgEvent?.copy(),
                       zoom: zoom,
                       pan: pan)
    }

    override func mouseDown(with event: NSEvent) {
        if !interactionEnabled {
            window?.makeFirstResponder(self)
            onCaptureRequest?()
            return
        }
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
        guard interactionEnabled else {
            guard zoom > 1 else { return }
            onPan?(CGPoint(
                x: event.scrollingDeltaX / 240,
                y: event.scrollingDeltaY / 240
            ))
            return
        }
        input?.scroll(deltaX: event.scrollingDeltaX,
                      deltaY: event.scrollingDeltaY,
                      viewPoint: viewPoint(for: event),
                      viewSize: bounds.size,
                      zoom: zoom,
                      pan: pan)
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

    // MARK: - Host-input capture

    private func beginHostInputCapture() {
        guard interactionEnabled,
              window?.isKeyWindow == true,
              !hostCaptureActive else { return }
        savedHostCursorPosition = CGEvent(source: nil)?.location
        let mapping = MirrorInput.ViewportMapping(
            displayBounds: displayBounds,
            viewSize: bounds.size,
            zoom: zoom,
            pan: pan
        )
        let localMouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        virtualPointer = mapping.contentRect.contains(localMouse)
            ? localMouse
            : CGPoint(x: mapping.contentRect.midX, y: mapping.contentRect.midY)
        clampVirtualPointer()

        // Record the takeover before it happens. Everything below belongs to the whole Mac and
        // outlives this process, so a crash between the breadcrumb and the restore is survivable
        // while a crash between the takeover and the breadcrumb is not.
        HostInputGuard.beginCapture()
        CGAssociateMouseAndMouseCursorPosition(0)
        _ = MirrorInput.setHostGlobalShortcutsEnabled(false)
        NSCursor.hide()
        hostCaptureActive = true
        virtualPointerLayer.isHidden = false
        updateVirtualPointerLayer(mapping: mapping)
    }

    private func endHostInputCapture() {
        guard hostCaptureActive else { return }
        _ = MirrorInput.setHostGlobalShortcutsEnabled(true)
        CGAssociateMouseAndMouseCursorPosition(1)
        if let savedHostCursorPosition {
            CGWarpMouseCursorPosition(savedHostCursorPosition)
        }
        savedHostCursorPosition = nil
        hostCaptureActive = false
        virtualPointerLayer.isHidden = true
        NSCursor.unhide()
        HostInputGuard.endCapture()
    }

    private func clampVirtualPointer() {
        let mapping = MirrorInput.ViewportMapping(
            displayBounds: displayBounds,
            viewSize: bounds.size,
            zoom: zoom,
            pan: pan
        )
        guard mapping.contentRect.width > 0, mapping.contentRect.height > 0 else {
            virtualPointer = CGPoint(x: bounds.midX, y: bounds.midY)
            return
        }
        virtualPointer = CGPoint(
            x: min(mapping.contentRect.maxX.nextDown,
                   max(mapping.contentRect.minX, virtualPointer.x)),
            y: min(mapping.contentRect.maxY.nextDown,
                   max(mapping.contentRect.minY, virtualPointer.y))
        )
    }

    private func updateVirtualPointerLayer(
        mapping: MirrorInput.ViewportMapping? = nil
    ) {
        guard hostCaptureActive else {
            virtualPointerLayer.isHidden = true
            return
        }
        if let mapping, !mapping.contentRect.contains(virtualPointer) {
            virtualPointer = CGPoint(
                x: mapping.contentRect.midX,
                y: mapping.contentRect.midY
            )
        }
        virtualPointerLayer.position = virtualPointer
        virtualPointerLayer.isHidden = false
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
        view.onCaptureRequest = { [weak model] in
            model?.setInteractionEnabled(true)
        }
        view.onPan = { [weak model] delta in
            model?.pan(by: delta)
        }
        model.onFrame = { [weak view] sample in
            DispatchQueue.main.async { view?.present(sample) }
        }
        return view
    }

    func updateNSView(_ view: VMSurfaceView, context: Context) {
        let interactive = model.interactionEnabled
            && model.selected != nil
            && model.streamRunning
        view.displayName = model.interactionDisplay?.name ?? "No display selected"
        view.displayBounds = model.interactionDisplay?.bounds ?? .zero
        view.zoom = model.viewportZoom
        view.pan = model.viewportPan
        view.streamRunning = model.streamRunning
        view.interactionEnabled = interactive
        if interactive, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
        if model.selected == nil || !model.streamState.isLive {
            view.clearFrame()
        }
    }
}
