import AppKit
import MetalKit
import simd

private final class MetalMPRPreviewOverlayView: NSView {
    weak var owner: MetalImageView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let owner,
              owner.renderer.displayMode == .mpr,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds) else {
            return
        }

        NSColor(calibratedWhite: 0.18, alpha: 0.9).setFill()
        layout.dividerRect.fill()
        NSColor(calibratedWhite: 0.55, alpha: 0.8).setFill()
        CGRect(x: layout.dividerRect.midX - 0.5, y: layout.dividerRect.minY, width: 1, height: layout.dividerRect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 0.95),
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = .zero
                return shadow
            }(),
        ]

        for pane in layout.previewPanes {
            drawLabel(pane.left, at: CGPoint(x: pane.rect.minX + 8, y: pane.rect.midY), alignment: .left, attributes: attributes)
            drawLabel(pane.right, at: CGPoint(x: pane.rect.maxX - 8, y: pane.rect.midY), alignment: .right, attributes: attributes)
            drawLabel(pane.top, at: CGPoint(x: pane.rect.midX, y: pane.rect.minY + 8), alignment: .center, attributes: attributes)
            drawLabel(pane.bottom, at: CGPoint(x: pane.rect.midX, y: pane.rect.maxY - 8), alignment: .center, attributes: attributes)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner,
              owner.renderer.displayMode == .mpr,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds),
              layout.dividerRect.insetBy(dx: -5, dy: 0).contains(point) else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let owner,
              owner.renderer.displayMode == .mpr,
              let layout = owner.renderer.mprPreviewOverlayLayout(in: bounds) else {
            return
        }
        addCursorRect(layout.dividerRect.insetBy(dx: -5, dy: 0), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.beginMPRPreviewDividerDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.dragMPRPreviewDivider(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.endMPRPreviewDividerDrag(with: event)
    }

    private enum LabelAlignment {
        case left
        case right
        case center
    }

    private func drawLabel(
        _ label: String,
        at point: CGPoint,
        alignment: LabelAlignment,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let attributed = NSAttributedString(string: label, attributes: attributes)
        let size = attributed.size()
        let originX: CGFloat
        switch alignment {
        case .left:
            originX = point.x
        case .right:
            originX = point.x - size.width
        case .center:
            originX = point.x - size.width * 0.5
        }

        attributed.draw(at: CGPoint(x: originX, y: point.y - size.height * 0.5))
    }
}

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
    private var mprDragMode: MPRDragMode = .none
    private var isDraggingMPRPreviewDivider = false
    private var trackingAreaRef: NSTrackingArea?
    private var preciseScrollSliceAccumulator: CGFloat = 0
    private let mprPreviewOverlayView = MetalMPRPreviewOverlayView(frame: .zero)

    private enum InteractionMode {
        case windowLevel
        case pan
    }

    private enum MPRDragMode {
        case none
        case rotate
        case pan
        case plane
        case planeTilt
    }

    private func interactionMode(for event: NSEvent) -> InteractionMode {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.shift) ? .pan : .windowLevel
    }

    private static let preciseScrollPointsPerSlice: CGFloat = 18
    private static let momentumScrollPointsPerSlice: CGFloat = 60

    let renderer: MetalViewerRenderer
    var titleDidChange: ((String) -> Void)?
    var activateHandler: (() -> Void)?
    var interactionEventHandler: (() -> Void)?
    var annotationStateDidChange: (() -> Void)?
    var windowLevelInteractionHandler: (() -> Void)?
    private(set) var mouseAnnotationState: MouseAnnotationState?

    init(
        frame frameRect: NSRect,
        pixList: [DCMPix],
        windowLevelState: MetalViewerWindowLevelState = MetalViewerWindowLevelState(),
        windowLevelStateDidChange: ((MetalViewerWindowLevelState) -> Void)? = nil
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this Mac.")
        }

        renderer = MetalViewerRenderer(device: device, pixList: pixList, windowLevelState: windowLevelState)
        super.init(frame: frameRect, device: device)

        self.delegate = renderer
        self.framebufferOnly = false
        self.enableSetNeedsDisplay = true
        self.isPaused = true
        self.colorPixelFormat = .bgra8Unorm
        self.depthStencilPixelFormat = .depth32Float
        self.clearColor = MTLClearColorMake(0, 0, 0, 1)
        self.preferredFramesPerSecond = 60

        mprPreviewOverlayView.owner = self
        mprPreviewOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mprPreviewOverlayView)
        NSLayoutConstraint.activate([
            mprPreviewOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mprPreviewOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mprPreviewOverlayView.topAnchor.constraint(equalTo: topAnchor),
            mprPreviewOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        renderer.stateDidChange = { [weak self] state in
            self?.titleDidChange?(state)
            self?.needsDisplay = true
            self?.mprPreviewOverlayView.needsDisplay = true
            if let overlayView = self?.mprPreviewOverlayView {
                overlayView.window?.invalidateCursorRects(for: overlayView)
            }
            self?.annotationStateDidChange?()
        }
        renderer.windowLevelStateDidChange = windowLevelStateDidChange
        renderer.resetAndLoadInitialSlice()
        titleDidChange?(renderer.stateDescription)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        mprPreviewOverlayView.needsDisplay = true
        mprPreviewOverlayView.window?.invalidateCursorRects(for: mprPreviewOverlayView)
    }

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
        let phase = event.momentumPhase.isEmpty ? event.phase : event.momentumPhase

        if phase.contains(.began) {
            preciseScrollSliceAccumulator = 0
        }

        if event.hasPreciseScrollingDeltas {
            preciseScrollSliceAccumulator += delta
            let scrollPointsPerSlice = event.momentumPhase.isEmpty ? Self.preciseScrollPointsPerSlice : Self.momentumScrollPointsPerSlice
            let stepCount = Int(preciseScrollSliceAccumulator / scrollPointsPerSlice)
            if stepCount != 0 {
                stepThroughCurrentMode(by: stepCount, event: event)
                preciseScrollSliceAccumulator -= CGFloat(stepCount) * scrollPointsPerSlice
            }
        } else if delta != 0 {
            stepThroughCurrentMode(by: delta > 0 ? 1 : -1, event: event)
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            preciseScrollSliceAccumulator = 0
        }
        updateMouseAnnotationState(from: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        let zoomFactor = min(max(1.0 + Float(event.magnification), 0.1), 10.0)
        renderer.zoom(by: zoomFactor)
        updateMouseAnnotationState(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        dragAnchor = convert(event.locationInWindow, from: nil)
        wlAnchor = renderer.activeWindowLevel
        wwAnchor = renderer.activeWindowWidth
        panAnchor = renderer.panOffset
        interactionMode = interactionMode(for: event)
        if renderer.displayMode == .mpr {
            switch interactionMode {
            case .pan:
                mprDragMode = .pan
            case .windowLevel:
                if renderer.beginMPRPlaneDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .plane
                } else if renderer.beginMPRPlaneTiltDrag(at: dragAnchor, in: bounds) {
                    mprDragMode = .planeTilt
                } else {
                    mprDragMode = .rotate
                }
            }
        } else {
            mprDragMode = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        interactionEventHandler?()
        let currentPoint = convert(event.locationInWindow, from: nil)
        let currentInteractionMode = interactionMode(for: event)

        if currentInteractionMode != interactionMode {
            interactionMode = currentInteractionMode
            dragAnchor = currentPoint
            wlAnchor = renderer.activeWindowLevel
            wwAnchor = renderer.activeWindowWidth
            panAnchor = renderer.panOffset
            if renderer.displayMode == .mpr, mprDragMode != .plane, mprDragMode != .planeTilt {
                mprDragMode = currentInteractionMode == .pan ? .pan : .rotate
            }
        }

        let deltaX = Float(currentPoint.x - dragAnchor.x)
        let deltaY = Float(currentPoint.y - dragAnchor.y)

        if renderer.displayMode == .mpr {
            switch mprDragMode {
            case .plane:
                renderer.dragMPRPlane(to: currentPoint)
            case .planeTilt:
                renderer.dragMPRPlaneTilt(to: currentPoint)
            case .rotate:
                renderer.rotateMPR(from: dragAnchor, to: currentPoint, in: bounds)
                dragAnchor = currentPoint
            case .pan:
                renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
            case .none:
                break
            }
            updateMouseAnnotationState(from: currentPoint)
            return
        }

        switch interactionMode {
        case .windowLevel:
            renderer.updateWindowLevel(
                wl: wlAnchor - deltaY * max(abs(wlAnchor), 128) * 0.003,
                ww: wwAnchor + deltaX * max(abs(wwAnchor), 256) * 0.003
            )
            windowLevelInteractionHandler?()
        case .pan:
            renderer.setPanOffset(panAnchor + SIMD2<Float>(deltaX, deltaY))
        }
        updateMouseAnnotationState(from: currentPoint)
    }

    override func mouseUp(with event: NSEvent) {
        interactionEventHandler?()
        renderer.endMPRPlaneDrag()
        mprDragMode = .none
        if interactionMode == .windowLevel, renderer.displayMode == .stack2D {
            renderer.commitWindowLevel()
        }
    }

    func beginMPRPreviewDividerDrag(with event: NSEvent) {
        interactionEventHandler?()
        activateHandler?()
        window?.makeFirstResponder(self)
        isDraggingMPRPreviewDivider = true
        updateMPRPreviewDivider(with: event)
    }

    func dragMPRPreviewDivider(with event: NSEvent) {
        guard isDraggingMPRPreviewDivider else { return }
        interactionEventHandler?()
        updateMPRPreviewDivider(with: event)
    }

    func endMPRPreviewDividerDrag(with event: NSEvent) {
        guard isDraggingMPRPreviewDivider else { return }
        interactionEventHandler?()
        updateMPRPreviewDivider(with: event)
        isDraggingMPRPreviewDivider = false
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
        let point = convert(event.locationInWindow, from: nil)
        updateMouseAnnotationState(from: point)
    }

    override func mouseExited(with event: NSEvent) {
        renderer.updateMPRHover(at: nil, in: bounds)
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

    func setDisplayMode(_ mode: MetalViewerDisplayMode) {
        renderer.setDisplayMode(mode)
        mouseAnnotationState = nil
        annotationStateDidChange?()
    }

    private func stepThroughCurrentMode(by stepCount: Int, event: NSEvent) {
        if renderer.displayMode == .mpr {
            renderer.moveMPRPlane(axis: mprScrollAxis(for: event), by: -Float(stepCount))
        } else {
            renderer.stepSlice(by: stepCount)
        }
    }

    private func mprScrollAxis(for event: NSEvent) -> Int {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option) {
            return 0
        }
        if flags.contains(.shift) {
            return 1
        }
        return 2
    }

    private func updateMPRPreviewDivider(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        renderer.setMPRPreviewDividerLocation(point.x, in: bounds)
        needsDisplay = true
        mprPreviewOverlayView.needsDisplay = true
        mprPreviewOverlayView.window?.invalidateCursorRects(for: mprPreviewOverlayView)
    }

    private func updateMouseAnnotationState(from point: CGPoint) {
        guard renderer.displayMode == .stack2D else {
            renderer.updateMPRHover(at: point, in: bounds)
            if mouseAnnotationState != nil {
                mouseAnnotationState = nil
                annotationStateDidChange?()
            }
            return
        }

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
