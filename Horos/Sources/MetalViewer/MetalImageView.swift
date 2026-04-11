import AppKit
import MetalKit
import simd

final class MetalImageView: MTKView {
    struct MouseAnnotationState {
        let pixelPoint: CGPoint
        let pixelValue: Float
        let dicomPoint: SIMD3<Float>
    }

    private var dragAnchor: NSPoint = .zero
    private var wlAnchor: Float = 0
    private var wwAnchor: Float = 0
    private var panAnchor = SIMD2<Float>(repeating: 0)
    private var interactionMode: InteractionMode = .windowLevel
    private var trackingAreaRef: NSTrackingArea?

    private enum InteractionMode {
        case windowLevel
        case pan
    }

    private func interactionMode(for event: NSEvent) -> InteractionMode {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.shift) ? .pan : .windowLevel
    }

    let renderer: MetalViewerRenderer
    var titleDidChange: ((String) -> Void)?
    var activateHandler: (() -> Void)?
    var interactionEventHandler: (() -> Void)?
    var annotationStateDidChange: (() -> Void)?
    private(set) var mouseAnnotationState: MouseAnnotationState?

    init(frame frameRect: NSRect, pixList: [DCMPix]) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac.")
        }

        renderer = MetalViewerRenderer(device: device, pixList: pixList)
        super.init(frame: frameRect, device: device)

        self.delegate = renderer
        self.framebufferOnly = false
        self.enableSetNeedsDisplay = true
        self.isPaused = true
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColorMake(0, 0, 0, 1)
        self.preferredFramesPerSecond = 60

        renderer.stateDidChange = { [weak self] state in
            self?.titleDidChange?(state)
            self?.needsDisplay = true
            self?.annotationStateDidChange?()
        }
        renderer.resetAndLoadInitialSlice()
        titleDidChange?(renderer.stateDescription)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        interactionEventHandler?()
        let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let step = delta > 0 ? 1 : -1
        renderer.stepSlice(by: step)
        updateMouseAnnotationState(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        dragAnchor = convert(event.locationInWindow, from: nil)
        wlAnchor = renderer.windowLevel
        wwAnchor = renderer.windowWidth
        panAnchor = renderer.panOffset
        interactionMode = interactionMode(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        interactionEventHandler?()
        let currentPoint = convert(event.locationInWindow, from: nil)
        let currentInteractionMode = interactionMode(for: event)

        if currentInteractionMode != interactionMode {
            interactionMode = currentInteractionMode
            dragAnchor = currentPoint
            wlAnchor = renderer.windowLevel
            wwAnchor = renderer.windowWidth
            panAnchor = renderer.panOffset
        }

        let deltaX = Float(currentPoint.x - dragAnchor.x)
        let deltaY = Float(currentPoint.y - dragAnchor.y)

        switch interactionMode {
        case .windowLevel:
            renderer.updateWindowLevel(
                wl: wlAnchor - deltaY * max(abs(wlAnchor), 128) * 0.003,
                ww: wwAnchor + deltaX * max(abs(wwAnchor), 256) * 0.003
            )
        case .pan:
            renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
        }
        updateMouseAnnotationState(from: currentPoint)
    }

    override func mouseUp(with event: NSEvent) {
        interactionEventHandler?()
        if interactionMode == .windowLevel {
            renderer.commitWindowLevel()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        renderer.resetWindowLevel()
        updateMouseAnnotationState(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        interactionEventHandler?()
        updateMouseAnnotationState(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if mouseAnnotationState != nil {
            mouseAnnotationState = nil
            annotationStateDidChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // left arrow
            renderer.stepSlice(by: 1)
        case 124: // right arrow
            renderer.stepSlice(by: -1)
        case 126: // up arrow
            renderer.zoom(by: 1.1)
        case 125: // down arrow
            renderer.zoom(by: 1.0 / 1.1)
        case 15: // r
            renderer.rerunRegistration()
        default:
            super.keyDown(with: event)
        }
    }

    var currentSliceGeometry: MetalViewerSliceGeometry? {
        guard let pix = renderer.currentPix else { return nil }
        return MetalViewerSliceGeometry(pix: pix)
    }

    var displayedImageRect: CGRect {
        renderer.imageRect(in: bounds)
    }

    private func updateMouseAnnotationState(from point: CGPoint) {
        guard let pix = renderer.currentPix else {
            if mouseAnnotationState != nil {
                mouseAnnotationState = nil
                annotationStateDidChange?()
            }
            return
        }

        let imageRect = displayedImageRect
        guard imageRect.contains(point), pix.pwidth > 0, pix.pheight > 0 else {
            if mouseAnnotationState != nil {
                mouseAnnotationState = nil
                annotationStateDidChange?()
            }
            return
        }

        let normalizedX = (point.x - imageRect.minX) / imageRect.width
        let normalizedY = (imageRect.maxY - point.y) / imageRect.height
        let pixelX = max(0, min(CGFloat(pix.pwidth - 1), normalizedX * CGFloat(pix.pwidth)))
        let pixelY = max(0, min(CGFloat(pix.pheight - 1), normalizedY * CGFloat(pix.pheight)))
        let sampleX = min(max(Int(pixelX), 0), Int(pix.pwidth - 1))
        let sampleY = min(max(Int(pixelY), 0), Int(pix.pheight - 1))

        var dicomCoords = [Float](repeating: 0, count: 3)
        pix.convertX(Float(pixelX), pixY: Float(pixelY), toDICOMCoords: &dicomCoords, pixelCenter: true)

        mouseAnnotationState = MouseAnnotationState(
            pixelPoint: CGPoint(x: pixelX, y: pixelY),
            pixelValue: pix.fImage?[sampleY * Int(pix.pwidth) + sampleX] ?? 0,
            dicomPoint: SIMD3<Float>(dicomCoords[0], dicomCoords[1], dicomCoords[2])
        )
        annotationStateDidChange?()
    }
}
